#!/usr/bin/env python3
"""
scripts/build_diskimg.py — generates the baked-in disk image that
drivers/block/brd.py registers as /dev/ram0.

M16.43 builds it as a minimal FAT32-layout image containing one
file (HELLO.TXT) with a known marker. Real FAT32 spec wants
>= 65525 data clusters, which is impractical to bake into the
kernel; our parser is lenient about that minimum.  Everything else
about the layout matches Linux's fs/fat/ expectations:

  bytes_per_sector     512
  sectors_per_cluster  1   (one cluster == one sector — simplest)
  reserved_sectors     16
  num_fats             2
  sectors_per_fat      1   (128 entries — plenty for our few clusters)
  root_cluster         2
  total_sectors        64

Layout:
  sector  0      : BPB (boot sector)
  sector  1..15  : reserved (zeroed)
  sector 16      : FAT 0
  sector 17      : FAT 1 (mirror of FAT 0)
  sector 18      : cluster 2 = root directory
  sector 19      : cluster 3 = HELLO.TXT contents
  sector 20..63  : free clusters (zeroed)

Future milestones will populate more files (and longer ones spanning
multiple clusters); the parser's FAT-chain walk is already general.
"""

import os
import shutil
import struct
import subprocess
from pathlib import Path

SECTOR_SIZE         = 512
SECTORS_PER_CLUSTER = 1
RESERVED_SECTORS    = 16
NUM_FATS            = 2
SECTORS_PER_FAT     = 1
ROOT_CLUSTER        = 2
TOTAL_SECTORS       = 64

# Files we ship in the image. Names MUST be uppercase 8.3 so
# mkfs-style LFN handling is unnecessary on either side.
HELLO_NAME  = "HELLO   TXT"         # 8+3, space-padded
HELLO_BODY  = (
    b"FAT32_MARKER hello from /mnt/HELLO.TXT in a baked-in image\n"
)

# M16.45: a subdirectory at root containing a nested file. Exercises
# fat_lookup's path-component traversal (root → SUBDIR → NESTED.TXT)
# and the FAT chain walk through a directory cluster.
SUBDIR_NAME = "SUBDIR     "         # 11 spaces total, all-uppercase
NESTED_NAME = "NESTED  TXT"
NESTED_BODY = (
    b"NESTED_MARKER from /mnt/SUBDIR/NESTED.TXT - subdir walk works\n"
)


def build_bpb() -> bytes:
    # Skip the 3-byte jmp-to-bootcode at offset 0; we don't boot from
    # this sector. Fill with 0xEB 0x3C 0x90 (the conventional "jmp +60
    # / nop" boot stub) so a real bootloader inspecting the magic
    # doesn't sneeze.
    bpb = bytearray(SECTOR_SIZE)
    bpb[0:3]  = b"\xEB\x3C\x90"
    bpb[3:11] = b"HAMNIX  "                                # OEM ID, 8 bytes
    struct.pack_into("<H", bpb, 11, SECTOR_SIZE)           # bytes_per_sector
    bpb[13]   = SECTORS_PER_CLUSTER
    struct.pack_into("<H", bpb, 14, RESERVED_SECTORS)
    bpb[16]   = NUM_FATS
    struct.pack_into("<H", bpb, 17, 0)                     # root_entries (0 for FAT32)
    struct.pack_into("<H", bpb, 19, 0)                     # total_sectors_16 (0 → use 32)
    bpb[21]   = 0xF8                                       # media descriptor (fixed disk)
    struct.pack_into("<H", bpb, 22, 0)                     # sectors_per_fat_16 (0 for FAT32)
    struct.pack_into("<H", bpb, 24, 32)                    # sectors_per_track (cosmetic)
    struct.pack_into("<H", bpb, 26, 64)                    # num_heads (cosmetic)
    struct.pack_into("<I", bpb, 28, 0)                     # hidden_sectors
    struct.pack_into("<I", bpb, 32, TOTAL_SECTORS)         # total_sectors_32
    # FAT32 extended BPB starts at offset 36.
    struct.pack_into("<I", bpb, 36, SECTORS_PER_FAT)       # sectors_per_fat_32
    struct.pack_into("<H", bpb, 40, 0)                     # ext_flags
    struct.pack_into("<H", bpb, 42, 0)                     # fs_version
    struct.pack_into("<I", bpb, 44, ROOT_CLUSTER)
    struct.pack_into("<H", bpb, 48, 1)                     # fs_info sector
    struct.pack_into("<H", bpb, 50, 6)                     # backup_boot sector
    # offset 64: drive_number, etc. Conventional values:
    bpb[64]   = 0x80                                       # drive_number
    bpb[66]   = 0x29                                       # extended boot sig
    struct.pack_into("<I", bpb, 67, 0xDEADBEEF)            # volume serial
    bpb[71:82]   = b"HAMNIX_FAT "                          # volume label, 11 chars
    bpb[82:90]   = b"FAT32   "                             # fs type, 8 chars
    # Boot signature 0x55 0xAA at end-of-sector.
    bpb[510]  = 0x55
    bpb[511]  = 0xAA
    return bytes(bpb)


