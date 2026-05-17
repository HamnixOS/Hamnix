#!/usr/bin/env bash
# scripts/test_u6_multi.sh - U6 milestone: multi-syscall Linux ELF.
#
# Boots Hamnix with /bin/u_multi embedded in the initramfs and drives
# hamsh to exec it. u_multi is a host-built, static, OSABI=Linux x86_64
# ELF whose _start exercises five Linux syscalls in sequence:
#
#     write(1, "U6: start\n", 10)
#     getpid()                    -> expect rax >= 1, prints "U6: pid ok"
#     clock_gettime(CLOCK_MONOTONIC, &ts)
#                                 -> expect rax == 0, prints "U6: clock ok"
#     brk(NULL)                   -> expect non-zero, prints "U6: brk0 ok",
#                                    then *base = 0xAA (touches kmalloc page)
#     brk(prev + 0x1000)          -> expect grow, prints "U6: brk1 ok",
#                                    then *(base+0x800) = 0xBB
#     write(1, "U6: done\n", 9)
#     exit_group(0)
#
# Each marker is a discrete success signal: if "U6: pid ok" is missing
# but "U6: start" is present, the kernel's getpid path is broken. If
# "U6: brk0 ok" is missing or the kernel halted at a #PF trap on the
# user write, the kmalloc-backed brk region isn't user-accessible
# (or brk() returned 0). The harness reports each marker individually.
#
# Skip-on-missing: if tests/u-binary/u_multi hasn't been built on the
# host (`make -C tests/u-binary/src/multi install`), exit 0 with a
# notice so CI in environments without `as`/`ld` still passes.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_multi
if [ ! -f "$UBIN" ]; then
    echo "[test_u6_multi] SKIP: $UBIN not staged"
    echo "    Build with: make -C tests/u-binary/src/multi install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u6_multi] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u6_multi] (2/4) Swap /init = $HAMSH_ELF + embed u_multi"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u6_multi] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u6_multi] (4/4) Boot QEMU + run /bin/u_multi via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_multi\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_u6_multi] --- captured output ---"
cat "$LOG"
echo "[test_u6_multi] --- end output ---"

fail=0

# Per-syscall asserts. Order matters: a missing earlier marker means
# every later marker is also missing for that reason, so report each
# independently rather than short-circuiting on the first miss.

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u6_multi] OK: $label  ('$needle')"
    else
        echo "[test_u6_multi] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "U1/U2 ELF detect"  "Linux-ABI binary detected"
check_marker "write(1)"          "U6: start"
check_marker "getpid"            "U6: pid ok"
check_marker "clock_gettime"     "U6: clock ok"
check_marker "brk(NULL) + *base" "U6: brk0 ok"
check_marker "brk(grow) + *mid"  "U6: brk1 ok"
check_marker "exit_group reached" "U6: done"

# Sanity: hamsh kept running after the child exited. If exit_group(0)
# reaped cleanly we get back to the prompt and the test driver's
# "exit\n" hits the bye line.
if grep -F -q "[hamsh] bye." "$LOG"; then
    echo "[test_u6_multi] OK: hamsh reaped u_multi and exited cleanly"
else
    echo "[test_u6_multi] MISS: hamsh did not reach bye line"
    fail=1
fi

# Diagnostic: a #PF (vector 0x0e) from user mode on the brk write
# would surface as a do_trap printk. Surface it explicitly so the
# kernel-side gap is obvious in the test output even if "U6: brk0 ok"
# is missing for a different reason.
if grep -F -q "TRAP: vector 0x0e" "$LOG"; then
    echo "[test_u6_multi] DIAG: kernel reported #PF — likely user-mode" \
         "write to non-U=1 kmalloc page"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u6_multi] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u6_multi] PASS — getpid + clock_gettime + brk all working"
