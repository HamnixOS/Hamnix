#!/usr/bin/env bash
# scripts/test_enter_linux_uid_map.sh
#
# Guards the NATIVE -> LINUX identity mapping on the `enter linux { ... }`
# path. Until this landed, linux_abi/u_syscalls.ad's getuid/geteuid/
# getgid/getegid hard-coded `return 0`, so EVERY process under
# `enter linux` believed it was root regardless of the native caller's
# uid. The fix reads the real per-task uid via current_task_uid()
# (kernel/sched/core.ad) and maps it through _linux_uid_from_native:
#
#   native 1 (hostowner)  -> Linux 0      (root)
#   native 65534 (nobody) -> Linux 65534  (pass through)
#   native >= 1000        -> same numeric (a non-root Linux user)
#   native 2..999         -> same numeric (a non-root service)
#
# WHAT THIS TEST PROVES
#
#   From a HOSTOWNER shell (hamsh-as-init runs as uid 1 == hostowner),
#   `enter linux { <linux binary that prints getuid()> }` reports
#   uid 0 (root) — i.e. the hostowner -> root mapping fires across the
#   enter-linux rfork (the body inherits the caller's native uid, and
#   _u_getuid maps it).
#
# HARNESS — mirrors scripts/test_enter_linux_distro_root.sh: drop hamsh
# as /init (INIT_ELF=hamsh.elf) with a STRIPPED HAMNIX_HAMSH_RC that
# defines the `linux` namespace and does NOT enter runlevel 5. That is
# deliberate: the full boot's `init 5` autostarts the hamUId desktop,
# which GRABS the serial console the moment hamsh is ready (see
# build_initramfs.py "runlevel-5 console takeover") and then drops
# serial-injected commands. The stripped rc keeps the serial line as
# the live interactive shell so `enter linux { ... }` is drivable.
#
# PROBE — tests/u-binary/u_glibc_idprobe, a static-PIE glibc ELF whose
# main() prints "U21: uid=%d gid=%d ppid=%d" via getuid()/getgid()/
# getppid(). Embedded into the native cpio root at /bin/u_glibc_idprobe
# (HAMNIX_EMBED_UBIN=1). The stripped rc defines `linux = ns { }` — an
# OVERLAY namespace that inherits the ambient bindings, so the cpio /bin
# (where the probe lives) resolves inside `enter linux`. The probe is a
# Linux-ABI ELF (OSABI=3), so its getuid() runs through the real
# _u_getuid mapping regardless of which namespace it executes in; the
# point under test is that the hostowner uid inherits across the
# enter-linux rfork and maps to root.
#
# FIXTURE GAP (non-root mapping, documented not faked)
#
#   The brief also asks, as a BONUS, to demonstrate the non-root case
#   (a native uid >= 1000 -> the same non-zero Linux uid). This lean
#   initramfs provisions NO regular user: hamsh runs as hostowner, and
#   the only userland path that lowers a task's native uid is
#   `newshell`/`su`, which authenticates against /etc/shadow for a
#   provisioned account this image does not carry. So the non-root half
#   cannot be exercised here without staging a regular user + its shadow
#   entry into the initramfs (the smallest fixture addition that would
#   unlock it). This gate pins the hostowner -> root branch end-to-end;
#   the >=1000 / 2..999 branches are the helper's identity pass-through.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# Build-on-missing: the glibc idprobe fixture is host-built + gitignored.
# Only SKIP on a genuine toolchain failure (mirrors test_u21_glibc_idprobe).
ensure_ubin_or_skip test_enter_linux_uid_map u_glibc_idprobe glibc_idprobe

