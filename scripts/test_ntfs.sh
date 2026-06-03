#!/usr/bin/env bash
# scripts/test_ntfs.sh — read-only NTFS reader self-test.
#
# Boots the kernel once with /etc/ntfs-test planted (ENABLE_NTFS_TEST=1).
# build_initramfs.py builds a REAL NTFS image (scripts/build_ntfs_fixture.py,
# via mkntfs/ntfs-3g) and bakes it into the cpio at /tests/ntfs/test.img.
# init/main.ad at boot:37.ntfs calls ntfs_e2e_selftest() (fs/ntfs.ad),
# which:
#
#   * loop-attaches the baked image as /dev/blk/loopN,
#   * parses the boot sector/BPB (bytes-per-sector, sectors-per-cluster,
#     MFT LCN, the SIGNED clusters-per-MFT-record encoding) and decodes
#     the $MFT's own non-resident $DATA runlist,
#   * enumerates the root directory (MFT ref 5) via $INDEX_ROOT plus the
#     non-resident $INDEX_ALLOCATION INDX block (each USN-fixed-up), and
#     confirms HELLO.TXT + BIG.DAT are seen,
#   * reads /HELLO.TXT (RESIDENT $DATA) and asserts bytes "NTFS_MARKER",
#   * reads /BIG.DAT (NON-RESIDENT $DATA, multi-cluster runlist, 20000
#     bytes) and asserts the deterministic pattern is byte-exact,
#   * resolves /sub/NESTED.TXT (best-effort; only present when the fixture
#     builder had a FUSE mount available).
#
# The image is built at build time and kept OUT of git.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO.
#
# Pass marker:  [ntfs] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

# Pre-flight: the fixture needs mkntfs + ntfscp (ntfs-3g). If they are
# absent we cannot build a real NTFS image, so skip cleanly rather than
# fail the suite.
if ! { command -v mkntfs >/dev/null 2>&1 || [ -x /usr/sbin/mkntfs ] || [ -x /sbin/mkntfs ]; }; then
    echo "[test_ntfs] SKIP: mkntfs (ntfs-3g) not installed — cannot build NTFS fixture"
    exit 0
fi

echo "[test_ntfs] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_ntfs] (2/3) Build kernel with /etc/ntfs-test marker + NTFS image fixture"
INIT_ELF=build/user/init.elf ENABLE_NTFS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ntfs] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ntfs] --- captured (ntfs lines) ---"
grep -E '\[ntfs\]' "$LOG" || true
echo "[test_ntfs] --- end ---"

fail=0

# rc 124 = timeout, 143 = SIGTERM under host load — treat as flake, not
# a logic failure, IF the PASS marker is absent (handled by check below).
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 143 ]; then
    echo "[test_ntfs] WARN: qemu exited rc=$rc" >&2
fi

if grep -qF "[ntfs] FAIL" "$LOG"; then
    echo "[test_ntfs] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[ntfs] self-test reported FAIL" "$LOG"; then
    echo "[test_ntfs] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_ntfs] PASS: $label"
    else
        echo "[test_ntfs] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"          "[ntfs] self-test start"
check "loop attached"          "[ntfs] loop device attached for .img"
check "boot sector mounted"    "[ntfs] mounted"
check "root enumerated"        "[ntfs] root directory enumerated"
check "HELLO.TXT resident"     "[ntfs] /HELLO.TXT (resident) content verified"
check "BIG.DAT non-resident"   "[ntfs] /BIG.DAT (non-resident multi-cluster) verified byte-exact"
check "ntfs PASS"              "[ntfs] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_ntfs] FAIL"
    exit 1
fi

echo "[test_ntfs] PASS — read-only NTFS: boot sector/BPB parse, signed MFT-record encoding, \$MFT runlist, USN fixup, resident + non-resident multi-cluster \$DATA, and root directory enumerate (INDEX_ROOT + INDEX_ALLOCATION) all verified"
