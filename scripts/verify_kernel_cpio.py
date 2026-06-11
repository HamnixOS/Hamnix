#!/usr/bin/env python3
"""
scripts/verify_kernel_cpio.py — assert a compiled kernel ELF embeds the
INTENDED initramfs cpio (#410 Item 1: hard cpio-intent assert).

WHY THIS EXISTS
---------------
scripts/build_installer_img.sh compiles TWO kernels in one run:

  * Stage 3 INSTALLED kernel  (HAMNIX_CPIO_EMPTY=1)     — must NOT carry
    /init or /rootfs.sqfs (it boots off the NVMe ext4 root).
  * Stage 6 INSTALLER kernel  (HAMNIX_INSTALLER_BLOB=1) — MUST carry
    /init and /rootfs.sqfs plus the full live userland.

A stale or raced fs/initramfs_blob.S once produced an installer image
whose kernel cpio held only 2 files — no /init — and the shipped image
booted to a ring3 #UD. The blob-race itself is fixed (HAMNIX_BUILD_DIR
isolation), but nothing ASSERTED the compiled kernel actually embeds the
intended cpio. This script is that assert: it scans the ACTUAL ELF BYTES
for the embedded newc archive, walks it entry-by-entry to the trailer,
and compares the recovered name list against the manifest that
build_initramfs.py emitted next to the blob it generated. A mismatch
(the raced-artifact case) ERRORS the build instead of shipping.

Checks performed (all against real bytes, not build-script intent):
  1. The ELF contains a walkable newc cpio archive ("070701" magic,
     header-chained to TRAILER!!!).
  2. The archive's entry-name set EQUALS the manifest's (stale-blob
     detector — a fresh manifest vs an old blob can never agree).
  3. --require PATH ... : every PATH is present in the archive.
  4. --forbid  PATH ... : no PATH is present in the archive.
  5. --min-elf-size N   : the ELF file is at least N bytes (e.g. the
     installer kernel must exceed the squashfs payload it embeds).
  6. --max-elf-size N   : the ELF file is at most N bytes (e.g. the
     installed kernel must be far smaller than the squashfs payload).

Usage (from build_installer_img.sh):
  python3 scripts/verify_kernel_cpio.py \
      --elf build/hamnix-installer-kernel.elf \
      --manifest build/initramfs_blob.S.manifest \
      --require /init --require /rootfs.sqfs \
      --min-elf-size "$SQFS_BYTES"

Exit status: 0 = all checks pass; 1 = any check failed (build must abort).
"""

import argparse
import sys

MAGIC = b"070701"
HDR_LEN = 110                      # 6-byte magic + 13 8-char hex fields
TRAILER = "TRAILER!!!"


def _hex_field(buf: bytes, off: int) -> int:
    """Parse one 8-char uppercase-hex header field; raise on non-hex."""
    field = buf[off:off + 8]
    if len(field) != 8:
        raise ValueError("truncated header field")
    return int(field, 16)


def _parse_entry(buf: bytes, off: int):
    """Parse one newc entry at `off`.

    Returns (name, next_off) or raises ValueError if the bytes at `off`
    are not a well-formed entry (the false-candidate filter).
    """
    if buf[off:off + 6] != MAGIC:
        raise ValueError("bad magic")
    hdr = buf[off:off + HDR_LEN]
    if len(hdr) < HDR_LEN:
        raise ValueError("truncated header")
    # All 13 fields must be hex (rejects random '070701' in data).
    fields = [_hex_field(hdr, 6 + i * 8) for i in range(13)]
    filesize = fields[6]
    namesize = fields[11]
    if namesize < 2 or namesize > 4096:
        raise ValueError("implausible namesize")
    name_start = off + HDR_LEN
    name_bytes = buf[name_start:name_start + namesize]
    if len(name_bytes) < namesize or name_bytes[-1] != 0:
        raise ValueError("name not NUL-terminated")
    name = name_bytes[:-1].decode("ascii", errors="strict")
    if any(ord(c) < 0x20 or ord(c) > 0x7e for c in name):
        raise ValueError("non-printable name")
    # Pad after name so data starts 4-aligned from entry start; pad
    # after data so the next entry is 4-aligned (cpio(5) newc rules,
    # mirrored from build_initramfs.py's cpio_entry()).
    name_field_len = HDR_LEN + namesize
    name_pad = (-name_field_len) % 4
    data_start = name_start + namesize + name_pad
    data_pad = (-filesize) % 4
    next_off = data_start + filesize + data_pad
    if next_off > len(buf):
        raise ValueError("entry runs past end of buffer")
    return name, next_off


