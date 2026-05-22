#!/usr/bin/env bash
# scripts/test_inflate_realgz.sh — OFFLINE repro for the streaming
# gzip inflater against a REAL Debian main/Packages.gz.
#
# The small synthetic fixtures in scripts/test_inflate.sh did NOT
# catch the cross-chunk dynamic-Huffman-header resume bug — only a
# real-world Packages.gz, fed in 64 KiB chunks, exercises a chunk
# boundary landing inside a dynamic block's run-length-encoded
# code-length list (the bug: a 16/17/18 repeat code decoded just
# before an input-starvation yield was lost on resume).
#
# This test is fully offline + deterministic:
#   1. scripts/build_realgz_img.py fetches the genuine
#      deb.debian.org `stable main` Packages.gz ONCE (cached at
#      build/cache/Packages.gz) and bakes it onto a virtio-blk ext4
#      disk image build/realgz.img.
#   2. The kernel auto-mounts the ext4 disk at /ext.
#   3. tests/test_inflate_realgz.ad reads /ext/Packages.gz in 64 KiB
#      chunks and streams them through inflate_feed; the inflater
#      verifies the gzip CRC32 + ISIZE trailer internally.
#
# PASS criterion: "[realgz] PASS" in the serial log.
#
# If the real file cannot be fetched and is not cached, the test
# SKIPs (exit 0) rather than failing — an offline box must not
# spuriously break CI. A genuine inflate regression always FAILs.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_inflate_realgz.elf

echo "[test_inflate_realgz] (1/6) Fetch real Packages.gz + build ext4 disk image"
if ! python3 scripts/build_realgz_img.py; then
    echo "[test_inflate_realgz] SKIP: real Packages.gz unavailable (offline?)"
    exit 0
fi

echo "[test_inflate_realgz] (2/6) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_inflate_realgz] (3/6) Build tests/test_inflate_realgz.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_inflate_realgz.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_inflate_realgz] (4/6) Plant /init = hamsh + /bin/test_inflate_realgz"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_inflate_realgz] (5/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_inflate_realgz] (6/6) Boot QEMU with realgz.img as virtio-blk"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_inflate_realgz\n'
    # Inflating ~50 MB takes a while in the emulator — give it room.
    sleep 35
    printf 'exit\n'
    sleep 1
) | timeout 90s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file=build/realgz.img,if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_inflate_realgz] --- captured output ---"
cat "$LOG"
echo "[test_inflate_realgz] --- end output ---"

fail=0

if grep -F -q "[realgz] start" "$LOG"; then
    echo "[test_inflate_realgz] OK: test binary ran"
else
    echo "[test_inflate_realgz] MISS: [realgz] start banner absent"
    fail=1
fi

if grep -F -q "[realgz] FAIL" "$LOG"; then
    echo "[test_inflate_realgz] MISS: inflater reported failure:"
    grep -F "[realgz]" "$LOG" | sed 's/^/  /'
    fail=1
fi

if grep -F -q "[realgz] gzip CRC32 + ISIZE trailer verified" "$LOG"; then
    echo "[test_inflate_realgz] OK: gzip trailer (CRC32 + ISIZE) verified"
else
    echo "[test_inflate_realgz] MISS: trailer-verified line absent"
    fail=1
fi

if grep -F -q "[realgz] PASS" "$LOG"; then
    echo "[test_inflate_realgz] OK: reached PASS"
else
    echo "[test_inflate_realgz] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_inflate_realgz] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_inflate_realgz] PASS"
