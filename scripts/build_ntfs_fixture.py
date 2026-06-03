#!/usr/bin/env python3
# scripts/build_ntfs_fixture.py
#
# Builds a small NTFS image for the fs/ntfs.ad boot self-test
# (scripts/test_ntfs.sh, gated ENABLE_NTFS_TEST). The generated image is
# NOT committed to git — build_initramfs.py calls build_ntfs_image() at
# build time and bakes the bytes into the cpio at /tests/ntfs/test.img,
# the same way build_iso_fixture.build_iso_image() feeds the ISO9660
# fixture and build_diskimg.build_image() feeds the loop FAT fixture.
#
# Fixture layout (what the kernel self-test asserts):
#   /HELLO.TXT       short RESIDENT file, exact bytes "NTFS_MARKER"
#   /BIG.DAT         20000 bytes (>1 cluster), deterministic byte pattern
#                    stored NON-RESIDENT (a real $DATA runlist)
#   /sub/NESTED.TXT  a file one directory deep (exercises a nested lookup
#                    + a sub-directory's own index)
# The root directory has enough entries (the NTFS metafiles $MFT, $Boot,
# ... plus ours) that its index spills into a non-resident
# $INDEX_ALLOCATION INDX block — exercising the large-index path.
#
# We format with mkntfs (ntfs-3g's mkfs.ntfs), copy the two plain files
# with ntfscp, and add the sub/ directory via a ntfs-3g FUSE mount. If
# FUSE is unavailable the nested leg is omitted and the test covers the
# remaining legs (boot sector, MFT, fixup, resident + non-resident
# $DATA, root directory enumerate) — test_ntfs.sh reports which legs ran.

import os
import subprocess
import tempfile
from pathlib import Path

HELLO_BYTES = b"NTFS_MARKER"
NESTED_BYTES = b"nested-data"

# 20000 bytes (~5 clusters at a 4096-byte cluster) of a deterministic
# pattern so the kernel can assert exact bytes across cluster boundaries
# of a non-resident $DATA runlist.
BIG_LEN = 20000
BIG_BYTES = bytes((i * 31 + 7) & 0xFF for i in range(BIG_LEN))


def _which(name, extra_dirs=()):
    dirs = list(extra_dirs) + os.environ.get("PATH", "").split(os.pathsep)
    # ntfsprogs tools commonly live in /usr/sbin and /sbin.
    dirs += ["/usr/sbin", "/sbin", "/usr/bin", "/bin"]
    for d in dirs:
        if not d:
            continue
        cand = Path(d) / name
        if cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    return None


def have_ntfs_tools() -> bool:
    return _which("mkntfs") is not None and _which("ntfscp") is not None


def build_ntfs_image() -> bytes:
    mkntfs = _which("mkntfs")
    ntfscp = _which("ntfscp")
    if mkntfs is None or ntfscp is None:
        raise RuntimeError(
            "build_ntfs_fixture: need mkntfs + ntfscp (ntfs-3g) to build "
            "the NTFS fixture (not found on PATH/sbin)")

    with tempfile.TemporaryDirectory() as td:
        img = Path(td) / "ntfs.img"
        # 8 MiB volume, 4096-byte clusters => 1024-byte MFT records
        # (the signed clusters-per-record encoding the reader handles).
        img.write_bytes(b"\x00" * (8 * 1024 * 1024))
        subprocess.run(
            [mkntfs, "-F", "-c", "4096", "-L", "NTFSTEST", str(img)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        hello = Path(td) / "HELLO.TXT"
        hello.write_bytes(HELLO_BYTES)
        big = Path(td) / "BIG.DAT"
        big.write_bytes(BIG_BYTES)
        # ntfscp <img> <src> <dest-name-in-root>
        subprocess.run([ntfscp, str(img), str(hello), "HELLO.TXT"],
                       check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        subprocess.run([ntfscp, str(img), str(big), "BIG.DAT"],
                       check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)

        # ntfscp cannot create directories; add /sub/NESTED.TXT via a
        # ntfs-3g FUSE mount when one is available. Best-effort: the test
        # only asserts the nested leg if the marker file proves it landed.
        _try_add_subdir(td, img)

        return img.read_bytes()


def _try_add_subdir(td, img):
    ntfs3g = _which("ntfs-3g")
    fusermount = _which("fusermount") or _which("fusermount3")
    if ntfs3g is None:
        return
    mnt = Path(td) / "mnt"
    mnt.mkdir()
    try:
        r = subprocess.run([ntfs3g, str(img), str(mnt)],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        if r.returncode != 0:
            return
        mounted = True
    except Exception:
        return
    try:
        sub = mnt / "sub"
        sub.mkdir()
        (sub / "NESTED.TXT").write_bytes(NESTED_BYTES)
        subprocess.run(["sync"], check=False)
    finally:
        if fusermount:
            subprocess.run([fusermount, "-u", str(mnt)],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        else:
            subprocess.run(["umount", str(mnt)],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    import sys
    data = build_ntfs_image()
    sys.stdout.buffer.write(data)
