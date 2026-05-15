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

import struct
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


def emit_asm(image: bytes, dest: Path) -> None:
    lines = [
        "/* AUTOGENERATED by scripts/build_diskimg.py — do not edit. */",
        "    .section .rodata",
        "    .align 8",
        "    .globl diskimg_start",
        "diskimg_start:",
    ]
    for i in range(0, len(image), 16):
        chunk = image[i:i + 16]
        bytes_csv = ", ".join(f"0x{b:02x}" for b in chunk)
        lines.append(f"    .byte {bytes_csv}")
    lines += [
        "    .globl diskimg_end",
        "diskimg_end:",
        "",
        "    .code64",
        "    .section .text, \"ax\"",
        "    .globl diskimg_base",
        "diskimg_base:",
        "    leaq diskimg_start(%rip), %rax",
        "    ret",
        "    .globl diskimg_size",
        "diskimg_size:",
        "    leaq diskimg_end(%rip), %rax",
        "    leaq diskimg_start(%rip), %rcx",
        "    subq %rcx, %rax",
        "    ret",
    ]
    dest.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    here = Path(__file__).resolve().parent.parent
    image = build_image()
    blob_dest = here / "fs" / "diskimg_blob.S"
    emit_asm(image, blob_dest)
    # Also write the raw image to build/disk.img so QEMU can mount
    # it via -drive file=build/disk.img,if=virtio. The block layer
    # accepts both backings via the same BlockDevice abstraction;
    # virtio-blk picks up vda, brd picks up ram0.
    img_dest = here / "build" / "disk.img"
    img_dest.parent.mkdir(parents=True, exist_ok=True)
    img_dest.write_bytes(image)
    print(f"Wrote {blob_dest} ({len(image)} bytes image, "
          f"{TOTAL_SECTORS} sectors of {SECTOR_SIZE})")
    print(f"Wrote {img_dest} (raw, same bytes)")
    print(f"  embedded /mnt/HELLO.TXT ({len(HELLO_BODY)} bytes)")
    print(f"  embedded /mnt/SUBDIR/NESTED.TXT ({len(NESTED_BODY)} bytes)")
