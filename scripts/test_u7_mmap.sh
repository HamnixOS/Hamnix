#!/usr/bin/env bash
# scripts/test_u7_mmap.sh — U7 milestone: writev + mmap/munmap Linux ELF.
#
# Boots Hamnix with /bin/u_mmap embedded in the initramfs and drives
# hamsh to exec it. u_mmap is a host-built, static, OSABI=Linux x86_64
# ELF whose _start exercises three syscalls that were -ENOSYS stubs
# before U7:
#
#     writev(1, iov[2], 2)             -> two iov entries form the
#                                          line "U7: writev ok\n"
#     mmap(NULL, 0x1000, RW, ANON|PRIV, -1, 0)
#                                       -> non-zero rax = page base,
#                                          a4/a5 must arrive through
#                                          the widened SYSCALL stub
#     munmap(base, 0x1000)             -> rax == 0
#     write(1, "U7: mmap ok\n")        -> success marker
#     exit_group(0)
#
# Skip-on-missing: if tests/u-binary/u_mmap hasn't been built on the
# host (`make -C tests/u-binary/src/mmap install`), exit 0 with a
# notice so CI in environments without `as`/`ld` still passes.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_mmap
if [ ! -f "$UBIN" ]; then
    echo "[test_u7_mmap] SKIP: $UBIN not staged"
    echo "    Build with: make -C tests/u-binary/src/mmap install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u7_mmap] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u7_mmap] (2/4) Swap /init = $HAMSH_ELF + embed u_mmap"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u7_mmap] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u7_mmap] (4/4) Boot QEMU + run /bin/u_mmap via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending
# input (a fixed sleep races boot-time variance — see _qemu_drive.sh).
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 35 \
    -- "u_mmap" 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u7_mmap] --- captured output ---"
cat "$LOG"
echo "[test_u7_mmap] --- end output ---"

fail=0

# Per-syscall asserts. Order matters: a missing earlier marker means
# every later marker is also missing for that reason, so report each
# independently rather than short-circuiting on the first miss.

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u7_mmap] OK: $label  ('$needle')"
    else
        echo "[test_u7_mmap] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "U1/U2 ELF detect"        "Linux-ABI binary detected"
check_marker "writev(1) -> 2 iovecs"   "U7: writev ok"
check_marker "mmap/munmap round-trip"  "U7: mmap ok"

# Negative markers — these would only appear if u_mmap took an error
# path. Surface them in the test output so a regression is obvious.
if grep -F -q "U7: writev FAIL" "$LOG"; then
    echo "[test_u7_mmap] DIAG: u_mmap reported writev FAIL"
    fail=1
fi
if grep -F -q "U7: mmap FAIL" "$LOG"; then
    echo "[test_u7_mmap] DIAG: u_mmap reported mmap FAIL"
    fail=1
fi
if grep -F -q "U7: munmap FAIL" "$LOG"; then
    echo "[test_u7_mmap] DIAG: u_mmap reported munmap FAIL"
    fail=1
fi

# Sanity: hamsh kept running after the child exited. If exit_group(0)
# reaped cleanly we get back to the prompt and the test driver's
# "exit\n" hits the bye line.
if grep -F -q "[hamsh] bye." "$LOG"; then
    echo "[test_u7_mmap] OK: hamsh reaped u_mmap and exited cleanly"
else
    echo "[test_u7_mmap] MISS: hamsh did not reach bye line"
    fail=1
fi

# Diagnostic: a #PF (vector 0x0e) from user mode on the mmap write
# would surface as a do_trap printk. Surface it explicitly so the
# kernel-side gap is obvious even when the marker is missing for a
# different reason.
if grep -F -q "TRAP: vector 0x0e" "$LOG"; then
    echo "[test_u7_mmap] DIAG: kernel reported #PF — likely user-mode" \
         "touch of unmapped mmap page or stale munmap pointer"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u7_mmap] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u7_mmap] PASS — writev + mmap + munmap all working"