echo "[test_enter_linux_uid_map] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_enter_linux_uid_map] (2/4) Plant stripped /etc/hamsh.rc (linux ns, no runlevel-5 DE)"
RC_TMP=$(mktemp /tmp/hamsh-rc-uidmap.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
linux = ns {
}
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[test_enter_linux_uid_map] (3/4) Build initramfs (hamsh as /init) + embed probe + kernel"
HAMNIX_EMBED_UBIN=1 HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-enter-linux-uidmap.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_enter_linux_uid_map] (4/4) Boot QEMU + drive enter linux { <uid probe> }"
set +e
(
    # Boot settle. A freshly-booted hamsh drops its FIRST serial line(s)
    # while early boot still churns, so we wait, then flush with throwaway
    # syncs before the load-bearing commands (see the serial-test memos).
    sleep 12
    printf 'echo SYNC_FLUSH\n'; sleep 2
    printf 'echo SYNC_FLUSH\n'; sleep 2

    # CONTROL (diagnostic): run the probe directly in the ambient
    # (hostowner) ns — getuid maps hostowner -> 0 even without the
    # enter-linux wrapper. Re-sent once to defeat any single-line drop.
    printf 'echo MAP_DIRECT_BEGIN\n'; sleep 1
    printf '/bin/u_glibc_idprobe\n'; sleep 3
    printf '/bin/u_glibc_idprobe\n'; sleep 3
    printf 'echo MAP_DIRECT_END\n'; sleep 1

    # GATE: the probe inside the linux namespace must STILL report uid 0 —
    # the hostowner uid inherits across the enter-linux rfork and maps to
    # root. Re-sent once for robustness against a dropped line.
    printf 'echo MAP_ENTER_BEGIN\n'; sleep 1
    printf 'enter linux { /bin/u_glibc_idprobe }\n'; sleep 5
    printf 'enter linux { /bin/u_glibc_idprobe }\n'; sleep 5
    printf 'echo MAP_ENTER_END\n'; sleep 1

    printf 'echo MAP_DONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 150s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[test_enter_linux_uid_map] --- captured output (tail) ---"
tail -200 "$LOG" | strings
echo "[test_enter_linux_uid_map] --- end output ---"

fail=0

# Sanity: the stripped rc sourced and the ns was captured.
if grep -a -F -q "TEST_RC_DONE_DEFINING_NS" "$LOG"; then
    echo "[test_enter_linux_uid_map] OK: stripped rc sourced + linux ns captured"
else
    echo "[test_enter_linux_uid_map] FAIL: stripped rc did not run (no ns)"
    fail=1
fi

# Helper: the idprobe marker "U21: uid=0 gid=0 ppid=1" must appear in the
# window AFTER the given BEGIN marker and BEFORE the matching END marker,
# so the direct-run control cannot satisfy the enter-linux gate (and
# vice-versa). LC_ALL=C — the serial log carries raw escape/NUL bytes.
uid0_between() {
    local beg="$1" end="$2"
    LC_ALL=C awk -v b="$beg" -v e="$end" '
        BEGIN { armed=0; found=0 }
        index($0,b)>0 { armed=1; next }
        index($0,e)>0 { armed=0 }
        armed && index($0,"U21: uid=0 gid=0 ppid=1")>0 { found=1 }
        END { exit found?0:1 }
    ' "$LOG"
}

# CONTROL (diagnostic): hostowner getuid maps to 0 on the direct path.
if uid0_between "MAP_DIRECT_BEGIN" "MAP_DIRECT_END"; then
    echo "[test_enter_linux_uid_map] OK(control): direct getuid maps hostowner -> uid 0"
else
    echo "[test_enter_linux_uid_map] DIAG: direct-run probe did not report uid 0" \
         "(non-fatal; the enter-linux gate below is authoritative)"
fi

# GATE: hostowner -> uid 0 across the enter-linux rfork.
if uid0_between "MAP_ENTER_BEGIN" "MAP_ENTER_END"; then
    echo "[test_enter_linux_uid_map] OK: enter linux { uid probe } reports uid 0 (hostowner -> root)"
else
    echo "[test_enter_linux_uid_map] FAIL: enter linux did not report uid 0 —" \
         "the hostowner -> root mapping did not fire (or the probe never ran)"
    fail=1
fi

# Regression guard: no kernel trap / page fault during the run.
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_enter_linux_uid_map] FAIL: CPU exception observed"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

# Diagnostic: surface exec failures for triage.
if grep -a -F -q "code=127" "$LOG"; then
    echo "[test_enter_linux_uid_map] DIAG: a code=127 (exec failure) appeared"
    grep -a -F "code=127" "$LOG" | head -4 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_enter_linux_uid_map] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_enter_linux_uid_map] PASS -- hostowner enters the Linux NS as root (uid 0)"
exit 0
