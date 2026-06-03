#!/usr/bin/env python3
# scripts/build_btrfs_fixture.py
#
# Builds a small SINGLE-DEVICE, SINGLE-PROFILE, UNCOMPRESSED btrfs image
# for the fs/btrfs.ad boot self-test (scripts/test_btrfs.sh, gated
# ENABLE_BTRFS_TEST). The generated image is NOT committed to git —
# build_initramfs.py calls build_btrfs_image() at build time and bakes
# the bytes into the cpio at /tests/btrfs/test.img, the same way the
# ISO9660 / NTFS / loop-FAT fixtures are produced.
#
# Fixture layout (what the kernel self-test asserts):
#   /HELLO.TXT        short file -> INLINE extent, exact bytes
#                     "BTRFS_MARKER"
#   /BIG.DAT          large file (> one 16 KiB node) -> a REGULAR extent;
#                     a deterministic byte pattern, read back byte-exact
#   /sub/NESTED.TXT   a file one directory deep (B-tree directory lookup
#                     across a subdir's own DIR_ITEMs)
#   /pad_NN.txt       a handful of padding files so the FS tree grows
#                     past a single leaf into a level-1 B-tree, exercising
#                     internal-node descent.
#
# mkfs.btrfs (btrfs-progs) builds the image from a directory with
# --rootdir, which needs NO root privileges and NO loop/FUSE mount. We
# force -m single -d single (single profile), nodesize 16384, sectorsize
# 4096, and rely on the default (no compression) so every extent is
# uncompressed. If mkfs.btrfs is absent the build fails loudly — the test
# needs a real btrfs image.

import os
import subprocess
import tempfile
from pathlib import Path

HELLO_BYTES = b"BTRFS_MARKER"
NESTED_BYTES = b"nested-file-contents\n"

# 300000 bytes (> one 16 KiB node, multiple data pages) of a
# deterministic pattern so the kernel can assert exact bytes through a
# REGULAR extent read via the chunk map.
BIG_LEN = 300000
BIG_BYTES = bytes((i * 31 + 7) & 0xFF for i in range(BIG_LEN))

# Candidate locations for mkfs.btrfs (often in /sbin, not on PATH).
_MKFS_CANDIDATES = (
    "mkfs.btrfs",
    "/sbin/mkfs.btrfs",
    "/usr/sbin/mkfs.btrfs",
    "/usr/local/sbin/mkfs.btrfs",
)


def _find_mkfs():
    # PATH search first.
    for d in os.environ.get("PATH", "").split(os.pathsep):
        cand = Path(d) / "mkfs.btrfs"
        if cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    # Then the well-known sbin locations.
    for c in _MKFS_CANDIDATES:
        p = Path(c)
        if p.is_file() and os.access(p, os.X_OK):
            return str(p)
    return None


def build_btrfs_image() -> bytes:
    mkfs = _find_mkfs()
    if mkfs is None:
        raise RuntimeError(
            "build_btrfs_fixture: need mkfs.btrfs (btrfs-progs) to build "
            "the btrfs fixture (not found on PATH or in /sbin)")

    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / "btrfsroot"
        (root / "sub").mkdir(parents=True)
        (root / "HELLO.TXT").write_bytes(HELLO_BYTES)
        (root / "BIG.DAT").write_bytes(BIG_BYTES)
        (root / "sub" / "NESTED.TXT").write_bytes(NESTED_BYTES)
        # Padding files push the FS tree past a single leaf so the reader
        # exercises internal-node (level>0) descent.
        for i in range(1, 81):
            (root / ("pad_%02d.txt" % i)).write_bytes(
                ("pad-%d\n" % i).encode())

        out = Path(td) / "fixture.btrfs"
        # 128 MiB backing file (mkfs.btrfs --rootdir sizes the fs to fit
        # the file). single profile, 16 KiB nodes, 4 KiB sectors,
        # default checksum, no compression. Kept small so the baked cpio
        # stays lean.
        out.write_bytes(b"\x00" * (128 * 1024 * 1024))
        cmd = [
            mkfs,
            "--rootdir", str(root),
            "-m", "single",
            "-d", "single",
            "-n", "16384",
            "-s", "4096",
            "-f",
            str(out),
        ]
        subprocess.run(cmd, check=True,
                       stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        return out.read_bytes()


if __name__ == "__main__":
    import sys
    data = build_btrfs_image()
    sys.stdout.buffer.write(data)