def build_fat() -> bytes:
    # FAT entries are uint32, only the low 28 bits are the cluster
    # number; high 4 bits are reserved and read-as-zero. Entry 0
    # encodes the media descriptor in the low byte; entry 1 is
    # reserved (typically end-of-chain). Entries 2+ describe the
    # data clusters. Layout:
    #
    #   cluster 2: root directory
    #   cluster 3: HELLO.TXT contents
    #   cluster 4: SUBDIR/ directory contents
    #   cluster 5: SUBDIR/NESTED.TXT contents
    EOC = 0x0FFFFFFF
    fat = bytearray(SECTOR_SIZE)
    struct.pack_into("<I", fat, 0,  0x0FFFFFF8)
    struct.pack_into("<I", fat, 4,  EOC)
    struct.pack_into("<I", fat, 8,  EOC)
    struct.pack_into("<I", fat, 12, EOC)
    struct.pack_into("<I", fat, 16, EOC)
    struct.pack_into("<I", fat, 20, EOC)
    return bytes(fat)


def _pack_dir_entry(name11: bytes, attr: int, cluster: int,
                    size: int) -> bytes:
    assert len(name11) == 11
    e = bytearray(32)
    e[0:11] = name11
    e[11]   = attr
    struct.pack_into("<H", e, 20, (cluster >> 16) & 0xFFFF)
    struct.pack_into("<H", e, 26, cluster & 0xFFFF)
    struct.pack_into("<I", e, 28, size)
    return bytes(e)


def build_root_dir(hello_cluster: int, hello_size: int,
                   subdir_cluster: int) -> bytes:
    cluster = bytearray(SECTOR_SIZE)
    # Entry 0: HELLO.TXT (regular file).
    cluster[0:32] = _pack_dir_entry(
        HELLO_NAME.encode("ascii"), attr=0x20,
        cluster=hello_cluster, size=hello_size,
    )
    # Entry 1: SUBDIR (directory). Size is 0 for directories per spec.
    cluster[32:64] = _pack_dir_entry(
        SUBDIR_NAME.encode("ascii"), attr=0x10,
        cluster=subdir_cluster, size=0,
    )
    return bytes(cluster)


def build_subdir_dir(nested_cluster: int, nested_size: int) -> bytes:
    cluster = bytearray(SECTOR_SIZE)
    # "." entry — points to the subdir itself (well-known convention).
    cluster[0:32] = _pack_dir_entry(
        b".          ", attr=0x10,
        cluster=4,                              # SUBDIR's own cluster
        size=0,
    )
    # ".." entry — points to root. FAT32 convention: parent's cluster
    # if root, write 0 (not 2).
    cluster[32:64] = _pack_dir_entry(
        b"..         ", attr=0x10, cluster=0, size=0,
    )
    # The actual nested file.
    cluster[64:96] = _pack_dir_entry(
        NESTED_NAME.encode("ascii"), attr=0x20,
        cluster=nested_cluster, size=nested_size,
    )
    return bytes(cluster)


