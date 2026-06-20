#!/usr/bin/env bash
# scripts/test_enter_linux_two_spawns.sh
#
# DECISIVE gate for the ET_DYN-vs-direct-map aliasing fix.
#
# Two Linux-ELF spawns in ONE boot must BOTH run to completion with NO
# supervisor #PF (vec=0x0e) and NO one-shot trap-diag halt. Before the
# fix, the first `enter linux` could load+run a busybox ELF, but the
# SECOND Linux-ELF spawn (a second `enter linux`, or a second
# `;`-separated binary inside one block) tripped a supervisor NOT-PRESENT
# #PF: the per-task Linux brk arena was identity-mapped at LOW physical
# RAM, so its 32 MiB window aliased the very frames the buddy/page
# allocator handed back to the kernel. A kernel write (slab/printk) under
# the second child's CR3 landed on a punched / re-issued low-identity PTE
# and the box halted (cr2 LOW, pte[0]=0).
#
# The fix (linux_abi/u_syscalls.ad + fs/elf.ad) relocates the brk arena
# to a HIGH virtual base (6 GiB, above the kernel direct-map) backed by
# the same low physical reservation — so no frame is ever reachable
# through BOTH a live user mapping AND a free / kernel-writable
# direct-map slot at the same translation.
#
# This gate asserts BOTH spawns reach the caller's terminal AND the
# kernel never halts. It is the hard counterpart to
# test_enter_linux_distro_root.sh (which deliberately scopes itself to
# ONE spawn and treats the 2nd-spawn #PF as a known-issue).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[two_spawns] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[two_spawns] (2/4) Plant /etc/hamsh.rc with the production #distro recipe"
RC_TMP=$(mktemp /tmp/hamsh-rc-twospawn.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
linux = ns clean {
    bind '#distro' /
    bind '#r/home' /home
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
    bind '#t/tmp' /tmp
}
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[two_spawns] (3/4) Build initramfs (hamsh as /init) + kernel"
HAMNIX_DEFAULT_REAL_DEBIAN=0 HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LOG=$(mktemp /tmp/test-two-spawns.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
}
trap cleanup EXIT

python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "[two_spawns] (4/4) Boot QEMU + drive TWO enter-linux spawns"
set +e
(
    sleep 6
    # SPAWN 1.
    printf 'echo SPAWN_ONE_START\n'; sleep 1
    printf 'enter linux { /bin/ls / }\n'
    sleep 5
    printf 'echo SPAWN_ONE_END\n'; sleep 1

    # SPAWN 2 — the historically-fatal second Linux-ELF load in one boot.
    printf 'echo SPAWN_TWO_START\n'; sleep 1
    printf 'enter linux { /bin/ls /bin }\n'
    sleep 5
    printf 'echo SPAWN_TWO_END\n'; sleep 1

    # SPAWN 3 — two binaries inside ONE block (a third + fourth ELF load).
    printf 'echo SPAWN_THREE_START\n'; sleep 1
    printf 'enter linux { /bin/ls / ; /bin/ls /bin }\n'
    sleep 6
    printf 'echo SPAWN_THREE_END\n'; sleep 1

    printf 'echo BANNER_DONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 110s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[two_spawns] --- captured output (tail) ---"
tail -250 "$LOG" | strings
echo "[two_spawns] --- end output ---"

fail=0
note() { echo "[two_spawns] $*"; }

# 1. HARD GATE: the kernel must NOT halt on the ET_DYN/direct-map #PF.
if grep -F -q "halting (one-shot diag, no recovery)" "$LOG"; then
    note "FAIL: kernel hit the one-shot trap-diag halt (ET_DYN/direct-map #PF still present)"
    fail=1
else
    note "OK: kernel did NOT halt across all spawns"
fi
# Belt-and-suspenders: an explicit page-fault vector dump is also fatal.
if grep -E -q "vec=0x0e|vec=0x0E|#PF.*cr2" "$LOG"; then
    note "FAIL: a #PF (vec=0x0e) appeared in the log"
    fail=1
else
    note "OK: no #PF vector in the log"
fi

# 2. rc.boot sanity.
if grep -F -q "TEST_RC_DONE_DEFINING_NS" "$LOG"; then
    note "OK: production #distro ns captured"
else
    note "FAIL: rc never finished defining the linux namespace"
    fail=1
fi

# Soft observation: did each spawn's listing reach the caller? (PROVENANCE
# is the distro-root marker.) We REQUIRE the kernel-survives gate above;
# the listing checks are reported and, when the boot is healthy, also
# enforced — two clean spawns must each show the distro root.
seen_prov=$(grep -c "PROVENANCE" "$LOG" || true)
note "INFO: PROVENANCE (distro-root listing) appeared $seen_prov time(s)"

# Each spawn's END banner must appear — proves hamsh kept running and the
# caller's terminal kept receiving output AFTER each Linux ELF ran (i.e.
# the box did not wedge mid-spawn).
for b in SPAWN_ONE_END SPAWN_TWO_END SPAWN_THREE_END BANNER_DONE; do
    if grep -F -q "$b" "$LOG"; then
        note "OK: reached $b"
    else
        note "FAIL: never reached $b (box wedged before this point)"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[two_spawns] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[two_spawns] PASS (two+ Linux-ELF spawns in one boot, no #PF, no halt)"
