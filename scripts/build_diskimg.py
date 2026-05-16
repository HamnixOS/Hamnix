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
    # Plant /HELLO.TXT, /SUB/NESTED.TXT, and /BIG.TXT via debugfs.
    # The mkdir / cd / write -f sequence is sent as one command
    # stream so debugfs preserves working-directory state between
    # commands. BIG.TXT is the source for the depth-1 surgery below.
    hello_body = (
        b"EXT4_MARKER hello from /ext/HELLO.TXT - ext4 driver works\n"
    )
    nested_body = (
        b"EXT4_NESTED_MARKER /ext/SUB/NESTED.TXT - subdir walk works\n"
    )
    big_body = (
        b"DEPTH1_MARKER ext4 index extents work - read via depth=1 tree\n"
    )
    tmp_hello  = out_path.with_suffix(".hello.tmp")
    tmp_nested = out_path.with_suffix(".nested.tmp")
    tmp_big    = out_path.with_suffix(".big.tmp")
    tmp_hello.write_bytes(hello_body)
    tmp_nested.write_bytes(nested_body)
    tmp_big.write_bytes(big_body)
    # Plant 50 additional files (FILE00.TXT..FILE49.TXT, each 1 byte)
    # in the root directory to force it to span multiple data blocks
    # — exercises ext4_dir_lookup / ext4_listdir's multi-block walk.
    # 50 entries × ~24 bytes per dirent = ~1.2 KiB, well past one
    # 1 KiB block. They all share `tmp_big` as source since the
    # content doesn't matter for the dir-walk test.
    extra_writes = "".join(
        f"write {tmp_big} FILE{i:02d}.TXT\n" for i in range(50)
    )
    cmd_stream = (
        f"write {tmp_hello} HELLO.TXT\n"
        f"write {tmp_big} BIG.TXT\n"
        + extra_writes +
        f"mkdir SUB\n"
        f"cd SUB\n"
        f"write {tmp_nested} NESTED.TXT\n"
        # Plant a symlink at /HELLO_LINK → /HELLO.TXT. debugfs's
        # `symlink <filespec> <target>` argument order is the
        # opposite of `ln -s` (man debugfs(8): "symlink filespec
        # target") — first arg is where the link is created, second
        # is where it points. Resolving /ext/HELLO_LINK on the
        # kernel side exercises the M16.68 symlink-follow path.
        f"cd /\n"
        f"symlink /HELLO_LINK /HELLO.TXT\n"
    )
    try:
        subprocess.run(
            [debugfs, "-w", "-f", "/dev/stdin", str(out_path)],
            input=cmd_stream, text=True,
            check=True, capture_output=True,
        )
        # Surgery: rewrite BIG.TXT's extent tree from inline depth=0
        # to indirect depth=1, exercising the index-walk path on read.
        _fragment_to_depth1(out_path, "BIG.TXT")
    finally:
        tmp_hello.unlink(missing_ok=True)
        tmp_nested.unlink(missing_ok=True)
        tmp_big.unlink(missing_ok=True)
    return out_path.read_bytes()


