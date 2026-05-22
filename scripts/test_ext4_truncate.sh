#!/usr/bin/env bash
# scripts/test_ext4_truncate.sh — M16.x §12.2 verification:
# ext4 truncate / ftruncate.
#
# The kernel runs ext4_truncate_smoke_test() at boot, which:
#   * creates TRUNC.TXT with a known head,
#   * GROWS it to 2.5 blocks — appends zero-filled extents — and
#     verifies i_size, the original head bytes, and that the grown
#     tail reads back as zeros,
#   * SHRINKS it back to 10 bytes — frees the now-unreachable blocks,
#     trims the leaf extents — and verifies i_size and that a read
#     past the new EOF returns 0,
#   * unlinks the leftover so the FS is left as found.
#
# This boots the kernel against build/ext4.img and asserts the
# truncate smoke marker.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_ext4_truncate] (1/4) Regenerate disk images"
python3 scripts/build_diskimg.py

echo "[test_ext4_truncate] (2/4) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_ext4_truncate] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_ext4_truncate] (4/4) Boot QEMU with ext4 image"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 40s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file=build/ext4.img,if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ext4_truncate] --- ext4 lines ---"
grep -E 'ext4: truncate' "$LOG" || true
echo "[test_ext4_truncate] --- end ---"

fail=0
if grep -F -q "ext4: truncate smoke PASS" "$LOG"; then
    echo "[test_ext4_truncate] OK: ext4 truncate (grow + shrink)"
else
    echo "[test_ext4_truncate] MISS: 'ext4: truncate smoke PASS'"
    echo "[test_ext4_truncate] --- full log ---"
    cat "$LOG"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_truncate] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_ext4_truncate] PASS"
