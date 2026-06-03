#!/usr/bin/env bash
# scripts/test_exfat.sh — read-only exFAT reader self-test.
#
# Boots the kernel once with /etc/exfat-test planted (ENABLE_EXFAT_TEST=1)
# and a QEMU ich9-ahci SATA disk holding a real exFAT volume attached as
# sd0. init/main.ad at boot:37.exfat calls exfat_selftest() (fs/exfat.ad),
# which mounts the volume, lists the root directory, opens the known file
# "HELLO_EXFAT.TXT", reads its 64 bytes and asserts the content pattern
# ((i*7+3)&0xFF). A PASS proves the reader parses the exFAT boot sector,
# walks the FAT/contiguous cluster chain, and reassembles the 0x85/0xC0/
# 0xC1 directory entry set's long file name.
#
# The host has no mkfs.exfat / mkexfatfs and mtools does not write exFAT,
# so the test image is hand-crafted by an embedded Python generator that
# emits a minimal but spec-correct exFAT volume:
#   * Main Boot Record (LBA 0) with the "EXFAT   " FileSystemName and the
#     geometry fields exfat.ad reads (FatOffset / ClusterHeapOffset /
#     FirstClusterOfRootDirectory / shifts / VolumeLength).
#   * A 32-bit FAT placing the allocation-bitmap, upcase-table, root dir
#     and the data file each on their own chained clusters.
#   * A root directory containing the mandatory Allocation Bitmap (0x81)
#     and Up-case Table (0x82) entries plus the file's 0x85/0xC0/0xC1
#     entry set, with a correct File-entry SetChecksum and 0xC1 NameHash.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO.
#
# Pass marker:  [exfat] PASS
# Fail marker:  [exfat] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_exfat] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_exfat] (2/4) Build kernel with /etc/exfat-test marker"
INIT_ELF=build/user/init.elf ENABLE_EXFAT_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_exfat] (3/4) Mint a hand-crafted exFAT disk image"
DISK=$(mktemp --suffix=.exfat-disk)
python3 - "$DISK" <<'PYEOF'
import struct, sys

# ---- Geometry (512-byte sectors, 4 KiB clusters) ------------------
BYTES_PER_SECTOR_SHIFT = 9          # 512
SECTORS_PER_CLUSTER_SHIFT = 3       # 8 sectors = 4096-byte clusters
SECTOR = 1 << BYTES_PER_SECTOR_SHIFT
CLUSTER = SECTOR << SECTORS_PER_CLUSTER_SHIFT

# Layout in sectors from LBA 0:
#   0          Main Boot Sector
#   1..11      rest of the boot region (we leave mostly zero)
#   FAT_OFFSET FAT (one cluster's worth of sectors is plenty)
#   HEAP_OFF   cluster heap (cluster 2 begins here)
FAT_OFFSET = 24                     # sector of the 32-bit FAT
FAT_LENGTH = 8                      # sectors (enough for our few clusters)
CLUSTER_HEAP_OFFSET = 32            # sector where cluster 2 starts
# Cluster assignment (heap):
#   cluster 2 = allocation bitmap
#   cluster 3 = up-case table
#   cluster 4 = root directory
#   cluster 5 = the data file "HELLO_EXFAT.TXT"
CL_BITMAP = 2
CL_UPCASE = 3
CL_ROOT   = 4
CL_FILE   = 5
CLUSTER_COUNT = 8                   # a handful is fine
VOLUME_LENGTH = CLUSTER_HEAP_OFFSET + CLUSTER_COUNT * (1 << SECTORS_PER_CLUSTER_SHIFT)

ROOT_FIRST_CLUSTER = CL_ROOT

# Total image size (round up to a few extra clusters of slack).
TOTAL_SECTORS = VOLUME_LENGTH + 16
img = bytearray(TOTAL_SECTORS * SECTOR)

def cluster_lba(n):
    return CLUSTER_HEAP_OFFSET + (n - 2) * (1 << SECTORS_PER_CLUSTER_SHIFT)

def put(off, data):
    img[off:off + len(data)] = data

# ---- The known data file ------------------------------------------
FILE_NAME = "HELLO_EXFAT.TXT"
FILE_DATA = bytes(((i * 7 + 3) & 0xFF) for i in range(64))
FILE_LEN = len(FILE_DATA)

