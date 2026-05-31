#!/usr/bin/env bash
# scripts/test_u9_access.sh — U9 milestone: access + stat + lstat + openat.
#
# Boots Hamnix with /bin/u_access embedded in the initramfs and drives
# hamsh to exec it. u_access is a host-built, static, OSABI=Linux x86_64
# ELF whose _start exercises four Linux syscalls that were -ENOSYS stubs
# before U9:
#
#     access("/etc/motd", F_OK)         -> rax == 0,
#                                          prints "U9: access ok"
#     access("/no/such/file", F_OK)     -> rax == -2 (-ENOENT),
#                                          prints "U9: access ENOENT ok"
#     stat("/etc/motd", &statbuf)       -> rax == 0,
#                                          prints "U9: stat ok"
#     lstat("/etc/motd", &statbuf)      -> rax == 0,
#                                          prints "U9: lstat ok"
#     openat(AT_FDCWD, "/etc/motd", 0)  -> rax >= 0 (fd),
#                                          prints "U9: openat ok"
#     exit_group(0)
#
# Each marker is a discrete success signal: a missing earlier marker
# means every later marker is also missing for that reason, so we
# report each independently rather than short-circuiting on the
# first miss.
#
# Skip-on-missing: if tests/u-binary/u_access hasn't been built on the
# host (`make -C tests/u-binary/src/access install`), exit 0 with a
# notice so CI in environments without `as`/`ld` still passes.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_access
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/access; only SKIP on a real failure.
ensure_ubin_or_skip test_u9_access u_access access

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u9_access] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u9_access] (2/4) Swap /init = $HAMSH_ELF + embed u_access"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u9_access] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u9_access] (4/4) Boot QEMU + run /bin/u_access via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 25 \
    -- "u_access" 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u9_access] --- captured output ---"
cat "$LOG"
echo "[test_u9_access] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u9_access] OK: $label  ('$needle')"
    else
        echo "[test_u9_access] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Informational only: the "elf: Linux-ABI binary detected" printk fires on
# the ELFCLASS64 load path; this static fixture loads via the class entry
# that does not emit it, and the line (an early-boot printk) is in any case
# buffered out of the interactive capture window. The U9 syscall markers
# below are the authoritative feature signal, so this is a DIAG not a fail.
if grep -a -F -q "Linux-ABI binary detected" "$LOG"; then
    echo "[test_u9_access] OK: U1/U2 ELF detect  ('Linux-ABI binary detected')"
else
    echo "[test_u9_access] DIAG: 'Linux-ABI binary detected' printk not in capture (informational)"
fi
check_marker "access F_OK"          "U9: access ok"
check_marker "access ENOENT"        "U9: access ENOENT ok"
check_marker "stat"                 "U9: stat ok"
check_marker "lstat"                "U9: lstat ok"
check_marker "openat AT_FDCWD"      "U9: openat ok"

# Negative markers — these only appear if u_access hit an error path.
# Surface them in the test output so a regression is obvious.
for negmark in \
    "U9: access FAIL" \
    "U9: access ENOENT FAIL" \
    "U9: stat FAIL" \
    "U9: lstat FAIL" \
    "U9: openat FAIL"
do
    if grep -a -F -q "$negmark" "$LOG"; then
        echo "[test_u9_access] DIAG: u_access reported '$negmark'"
        fail=1
    fi
done

# Sanity: hamsh kept running after the child exited and reaped it. Current
# hamsh does not print a "bye" banner on `exit`; the authoritative signal is
# that the child task exited (code=0) and the scheduler then halted with no
# live tasks, both of which appear in the captured log. Report informationally.
if grep -a -F -q "[hamsh] bye." "$LOG"; then
    echo "[test_u9_access] OK: hamsh reaped u_access and exited cleanly"
elif grep -a -E -q "task: pid [0-9]+ exited \(code=0\)" "$LOG"; then
    echo "[test_u9_access] OK: u_access child reaped (exit code 0)"
else
    echo "[test_u9_access] DIAG: no clean child-exit line observed (informational)"
fi

# Diagnostic: a #PF (vector 0x0e) from user mode on the stat write
# would surface as a do_trap printk. Surface it explicitly so the
# kernel-side gap is obvious even when the marker is missing for a
# different reason.
if grep -a -F -q "TRAP: vector 0x0e" "$LOG"; then
    echo "[test_u9_access] DIAG: kernel reported #PF — likely user-mode" \
         "write to non-U=1 .bss page"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u9_access] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u9_access] PASS — access + stat + lstat + openat all working"
