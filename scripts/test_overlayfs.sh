#!/usr/bin/env bash
# scripts/test_overlayfs.sh — Linux-style overlayfs (union FS) self-test.
#
# Boots the kernel once with /etc/overlayfs-test planted
# (ENABLE_OVERLAYFS_TEST=1). init/main.ad at boot:37.ovl calls
# overlayfs_selftest() (fs/overlayfs.ad), which builds a two-layer overlay
# backed by the in-memory tmpfs (one read-only LOWER + one writable UPPER)
# and PROVES the four core overlayfs behaviours:
#
#   * UPPER SHADOWS LOWER: a name present in both layers resolves to the
#     upper copy ('shadowed' reads "UPPERV", not the lower "LOWERV").
#   * COPY-UP ON WRITE: opening a lower-only file for write copies it into
#     the upper layer first; the merged file then reads the new bytes
#     ("COPIEDUP") while the LOWER copy stays byte-for-byte pristine
#     ("LOWERDATA").
#   * WHITEOUT ON DELETE: deleting a lower-only file drops a ".wh.<name>"
#     marker in upper so the name vanishes from the merged view; the
#     read-only lower file is never touched. Re-creating the name over the
#     whiteout makes it live again (the marker is cleared).
#   * MERGED READDIR: a directory listing is the deduplicated union of
#     upper + lower entries (upper wins collisions), whiteout markers are
#     hidden, and whiteouted names are removed.
#
# The self-test needs NO external disk — both layers are tmpfs subtrees, so
# the boot is fully deterministic.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [overlayfs] PASS
# Fail marker:  [overlayfs] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_overlayfs] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_overlayfs] (2/3) Build kernel with /etc/overlayfs-test marker"
INIT_ELF=build/user/init.elf ENABLE_OVERLAYFS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_overlayfs] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_overlayfs] --- captured (overlayfs lines) ---"
grep -E '\[overlayfs\]' "$LOG" || true
echo "[test_overlayfs] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_overlayfs] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[overlayfs] FAIL" "$LOG"; then
    echo "[test_overlayfs] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[overlayfs] self-test reported FAIL" "$LOG"; then
    echo "[test_overlayfs] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_overlayfs] PASS: $label"
    else
        echo "[test_overlayfs] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"          "[overlayfs] self-test start"
check "upper shadows lower"    "[overlayfs] upper-shadows-lower: 'shadowed' reads UPPERV OK"
check "copy-up on write"       "[overlayfs] copy-up-on-write: upper has COPIEDUP, lower still LOWERDATA OK"
check "whiteout on delete"     "[overlayfs] whiteout-on-delete: 'to_delete' hidden, lower pristine OK"
check "recreate over whiteout" "[overlayfs] recreate-over-whiteout: 'to_delete' live again OK"
check "merged readdir dedup"   "[overlayfs] merged-readdir: union deduped, whiteout hidden, count=4 OK"
check "overlayfs PASS"         "[overlayfs] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_overlayfs] FAIL"
    exit 1
fi

echo "[test_overlayfs] PASS — overlayfs: upper-shadows-lower, copy-up-on-write (lower pristine), whiteout-on-delete + recreate, and deduped merged readdir all verified"
