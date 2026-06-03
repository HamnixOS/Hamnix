#!/usr/bin/env bash
# scripts/test_btrfs.sh — read-only btrfs reader self-test.
#
# Boots the kernel once with /etc/btrfs-test planted (ENABLE_BTRFS_TEST=1).
# build_initramfs.py builds a REAL btrfs image (scripts/build_btrfs_fixture.py,
# via mkfs.btrfs/btrfs-progs --rootdir; no root needed) and bakes it into
# the cpio at /tests/btrfs/test.img. init/main.ad at boot:37.btrfs calls
# btrfs_e2e_selftest() (fs/btrfs.ad), which:
#
#   * loop-attaches the baked image as /dev/blk/loopN,
#   * verifies the superblock magic "_BHRfS_M" at byte offset 0x10000 and
#     reads node/sector sizes + the chunk-tree and root-tree roots,
#   * seeds the logical->physical chunk map from the bootstrap
#     sys_chunk_array, reads the CHUNK B-tree for the full map, then walks
#     the ROOT B-tree to the FS_TREE (objectid 5) root,
#   * descends the FS B-tree (internal nodes + leaves) to enumerate the
#     root directory and confirm HELLO.TXT / BIG.DAT / sub are seen,
#   * reads /HELLO.TXT (INLINE extent, data in the leaf) and asserts bytes
#     "BTRFS_MARKER",
#   * reads /BIG.DAT (REGULAR extent, 300000 bytes > one 16 KiB node, read
#     through the chunk map) and asserts the deterministic pattern is
#     byte-exact,
#   * resolves + reads the nested file /sub/NESTED.TXT.
#
# The image is built at build time and kept OUT of git.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO.
#
# Pass marker:  [btrfs] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

# Pre-flight: the fixture needs mkfs.btrfs (btrfs-progs). It is often in
# /sbin rather than on PATH. If absent we cannot build a real btrfs image,
# so skip cleanly rather than fail the suite.
if ! { command -v mkfs.btrfs >/dev/null 2>&1 || [ -x /usr/sbin/mkfs.btrfs ] || [ -x /sbin/mkfs.btrfs ]; }; then
    echo "[test_btrfs] SKIP: mkfs.btrfs (btrfs-progs) not installed — cannot build btrfs fixture"
    exit 0
fi

echo "[test_btrfs] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_btrfs] (2/3) Build kernel with /etc/btrfs-test marker + btrfs image fixture"
INIT_ELF=build/user/init.elf ENABLE_BTRFS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_btrfs] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_btrfs] --- captured (btrfs lines) ---"
grep -E '\[btrfs\]' "$LOG" || true
echo "[test_btrfs] --- end ---"

fail=0

# rc 124 = timeout, 143 = SIGTERM under host load — treat as flake, not
# a logic failure, IF the PASS marker is absent (handled by check below).
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 143 ]; then
    echo "[test_btrfs] WARN: qemu exited rc=$rc" >&2
fi

if grep -qF "[btrfs] FAIL" "$LOG"; then
    echo "[test_btrfs] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[btrfs] self-test reported FAIL" "$LOG"; then
    echo "[test_btrfs] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_btrfs] PASS: $label"
    else
        echo "[test_btrfs] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"          "[btrfs] self-test start"
check "loop attached"          "[btrfs] loop device attached for .img"
check "superblock mounted"     "[btrfs] mounted"
check "root enumerated"        "[btrfs] root directory enumerated"
check "HELLO.TXT inline"       "[btrfs] /HELLO.TXT (inline extent) content verified"
check "BIG.DAT regular extent" "[btrfs] /BIG.DAT (regular extent, > one node) verified byte-exact"
check "nested file"            "[btrfs] /sub/NESTED.TXT resolved + read"
check "btrfs PASS"             "[btrfs] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_btrfs] FAIL"
    exit 1
fi

echo "[test_btrfs] PASS — read-only btrfs: superblock magic + chunk-tree bootstrap, logical->physical chunk map, ROOT + FS B-tree descent (internal nodes + leaves), directory enumerate, INLINE-extent file, REGULAR-extent file (> one node) byte-exact, and nested lookup all verified"