def build_file_cluster(body: bytes) -> bytes:
    cluster = bytearray(SECTOR_SIZE)
    cluster[0:len(body)] = body
    return bytes(cluster)


def build_image() -> bytes:
    img = bytearray(TOTAL_SECTORS * SECTOR_SIZE)
    img[0:SECTOR_SIZE] = build_bpb()
    fat_bytes = build_fat()
    img[16*SECTOR_SIZE:17*SECTOR_SIZE] = fat_bytes
    img[17*SECTOR_SIZE:18*SECTOR_SIZE] = fat_bytes
    # cluster 2 = root dir
    img[18*SECTOR_SIZE:19*SECTOR_SIZE] = build_root_dir(
        hello_cluster=3, hello_size=len(HELLO_BODY),
        subdir_cluster=4,
    )
    # cluster 3 = HELLO.TXT
    img[19*SECTOR_SIZE:20*SECTOR_SIZE] = build_file_cluster(HELLO_BODY)
    # cluster 4 = SUBDIR/
    img[20*SECTOR_SIZE:21*SECTOR_SIZE] = build_subdir_dir(
        nested_cluster=5, nested_size=len(NESTED_BODY),
    )
    # cluster 5 = SUBDIR/NESTED.TXT
    img[21*SECTOR_SIZE:22*SECTOR_SIZE] = build_file_cluster(NESTED_BODY)
    return bytes(img)


def emit_asm(image: bytes, dest: Path, symbol_prefix: str = "diskimg") -> None:
    start = f"{symbol_prefix}_start"
    end   = f"{symbol_prefix}_end"
    base  = f"{symbol_prefix}_base"
    size  = f"{symbol_prefix}_size"
    lines = [
        "/* AUTOGENERATED by scripts/build_diskimg.py — do not edit. */",
        "    .section .rodata",
        "    .align 8",
        f"    .globl {start}",
        f"{start}:",
    ]
    for i in range(0, len(image), 16):
        chunk = image[i:i + 16]
        bytes_csv = ", ".join(f"0x{b:02x}" for b in chunk)
        lines.append(f"    .byte {bytes_csv}")
    lines += [
        f"    .globl {end}",
        f"{end}:",
        "",
        "    .code64",
        "    .section .text, \"ax\"",
        f"    .globl {base}",
        f"{base}:",
        f"    leaq {start}(%rip), %rax",
        "    ret",
        f"    .globl {size}",
        f"{size}:",
        f"    leaq {end}(%rip), %rax",
        f"    leaq {start}(%rip), %rcx",
        "    subq %rcx, %rax",
        "    ret",
    ]
    dest.write_text("\n".join(lines) + "\n")


def _which(name: str) -> str:
    # mkfs.ext4 and debugfs live in /sbin which isn't always in
    # PATH for non-root users; check the usual suspect locations.
    found = shutil.which(name)
    if found:
        return found
    for prefix in ("/sbin", "/usr/sbin", "/usr/local/sbin"):
        candidate = Path(prefix) / name
        if candidate.exists():
            return str(candidate)
    raise SystemExit(f"required tool '{name}' not found")


