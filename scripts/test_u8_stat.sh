#!/usr/bin/env bash
# scripts/test_u8_stat.sh — U8 milestone: uname + fstat + newfstatat.
#
# Boots Hamnix with /bin/u_stat embedded in the initramfs and drives
# hamsh to exec it. u_stat is a host-built, static, OSABI=Linux x86_64
# ELF whose _start exercises three syscalls that were -ENOSYS stubs
# before U8:
#
#     uname(&uts_buf)                 -> rax == 0, prints "U8: uname ok"
#     open("/etc/motd", O_RDONLY)     -> rax = fd
#     fstat(fd, &stat_buf)            -> rax == 0, st_size > 0,
#                                          prints "U8: fstat ok"
#     newfstatat(AT_FDCWD, "/etc/motd", &stat_buf, 0)
#                                       -> rax == 0, st_size > 0,
#                                          prints "U8: newfstatat ok"
#     exit_group(0)
#
# Each marker is a discrete success signal: a missing earlier marker
# means every later marker is also missing for that reason, so we
# report each independently rather than short-circuiting on the
# first miss.
#
# Skip-on-missing: if tests/u-binary/u_stat hasn't been built on the
# host (`make -C tests/u-binary/src/stat install`), exit 0 with a
# notice so CI in environments without `as`/`ld` still passes.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_stat
if [ ! -f "$UBIN" ]; then
    echo "[test_u8_stat] SKIP: $UBIN not staged"
    echo "    Build with: make -C tests/u-binary/src/stat install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u8_stat] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u8_stat] (2/4) Swap /init = $HAMSH_ELF + embed u_stat"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u8_stat] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u8_stat] (4/4) Boot QEMU + run /bin/u_stat via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_stat\n'
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

echo "[test_u8_stat] --- captured output ---"
cat "$LOG"
echo "[test_u8_stat] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u8_stat] OK: $label  ('$needle')"
    else
        echo "[test_u8_stat] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "U1/U2 ELF detect"  "Linux-ABI binary detected"
check_marker "uname"             "U8: uname ok"
check_marker "fstat"             "U8: fstat ok"
check_marker "newfstatat"        "U8: newfstatat ok"

# Negative markers — these only appear if u_stat hit an error path.
# Surface them in the test output so a regression is obvious.
for negmark in \
    "U8: uname FAIL" \
    "U8: open FAIL" \
    "U8: fstat FAIL" \
    "U8: fstat size FAIL" \
    "U8: newfstatat FAIL" \
    "U8: newfstatat size FAIL"
do
    if grep -F -q "$negmark" "$LOG"; then
        echo "[test_u8_stat] DIAG: u_stat reported '$negmark'"
        fail=1
    fi
done

# Sanity: hamsh kept running after the child exited.
if grep -F -q "[hamsh] bye." "$LOG"; then
    echo "[test_u8_stat] OK: hamsh reaped u_stat and exited cleanly"
else
    echo "[test_u8_stat] MISS: hamsh did not reach bye line"
    fail=1
fi

# Diagnostic: a #PF (vector 0x0e) from user mode on the stat write
# would surface as a do_trap printk. Surface it explicitly so the
# kernel-side gap is obvious even when the marker is missing for a
# different reason.
if grep -F -q "TRAP: vector 0x0e" "$LOG"; then
    echo "[test_u8_stat] DIAG: kernel reported #PF — likely user-mode" \
         "write to non-U=1 .bss page"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u8_stat] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u8_stat] PASS — uname + fstat + newfstatat all working"