# ---- Main Boot Sector (LBA 0) -------------------------------------
mbr = bytearray(SECTOR)
mbr[0:3] = b"\xEB\x76\x90"                 # JumpBoot
mbr[3:11] = b"EXFAT   "                     # FileSystemName (8 bytes)
# 11..64 MustBeZero
struct.pack_into("<Q", mbr, 64, 0)          # PartitionOffset
struct.pack_into("<Q", mbr, 72, VOLUME_LENGTH)
struct.pack_into("<I", mbr, 80, FAT_OFFSET)
struct.pack_into("<I", mbr, 84, FAT_LENGTH)
struct.pack_into("<I", mbr, 88, CLUSTER_HEAP_OFFSET)
struct.pack_into("<I", mbr, 92, CLUSTER_COUNT)
struct.pack_into("<I", mbr, 96, ROOT_FIRST_CLUSTER)
struct.pack_into("<I", mbr, 100, 0x12345678)  # VolumeSerialNumber
struct.pack_into("<H", mbr, 104, 0x0100)      # FileSystemRevision 1.00
struct.pack_into("<H", mbr, 106, 0)           # VolumeFlags
mbr[108] = BYTES_PER_SECTOR_SHIFT
mbr[109] = SECTORS_PER_CLUSTER_SHIFT
mbr[110] = 1                                   # NumberOfFats
mbr[111] = 0                                   # DriveSelect
mbr[112] = 0                                   # PercentInUse
mbr[510] = 0x55
mbr[511] = 0xAA
put(0, mbr)

# ---- FAT (32-bit entries) -----------------------------------------
# Entry 0 = 0xFFFFFFF8 (media), entry 1 = 0xFFFFFFFF.
# Each of our four clusters is a single-cluster chain -> EOC.
fat = bytearray(FAT_LENGTH * SECTOR)
def set_fat(n, val):
    struct.pack_into("<I", fat, n * 4, val & 0xFFFFFFFF)
set_fat(0, 0xFFFFFFF8)
set_fat(1, 0xFFFFFFFF)
EOC = 0xFFFFFFFF
for c in (CL_BITMAP, CL_UPCASE, CL_ROOT, CL_FILE):
    set_fat(c, EOC)
put(FAT_OFFSET * SECTOR, fat)

# ---- Allocation bitmap (cluster CL_BITMAP) ------------------------
# One bit per cluster starting at cluster 2 (bit0 = cluster 2).
# Mark clusters 2..5 in use.
bitmap = bytearray(CLUSTER)
used = (1 << (CL_BITMAP - 2)) | (1 << (CL_UPCASE - 2)) \
     | (1 << (CL_ROOT - 2)) | (1 << (CL_FILE - 2))
bitmap[0] = used & 0xFF
put(cluster_lba(CL_BITMAP) * SECTOR, bitmap)

# ---- Up-case table (cluster CL_UPCASE) ----------------------------
# Minimal identity up-case table for code units 0..127 (enough; our
# reader does not consult it, but a real volume requires the entry).
upcase = bytearray()
for i in range(128):
    upcase += struct.pack("<H", i)
def table_checksum(data):
    cks = 0
    for b in data:
        cks = ((cks << 31) | (cks >> 1)) & 0xFFFFFFFF
        cks = (cks + b) & 0xFFFFFFFF
    return cks
UPCASE_CHECKSUM = table_checksum(bytes(upcase))
put(cluster_lba(CL_UPCASE) * SECTOR, bytes(upcase))

# ---- exFAT name hash (for the 0xC1 entries' container) ------------
def name_hash(name_utf16le):
    h = 0
    for b in name_utf16le:
        h = ((h << 15) | (h >> 1)) & 0xFFFF
        h = (h + b) & 0xFFFF
    return h

name_units = FILE_NAME.encode("utf-16-le")
NAME_HASH = name_hash(name_units)
NAME_LEN = len(FILE_NAME)

# ---- Build the root directory (cluster CL_ROOT) -------------------
root = bytearray()

# 0x81 Allocation Bitmap entry.
e = bytearray(32)
e[0] = 0x81
e[1] = 0x00                                    # BitmapFlags (0 = first FAT)
struct.pack_into("<I", e, 20, CL_BITMAP)       # FirstCluster
struct.pack_into("<Q", e, 24, len(bitmap))     # DataLength
root += e

