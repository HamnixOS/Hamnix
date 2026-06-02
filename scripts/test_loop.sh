#!/usr/bin/env bash
# scripts/test_loop.sh — loop (file-backed block) device end-to-end.
#
# Boots the kernel once with /etc/loop-test + the FAT image fixture
# /tests/loop/disk.img planted (ENABLE_LOOP_TEST=1); init/main.ad at
# boot:37.loop calls loop_e2e_selftest() (init/main.ad), which PROVES a
# filesystem IMAGE FILE can be mounted like a real disk — Hamnix's
# equivalent of Linux `losetup /dev/loop0 disk.img; mount /dev/loop0`.
#
# The self-test (NO QEMU disk injection — the image is a regular FILE in
# the cpio initramfs):
#   * attaches /tests/loop/disk.img as /dev/blk/loop0 via loop_attach()
#     (the same path /dev/loop/ctl's "attach" verb takes),
#   * mounts the FAT driver off the loop slot (fat_init), so every
#     blk_read_sectors now lands on a pread of the backing FILE,
#   * looks up the known file HELLO.TXT and reads its bytes back through
#     the loop data path,
#   * asserts the content begins with "FAT32_MARKER".
#
# A PASS proves the whole loop data path (file -> loop_read_sectors ->
# vfs_pread_backing) is real, not stubbed.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_loop] PASS
# Fail marker:  [test_loop] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_loop] (1/3) Build userland (init + losetup)"
bash scripts/build_user.sh >/dev/null

echo "[test_loop] (2/3) Build kernel with /etc/loop-test marker + FAT image fixture"
INIT_ELF=build/user/init.elf ENABLE_LOOP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_loop] (3/3) Boot QEMU and run the loop self-test"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_loop] --- loop self-test output ---"
grep -E "\[loop\]" "$LOG" || true
echo "[test_loop] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_loop] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -qF "[loop] FAIL" "$LOG"; then
    echo "[test_loop] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_loop] PASS: $label"
    else
        echo "[test_loop] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"                  "[loop] self-test start"
check "loop0 attached"                 "[loop] /dev/blk/loop0 attached"
check "FAT mounted off loop0"          "[loop] FAT mounted off loop0"
check "HELLO.TXT content verified"     "[loop] HELLO.TXT content verified through loop device"
check "loop self-test PASS"            "[loop] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_loop] FAIL"
    exit 1
fi

echo "[test_loop] PASS — a FAT image FILE was attached as /dev/blk/loop0, mounted, and a known file read back through the loop device (file -> loop_read_sectors -> vfs_pread_backing)"