def walk_newc(buf: bytes, start: int):
    """Walk a newc archive starting at `start` until TRAILER!!!.

    Returns (names, end_off) with the trailer excluded from names, or
    None if the walk fails at any entry (false candidate).
    """
    names = []
    off = start
    # Hard ceiling so a pathological false candidate can't loop forever.
    for _ in range(1_000_000):
        try:
            name, off = _parse_entry(buf, off)
        except (ValueError, UnicodeDecodeError):
            return None
        if name == TRAILER:
            return names, off
        names.append(name)
    return None


def find_archives(buf: bytes):
    """Return [(offset, names)] for every walkable newc archive in buf.

    Candidates are every occurrence of the magic; a candidate that is
    merely the magic bytes inside file data fails the chained walk
    almost immediately. Candidates that fall INSIDE an already-walked
    archive (the magic of entry 2..N, or magic bytes inside entry data)
    are skipped.
    """
    found = []
    covered_until = -1
    off = buf.find(MAGIC)
    while off != -1:
        if off > covered_until:
            walked = walk_newc(buf, off)
            if walked is not None:
                names, end = walked
                found.append((off, names))
                covered_until = end - 1
        off = buf.find(MAGIC, off + 1)
    return found


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--elf", required=True, help="compiled kernel ELF")
    ap.add_argument("--manifest", required=True,
                    help="manifest emitted by build_initramfs.py "
                         "(one cpio path per line)")
    ap.add_argument("--require", action="append", default=[],
                    metavar="PATH", help="path that MUST be in the cpio")
    ap.add_argument("--forbid", action="append", default=[],
                    metavar="PATH", help="path that must NOT be in the cpio")
    ap.add_argument("--min-elf-size", type=int, default=0,
                    help="ELF file must be at least this many bytes")
    ap.add_argument("--max-elf-size", type=int, default=0,
                    help="ELF file must be at most this many bytes (0=off)")
    args = ap.parse_args()

    tag = "[verify_kernel_cpio]"
    fail = 0

    with open(args.elf, "rb") as f:
        elf = f.read()
    elf_size = len(elf)

    with open(args.manifest, "r", encoding="utf-8") as f:
        manifest = {line.rstrip("\n") for line in f if line.strip()}

    # --- ELF size envelope ------------------------------------------
    if args.min_elf_size and elf_size < args.min_elf_size:
        print(f"{tag} FAIL: {args.elf} is {elf_size} bytes; expected "
              f">= {args.min_elf_size} (the embedded payload alone is "
              f"bigger — the kernel cannot be carrying it)", file=sys.stderr)
        fail = 1
    if args.max_elf_size and elf_size > args.max_elf_size:
        print(f"{tag} FAIL: {args.elf} is {elf_size} bytes; expected "
              f"<= {args.max_elf_size} (an empty-cpio kernel must be far "
              f"smaller — is the installer payload baked into it?)",
              file=sys.stderr)
        fail = 1

    # --- locate + walk the embedded archive --------------------------
    archives = find_archives(elf)
    if not archives:
        print(f"{tag} FAIL: no walkable newc cpio archive found in "
              f"{args.elf} (no '070701'-chained entries reach TRAILER!!!)",
              file=sys.stderr)
        return 1
    if len(archives) > 1:
        offs = ", ".join(hex(o) for o, _ in archives)
        print(f"{tag} FAIL: {len(archives)} distinct cpio archives found "
              f"in {args.elf} (at {offs}); expected exactly one embedded "
              f"initramfs", file=sys.stderr)
        return 1
    arc_off, names = archives[0]
    name_set = set(names)
    print(f"{tag} {args.elf}: cpio archive at offset {arc_off:#x}, "
          f"{len(names)} entries; ELF {elf_size} bytes.")

    # --- manifest equality (the stale-blob detector) ------------------
    if name_set != manifest:
        only_elf = sorted(name_set - manifest)[:10]
        only_man = sorted(manifest - name_set)[:10]
        print(f"{tag} FAIL: ELF cpio does not match the manifest "
              f"{args.manifest} — the compiled kernel embeds a STALE or "
              f"WRONG initramfs blob.", file=sys.stderr)
        if only_elf:
            print(f"{tag}   in ELF only ({len(name_set - manifest)}): "
                  f"{only_elf}", file=sys.stderr)
        if only_man:
            print(f"{tag}   in manifest only ({len(manifest - name_set)}): "
                  f"{only_man}", file=sys.stderr)
        fail = 1

    # --- intent: required / forbidden paths ---------------------------
    for p in args.require:
        if p not in name_set:
            print(f"{tag} FAIL: required cpio path '{p}' is MISSING from "
                  f"{args.elf}", file=sys.stderr)
            fail = 1
    for p in args.forbid:
        if p in name_set:
            print(f"{tag} FAIL: forbidden cpio path '{p}' is PRESENT in "
                  f"{args.elf}", file=sys.stderr)
            fail = 1

    if fail:
        return 1
    print(f"{tag} OK: cpio intent verified "
          f"(manifest match + {len(args.require)} required / "
          f"{len(args.forbid)} forbidden paths).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