# 0x82 Up-case Table entry.
e = bytearray(32)
e[0] = 0x82
struct.pack_into("<I", e, 4, UPCASE_CHECKSUM)  # TableChecksum
struct.pack_into("<I", e, 20, CL_UPCASE)
struct.pack_into("<Q", e, 24, len(upcase))
root += e

# 0x83 Volume Label entry (length 0 = no label).
e = bytearray(32)
e[0] = 0x83
e[1] = 0
root += e

# ---- The file's entry set: 0x85 + 0xC0 + N*0xC1 -------------------
num_name_entries = (NAME_LEN + 14) // 15        # 15 units per 0xC1
secondary_count = 1 + num_name_entries          # stream + name entries

# 0x85 File entry (checksum filled after the secondaries are built).
file_ent = bytearray(32)
file_ent[0] = 0x85
file_ent[1] = secondary_count
struct.pack_into("<H", file_ent, 4, 0x0020)     # FileAttributes (Archive)

# 0xC0 Stream Extension entry.
stream = bytearray(32)
stream[0] = 0xC0
# GeneralSecondaryFlags: bit0 AllocationPossible(1), bit1 NoFatChain(0 ->
# FAT-chained). We keep the file FAT-chained so the reader exercises the
# FAT walk; a single-cluster file ends at EOC.
stream[1] = 0x01
stream[3] = NAME_LEN                            # NameLength (code units)
struct.pack_into("<H", stream, 4, NAME_HASH)    # NameHash
struct.pack_into("<Q", stream, 8, FILE_LEN)     # ValidDataLength
struct.pack_into("<I", stream, 20, CL_FILE)     # FirstCluster
struct.pack_into("<Q", stream, 24, FILE_LEN)    # DataLength

# 0xC1 File Name entries.
name_entries = []
units = list(name_units)
# pad to a multiple of 15 code units (30 bytes) with zeros
idx = 0
for k in range(num_name_entries):
    ne = bytearray(32)
    ne[0] = 0xC1
    ne[1] = 0                                   # GeneralSecondaryFlags
    frag = name_units[idx*30: idx*30 + 30]
    ne[2:2 + len(frag)] = frag
    name_entries.append(ne)
    idx += 1

# ---- SetChecksum over the entry set (File entry's bytes 2..3 are the
# checksum field and are excluded from the sum on the File entry only).
def entryset_checksum(entries):
    cks = 0
    for ei, ent in enumerate(entries):
        for bi, b in enumerate(ent):
            if ei == 0 and (bi == 2 or bi == 3):
                continue
            cks = ((cks << 15) | (cks >> 1)) & 0xFFFF
            cks = (cks + b) & 0xFFFF
    return cks

entry_set = [file_ent, stream] + name_entries
SET_CHECKSUM = entryset_checksum(entry_set)
struct.pack_into("<H", file_ent, 2, SET_CHECKSUM)

for ent in entry_set:
    root += ent

# Pad root to a full cluster.
root += b"\x00" * (CLUSTER - len(root))
put(cluster_lba(CL_ROOT) * SECTOR, bytes(root[:CLUSTER]))

# ---- The file's data (cluster CL_FILE) ----------------------------
data_clu = bytearray(CLUSTER)
data_clu[0:FILE_LEN] = FILE_DATA
put(cluster_lba(CL_FILE) * SECTOR, bytes(data_clu))

with open(sys.argv[1], "wb") as f:
    f.write(img)
print("[gen] exFAT image: %d sectors, file '%s' (%d bytes) at cluster %d"
      % (TOTAL_SECTORS, FILE_NAME, FILE_LEN, CL_FILE))
PYEOF

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_exfat] (4/4) Boot QEMU with -device ich9-ahci + -device ide-hd"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive if=none,file="$DISK",format=raw,id=hd0 \
    -device ich9-ahci,id=ahci0 \
    -device ide-hd,drive=hd0,bus=ahci0.0 \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_exfat] --- captured ([exfat] lines) ---"
grep -aE '\[exfat\]' "$LOG" || true
echo "[test_exfat] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_exfat] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -aqF "[exfat] FAIL" "$LOG"; then
    echo "[test_exfat] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

if ! grep -aqF "[exfat] PASS" "$LOG"; then
    echo "[test_exfat] MISS: self-test PASS banner (expected '[exfat] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_exfat] --- full log ---"
    cat "$LOG"
    echo "[test_exfat] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_exfat] PASS — read-only exFAT reader mounts a real exFAT" \
     "volume, lists the root, and reads a known file by long name"
