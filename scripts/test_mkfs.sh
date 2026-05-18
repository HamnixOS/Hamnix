#!/usr/bin/env bash
# scripts/test_mkfs.sh — M16.x verification: in-kernel ext4_mkfs
# formats a freshly-partitioned AHCI slice as ext4, then re-mounts +
# walks the root directory to confirm the bytes we wrote are coherent.
#
# Pipeline:
#   1. Build userland + modules + initramfs.
#   2. Build the test fixture tests/test_mkfs.ad to
#      build/user/test_mkfs.elf (lands at /bin/test_mkfs in the cpio).
#   3. Rebuild the kernel image so ext4_mkfs + self-test compile in.
#   4. Mint a 64 MiB tmpfile + lay down a single MBR primary
#      partition (LBA 2048..65535, 63488 sectors = 31 MiB) via sfdisk
#      — same shape test_partition_naming.sh uses.
#   5. Boot QEMU with the partitioned tmpfile attached over AHCI
#      AND build/ext4.img attached over virtio-blk (so ext4_init
#      mounts /ext on vda; userland's /bin/test_mkfs opens /ext/...
#      to wake the lazy mkfs self-test hook on sd0p1).
#   6. Grep the serial log for the PASS markers.
#
# Assertion markers:
#
#   "[ext4] mkfs sd0p1 OK"
#   "[ext4] mounted sd0p1 ro=0"
#   "[ext4] / contains . .."
#   "[ext4] mkfs self-test PASS"
#   "blk: registered 'sd0p1' capacity=63488 sectors"
#   "[mkfs] fixture OK"

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_mkfs.elf

# Locate sfdisk (some hosts put it in /sbin which the user $PATH
# doesn't include).
SFDISK=
for cand in sfdisk /sbin/sfdisk /usr/sbin/sfdisk; do
    if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then
        SFDISK="$cand"
        break
    fi
done
if [ -z "$SFDISK" ]; then
    echo "[test_mkfs] SKIP: sfdisk not found on host" >&2
    exit 0
fi

echo "[test_mkfs] (1/6) Build userland + modules"
if [ ! -f build/user/init.elf ]; then
    bash scripts/build_user.sh >/dev/null
    bash scripts/build_modules.sh >/dev/null
fi

echo "[test_mkfs] (2/6) Build tests/test_mkfs.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_mkfs.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_mkfs] (3/6) Regenerate disk images + plant /init = hamsh + /bin/test_mkfs"
python3 scripts/build_diskimg.py >/dev/null 2>&1 || python3 scripts/build_diskimg.py
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_mkfs] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_mkfs] (5/6) Mint a 64 MiB AHCI disk + single MBR primary"
DISK=$(mktemp --suffix=.mkfs-ahci.img)
dd if=/dev/zero of="$DISK" bs=1M count=64 status=none
"$SFDISK" --no-tell-kernel --no-reread "$DISK" >/dev/null <<'SFEOF'
label: dos
unit: sectors

start=2048, size=63488, type=83
SFEOF

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_mkfs] (6/6) Boot QEMU with AHCI partition + virtio ext4 disk"
set +e
(
    sleep 4
    printf '/bin/test_mkfs\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=hd0 \
    -device ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
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

echo "[test_mkfs] --- captured (ext4 / mkfs / blk / partition lines) ---"
grep -E '\[ext4\]|\[mkfs\]|\[partition\]|blk: registered' "$LOG" || true
echo "[test_mkfs] --- end ---"

fail=0
for needle in \
    "blk: registered 'sd0p1' capacity=63488 sectors" \
    "[ext4] mkfs sd0p1 OK" \
    "[ext4] mounted sd0p1 ro=0" \
    "[ext4] / contains . .." \
    "[ext4] mkfs self-test PASS" \
    "[mkfs] fixture OK"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_mkfs] OK: '$needle'"
    else
        echo "[test_mkfs] MISS: '$needle'"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_mkfs] FAIL (qemu rc=$rc)"
    echo "[test_mkfs] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_mkfs] PASS"