def _fragment_to_depth1(image_path: Path, filename: str) -> None:
    """Post-process an ext4 image so `filename` (in the root dir) has a
    depth=1 extent tree instead of an inline depth=0 leaf.

    debugfs writes are always optimally contiguous, so a single
    small file gets one inline extent — useful to verify the
    common case, but it doesn't exercise the index walk. We
    surgically rewrite the inode after planting:

      old layout (depth=0, inline)
        eh{magic, entries=1, max=4, depth=0}
        ee{ee_block=0, ee_len=1, ee_start_lo=DATA_BLK}

      new layout (depth=1)
        eh{magic, entries=1, max=4, depth=1}
        ei{ei_block=0, ei_leaf_lo=LEAF_BLK}

      LEAF_BLK contents (planted by us)
        eh{magic, entries=1, max=N, depth=0}
        ee{ee_block=0, ee_len=1, ee_start_lo=DATA_BLK}

    LEAF_BLK is taken from the top of the image (1 KiB blocks in
    a 1 MiB image leaves the trailing blocks unused after a fresh
    mkfs + small writes). We don't bother updating the block
    bitmap — our kernel doesn't validate it on read.
    """
    img = bytearray(image_path.read_bytes())
    # Parse just the fields we need from the SB at byte 1024.
    sb = img[1024:1024 + 1024]
    s_log_block_size  = struct.unpack_from("<I", sb, 0x18)[0]
    s_inodes_per_grp  = struct.unpack_from("<I", sb, 0x28)[0]
    s_first_data_blk  = struct.unpack_from("<I", sb, 0x14)[0]
    s_inode_size      = struct.unpack_from("<H", sb, 0x58)[0] or 128
    s_desc_size       = struct.unpack_from("<H", sb, 0xFE)[0] or 32
    block_size        = 1024 << s_log_block_size
    gdt_block         = s_first_data_blk + 1
    # Group 0 descriptor at the start of the GDT block.
    gd_off = gdt_block * block_size
    inode_table_blk = struct.unpack_from("<I", img, gd_off + 8)[0]

    # Find BIG.TXT's inode number by walking the root dir's first
    # data block. Root is inum 2; its i_block holds one inline extent
    # in the freshly-built image.
    root_inode_off = inode_table_blk * block_size + (2 - 1) * s_inode_size
    root_iblock_off = root_inode_off + 0x28
    # Read root's first extent (depth must be 0 for a fresh small dir).
    eh_magic, entries, _, depth, _ = struct.unpack_from(
        "<HHHHI", img, root_iblock_off)
    assert eh_magic == 0xF30A and depth == 0
    ee_off = root_iblock_off + 12
    _, _, _, root_data_blk = struct.unpack_from("<IHHI", img, ee_off)
    # Walk dir entries to find BIG.TXT.
    name_bytes = filename.encode("ascii")
    pos = 0
    target_inum = None
    while pos + 8 <= block_size:
        e_off = root_data_blk * block_size + pos
        inum, rec_len = struct.unpack_from("<IH", img, e_off)
        if rec_len == 0:
            break
        if inum != 0:
            name_len = img[e_off + 6]
            if img[e_off + 8: e_off + 8 + name_len] == name_bytes:
                target_inum = inum
                break
        pos += rec_len
    assert target_inum is not None, f"{filename} not found in root dir"

    # Read BIG.TXT's inode, current extent points at data_blk.
    big_inode_off = inode_table_blk * block_size \
                    + (target_inum - 1) * s_inode_size
    big_iblock_off = big_inode_off + 0x28
    eh_magic, entries, _, depth, _ = struct.unpack_from(
        "<HHHHI", img, big_iblock_off)
    assert eh_magic == 0xF30A and depth == 0 and entries == 1, \
        f"BIG.TXT extent tree unexpected: depth={depth} entries={entries}"
    _, _, ee_start_hi, ee_start_lo = struct.unpack_from(
        "<IHHI", img, big_iblock_off + 12)
    data_blk = (ee_start_hi << 32) | ee_start_lo

    # Pick a leaf block from the tail end of the image — well past
    # anything mkfs or our small writes have touched. Block (total - 4)
    # leaves a few sentinels at the very end alone.
    total_blocks = len(img) // block_size
    leaf_blk = total_blocks - 4
    assert leaf_blk > data_blk + 16

    # Write the synthetic leaf block: one header + one extent record
    # pointing back at the original data block. Pad the rest with 0
    # — eh_max can claim a high entry count, ext4 readers don't care
    # as long as eh_entries is honored.
    leaf_off = leaf_blk * block_size
    img[leaf_off: leaf_off + block_size] = b"\x00" * block_size
    struct.pack_into("<HHHHI", img, leaf_off,
                     0xF30A,     # eh_magic
                     1,          # eh_entries
                     (block_size - 12) // 12,  # eh_max
                     0,          # eh_depth (leaf)
                     0)          # eh_generation
    struct.pack_into("<IHHI", img, leaf_off + 12,
                     0,          # ee_block (logical)
                     1,          # ee_len
                     0,          # ee_start_hi
                     data_blk)   # ee_start_lo

    # Rewrite BIG.TXT's inline i_block to be a depth=1 header + one
    # index record pointing at leaf_blk.
    iblk_bytes = bytearray(60)
    struct.pack_into("<HHHHI", iblk_bytes, 0,
                     0xF30A,     # eh_magic
                     1,          # eh_entries
                     4,          # eh_max (inline cap)
                     1,          # eh_depth (1 = one level of index)
                     0)          # eh_generation
    struct.pack_into("<IIHH", iblk_bytes, 12,
                     0,          # ei_block
                     leaf_blk,   # ei_leaf_lo
                     0,          # ei_leaf_hi
                     0)          # ei_unused
    img[big_iblock_off: big_iblock_off + 60] = iblk_bytes

    image_path.write_bytes(bytes(img))


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
        print(f"  /ext/BIG.TXT   (depth=1 extent tree — exercises index walk)")
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