def build_ext4_image(out_path: Path) -> bytes:
    # Generate a 1 MiB ext4 image with a single file via mkfs.ext4
    # + debugfs (no root / loopback mount needed). We use 1 KiB
    # blocks so the smallest valid ext4 filesystem fits in 1 MiB.
    mkfs    = _which("mkfs.ext4")
    debugfs = _which("debugfs")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    # 1 MiB raw image.
    with open(out_path, "wb") as f:
        f.truncate(1 * 1024 * 1024)
    # Format. -F skips the "are you sure?" prompt, -b 1024 picks
    # 1 KiB blocks (the minimum), -L names the volume, -t ext4 is
    # explicit. -O '^has_journal' drops the journal we don't need
    # for read-only access — keeps the image tiny.
    subprocess.run(
        [mkfs, "-F", "-q", "-b", "1024", "-t", "ext4",
         "-L", "HAMNIX_EXT", "-O", "^has_journal",
         str(out_path)],
        check=True, capture_output=True,
    )
    # Plant /HELLO.TXT and /SUB/NESTED.TXT via debugfs. The mkdir
    # / cd / write -f sequence is sent as one command stream so
    # debugfs preserves working-directory state between commands.
    hello_body = (
        b"EXT4_MARKER hello from /ext/HELLO.TXT - ext4 driver works\n"
    )
    nested_body = (
        b"EXT4_NESTED_MARKER /ext/SUB/NESTED.TXT - subdir walk works\n"
    )
    tmp_hello  = out_path.with_suffix(".hello.tmp")
    tmp_nested = out_path.with_suffix(".nested.tmp")
    tmp_hello.write_bytes(hello_body)
    tmp_nested.write_bytes(nested_body)
    cmd_stream = (
        f"write {tmp_hello} HELLO.TXT\n"
        f"mkdir SUB\n"
        f"cd SUB\n"
        f"write {tmp_nested} NESTED.TXT\n"
    )
    try:
        subprocess.run(
            [debugfs, "-w", "-f", "/dev/stdin", str(out_path)],
            input=cmd_stream, text=True,
            check=True, capture_output=True,
        )
    finally:
        tmp_hello.unlink(missing_ok=True)
        tmp_nested.unlink(missing_ok=True)
    return out_path.read_bytes()


if __name__ == "__main__":
    here = Path(__file__).resolve().parent.parent

    # FAT image — baked as fs/diskimg_blob.S and copied raw to
    # build/disk.img for QEMU -drive,if=virtio.
    fat_image = build_image()
    blob_dest = here / "fs" / "diskimg_blob.S"
    emit_asm(fat_image, blob_dest, symbol_prefix="diskimg")
    img_dest = here / "build" / "disk.img"
    img_dest.parent.mkdir(parents=True, exist_ok=True)
    img_dest.write_bytes(fat_image)
    print(f"Wrote {blob_dest} ({len(fat_image)} bytes image, "
          f"{TOTAL_SECTORS} sectors of {SECTOR_SIZE})")
    print(f"Wrote {img_dest} (raw FAT bytes)")
    print(f"  /mnt/HELLO.TXT ({len(HELLO_BODY)} bytes)")
    print(f"  /mnt/SUBDIR/NESTED.TXT ({len(NESTED_BODY)} bytes)")

    # EXT4 image — generated via mkfs.ext4 + debugfs as a raw file
    # at build/ext4.img so QEMU can attach it via -drive,if=virtio.
    # We DON'T bake it into the kernel binary: at 1 MiB the blob
    # would dominate the .rodata segment, and ext4-on-ramdisk is
    # not a real use case (virtio-blk attaches it just as well).
    # The placeholder fs/ext4_blob.S keeps the build symbol-clean
    # for any future ext4-ramdisk path.
    ext4_raw  = here / "build" / "ext4.img"
    ext4_blob = here / "fs"    / "ext4_blob.S"
    try:
        build_ext4_image(ext4_raw)
        print(f"Wrote {ext4_raw} (raw ext4 bytes, ~1 MiB)")
        print(f"  /ext/HELLO.TXT (planted via debugfs)")
    except SystemExit as e:
        print(f"WARNING: ext4 image not generated ({e}); skipping")
    # Always emit the placeholder blob so the kernel's references
    # to ext4img_base / ext4img_size link cleanly.
    ext4_blob.write_text(
        "/* AUTOGENERATED placeholder — actual ext4 lives in\n"
        " * build/ext4.img and is attached to QEMU via -drive,if=virtio.\n"
        " * Kept here so any future ramdisk-backed ext4 path links\n"
        " * cleanly against the same symbols. */\n"
        "    .section .rodata\n    .align 8\n"
        "    .globl ext4img_start\next4img_start:\n"
        "    .globl ext4img_end\next4img_end:\n"
        "    .code64\n    .section .text, \"ax\"\n"
        "    .globl ext4img_base\next4img_base:\n"
        "    leaq ext4img_start(%rip), %rax\n    ret\n"
        "    .globl ext4img_size\next4img_size:\n"
        "    xorl %eax, %eax\n    ret\n"
    )
