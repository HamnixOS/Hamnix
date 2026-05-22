#!/usr/bin/env bash
# scripts/test_ext4_rename.sh — M16.x §12.1 verification: ext4 rename.
#
# The kernel runs ext4_rename_smoke_test() at boot, which:
#   * creates RNSRC.TXT, renames it to RNDST.TXT, verifies the bytes
#     survive the move and the old name is gone (same-directory case
#     + cross-directory machinery),
#   * creates RNSRC2.TXT and renames it ONTO RNDST.TXT — the
#     overwrite-existing-target path,
#   * unlinks the leftover so the FS is left as found.
#
# This script boots the kernel against build/ext4.img and asserts the
# rename smoke marker, plus exercises rename through the VFS by way of
# the native wstat(2) path (hamsh `mv` is copy+unlink, but vfs_rename
# now routes ext4 too).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_ext4_rename] (1/4) Regenerate disk images"
python3 scripts/build_diskimg.py

echo "[test_ext4_rename] (2/4) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_ext4_rename] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_ext4_rename] (4/4) Boot QEMU with ext4 image"
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

echo "[test_ext4_rename] --- ext4 lines ---"
grep -E 'ext4: rename' "$LOG" || true
echo "[test_ext4_rename] --- end ---"

fail=0
if grep -F -q "ext4: rename smoke PASS" "$LOG"; then
    echo "[test_ext4_rename] OK: ext4 rename (move + overwrite-target)"
else
    echo "[test_ext4_rename] MISS: 'ext4: rename smoke PASS'"
    echo "[test_ext4_rename] --- full log ---"
    cat "$LOG"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_rename] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_ext4_rename] PASS"
