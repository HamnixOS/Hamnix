#!/usr/bin/env python3
# scripts/build_iso_fixture.py
#
# Builds a small ROCK RIDGE ISO9660 image for the fs/iso9660.ad boot
# self-test (scripts/test_iso9660.sh, gated ENABLE_ISO9660_TEST). The
# generated .iso is NOT committed to git — build_initramfs.py calls
# build_iso_image() at build time and bakes the bytes into the cpio at
# /tests/iso9660/test.iso, the same way build_diskimg.build_image()
# feeds the loop-device fixture.
#
# Fixture layout (what the kernel self-test asserts):
#   /HELLO.TXT                  short file, exact bytes "ISO9660_MARKER"
#   /a_long_rock_ridge_name.txt long lowercase name only expressible via
#                               a Rock Ridge NM entry (the 8.3 ISO name
#                               would be uppercased/truncated)
#   /BIG.DAT                    >1 logical sector (2048 B): 4096 bytes of
#                               a deterministic byte pattern
#   /sub/NESTED.TXT             a file one directory deep
#
# We prefer genisoimage/mkisofs/xorriso with -R (Rock Ridge). If none is
# present the build fails loudly — the test needs a real Rock Ridge ISO.

import os
import subprocess
import tempfile
from pathlib import Path

HELLO_BYTES = b"ISO9660_MARKER"
LONG_NAME = "a_long_rock_ridge_name.txt"
LONG_BYTES = b"rock-ridge-long-name-ok\n"
NESTED_BYTES = b"nested-file-contents\n"

# 4096 bytes (two logical sectors) of a deterministic pattern so the
# kernel can assert exact bytes across a 2048-byte sector boundary.
BIG_BYTES = bytes((i * 31 + 7) & 0xFF for i in range(4096))


def _find_tool():
    for tool in ("genisoimage", "mkisofs", "xorriso"):
        path = _which(tool)
        if path:
            return tool, path
    return None, None


def _which(name):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        cand = Path(d) / name
        if cand.is_file() and os.access(cand, os.X_OK):
            return str(cand)
    return None


def build_iso_image() -> bytes:
    tool, path = _find_tool()
    if tool is None:
        raise RuntimeError(
            "build_iso_fixture: need genisoimage/mkisofs/xorriso to build "
            "the Rock Ridge ISO fixture (none found on PATH)")

    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / "isoroot"
        (root / "sub").mkdir(parents=True)
        (root / "HELLO.TXT").write_bytes(HELLO_BYTES)
        (root / LONG_NAME).write_bytes(LONG_BYTES)
        (root / "BIG.DAT").write_bytes(BIG_BYTES)
        (root / "sub" / "NESTED.TXT").write_bytes(NESTED_BYTES)

        out = Path(td) / "fixture.iso"
        if tool == "xorriso":
            cmd = [path, "-as", "mkisofs", "-R", "-o", str(out), str(root)]
        else:
            # genisoimage / mkisofs: -R enables Rock Ridge (SUSP),
            # -J would add Joliet (we don't, to keep Rock Ridge primary).
            cmd = [path, "-R", "-o", str(out), str(root)]
        subprocess.run(cmd, check=True,
                       stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        return out.read_bytes()


if __name__ == "__main__":
    import sys
    data = build_iso_image()
    sys.stdout.buffer.write(data)
