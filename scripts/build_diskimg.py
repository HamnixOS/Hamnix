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

# File we ship in the image. Name MUST be uppercase 8.3 so mkfs-style
# LFN handling is unnecessary on either side. The marker is what
# scripts/test_fat.sh greps for.
HELLO_NAME = "HELLO   TXT"          # 8+3, space-padded
HELLO_BODY = (
    b"FAT32_MARKER hello from /mnt/HELLO.TXT in a baked-in image\n"
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
    # data clusters.
    EOC = 0x0FFFFFFF
    fat = bytearray(SECTOR_SIZE)
    struct.pack_into("<I", fat, 0,  0x0FFFFFF8)   # entry 0: media | reserved bits
    struct.pack_into("<I", fat, 4,  EOC)          # entry 1: reserved
    struct.pack_into("<I", fat, 8,  EOC)          # entry 2: root dir, single cluster
    struct.pack_into("<I", fat, 12, EOC)          # entry 3: HELLO.TXT, single cluster
    return bytes(fat)


def build_root_dir(hello_cluster: int, hello_size: int) -> bytes:
    cluster = bytearray(SECTOR_SIZE)
    # Single entry: HELLO.TXT.
    name11 = HELLO_NAME.encode("ascii")
    assert len(name11) == 11
    cluster[0:11]  = name11
    cluster[11]    = 0x20                            # attr: ARCHIVE
    cluster[12]    = 0                               # nt reserved
    cluster[13]    = 0                               # ctime tenths
    struct.pack_into("<H", cluster, 14, 0)           # ctime
    struct.pack_into("<H", cluster, 16, 0)           # cdate
    struct.pack_into("<H", cluster, 18, 0)           # adate
    struct.pack_into("<H", cluster, 20, (hello_cluster >> 16) & 0xFFFF)
    struct.pack_into("<H", cluster, 22, 0)           # mtime
    struct.pack_into("<H", cluster, 24, 0)           # mdate
    struct.pack_into("<H", cluster, 26, hello_cluster & 0xFFFF)
    struct.pack_into("<I", cluster, 28, hello_size)
    return bytes(cluster)


def build_hello_cluster() -> bytes:
    cluster = bytearray(SECTOR_SIZE)
    cluster[0:len(HELLO_BODY)] = HELLO_BODY
    return bytes(cluster)


def build_image() -> bytes:
    img = bytearray(TOTAL_SECTORS * SECTOR_SIZE)
    # sector 0: BPB
    img[0:SECTOR_SIZE] = build_bpb()
    # sectors 1..15: reserved, zero.
    # sectors 16 + 17: FATs.
    fat_bytes = build_fat()
    img[16*SECTOR_SIZE:17*SECTOR_SIZE] = fat_bytes
    img[17*SECTOR_SIZE:18*SECTOR_SIZE] = fat_bytes
    # sector 18 (cluster 2): root directory.
    img[18*SECTOR_SIZE:19*SECTOR_SIZE] = build_root_dir(
        hello_cluster=3, hello_size=len(HELLO_BODY),
    )
    # sector 19 (cluster 3): HELLO.TXT contents.
    img[19*SECTOR_SIZE:20*SECTOR_SIZE] = build_hello_cluster()
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
