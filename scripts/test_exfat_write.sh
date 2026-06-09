#!/usr/bin/env bash
# scripts/test_exfat_write.sh — exFAT WRITE-path self-test.
#
# Boots the kernel once with /etc/exfat-write-test planted
# (ENABLE_EXFAT_WRITE_TEST=1) and a QEMU ich9-ahci SATA disk holding a
# real, WRITABLE exFAT volume attached as sd0. init/main.ad at
# boot:37.exfatw calls exfat_write_selftest() (fs/exfat.ad), which:
#   * mounts the volume and discovers the allocation bitmap (0x81),
#   * CREATES a brand-new file "WRITTEN_BY_HAMNIX.BIN" (5000 bytes, so
#     it spans 2 of the 4 KiB clusters) via exfat_create_and_write():
#       - allocates clusters from the allocation bitmap (set bits),
#       - links them in the 32-bit FAT (FAT-chained),
#       - writes the file bytes into the cluster heap,
#       - appends a fresh 0x85/0xC0/N*0xC1 entry set to the root dir
#         with a correct SetChecksum + NameHash,
#   * reads the file back through the read path and asserts the content
#     pattern ((i*13+5)&0xFF), including a cross-cluster seek read.
#
# A PASS proves the guest mutated the on-disk image. To prove that the
# mutation is SPEC-CORRECT (not just self-consistent), AFTER the boot
# this script re-parses the resulting disk image with an INDEPENDENT
# Python exFAT decoder and asserts the new file's entry set, FAT chain,
# bitmap bits and data bytes all match.
#
# The host has no mkfs.exfat / mkexfatfs, so the seed image is
# hand-crafted by an embedded Python generator (same style as
# scripts/test_exfat.sh) but sized with spare clusters + spare
# root-directory slots so the guest has room to allocate.
#
# Pass marker (guest):  [exfat-w] PASS
# Fail marker (guest):  [exfat-w] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_exfat_write] (1/5) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_exfat_write] (2/5) Build kernel with /etc/exfat-write-test marker"
INIT_ELF=build/user/init.elf ENABLE_EXFAT_WRITE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_exfat_write] (3/5) Mint a hand-crafted WRITABLE exFAT disk image"
DISK=$(mktemp --suffix=.exfat-disk)
python3 - "$DISK" <<'PYEOF'
import struct, sys

BYTES_PER_SECTOR_SHIFT = 9          # 512
SECTORS_PER_CLUSTER_SHIFT = 3       # 8 sectors = 4096-byte clusters
SECTOR = 1 << BYTES_PER_SECTOR_SHIFT
CLUSTER = SECTOR << SECTORS_PER_CLUSTER_SHIFT
SPC = 1 << SECTORS_PER_CLUSTER_SHIFT

FAT_OFFSET = 24
FAT_LENGTH = 8
CLUSTER_HEAP_OFFSET = 32
# Cluster assignment (heap):
#   cluster 2 = allocation bitmap
#   cluster 3 = up-case table
#   cluster 4 = root directory
#   clusters 5..  = FREE (the guest allocates here)
CL_BITMAP = 2
CL_UPCASE = 3
CL_ROOT   = 4
CLUSTER_COUNT = 16                  # plenty of free clusters for the guest
VOLUME_LENGTH = CLUSTER_HEAP_OFFSET + CLUSTER_COUNT * SPC

ROOT_FIRST_CLUSTER = CL_ROOT
TOTAL_SECTORS = VOLUME_LENGTH + 16
img = bytearray(TOTAL_SECTORS * SECTOR)

def cluster_lba(n):
    return CLUSTER_HEAP_OFFSET + (n - 2) * SPC

def put(off, data):
    img[off:off + len(data)] = data

# ---- Main Boot Sector ---------------------------------------------
mbr = bytearray(SECTOR)
mbr[0:3] = b"\xEB\x76\x90"
mbr[3:11] = b"EXFAT   "
struct.pack_into("<Q", mbr, 64, 0)
struct.pack_into("<Q", mbr, 72, VOLUME_LENGTH)
struct.pack_into("<I", mbr, 80, FAT_OFFSET)
struct.pack_into("<I", mbr, 84, FAT_LENGTH)
struct.pack_into("<I", mbr, 88, CLUSTER_HEAP_OFFSET)
struct.pack_into("<I", mbr, 92, CLUSTER_COUNT)
struct.pack_into("<I", mbr, 96, ROOT_FIRST_CLUSTER)
struct.pack_into("<I", mbr, 100, 0x12345678)
struct.pack_into("<H", mbr, 104, 0x0100)
struct.pack_into("<H", mbr, 106, 0)
mbr[108] = BYTES_PER_SECTOR_SHIFT
mbr[109] = SECTORS_PER_CLUSTER_SHIFT
mbr[110] = 1
mbr[510] = 0x55
mbr[511] = 0xAA
put(0, mbr)

# ---- FAT ----------------------------------------------------------
fat = bytearray(FAT_LENGTH * SECTOR)
def set_fat(n, val):
    struct.pack_into("<I", fat, n * 4, val & 0xFFFFFFFF)
set_fat(0, 0xFFFFFFF8)
set_fat(1, 0xFFFFFFFF)
EOC = 0xFFFFFFFF
for c in (CL_BITMAP, CL_UPCASE, CL_ROOT):
    set_fat(c, EOC)
# clusters 5.. left 0 (free) in the FAT
put(FAT_OFFSET * SECTOR, fat)

# ---- Allocation bitmap --------------------------------------------
bitmap = bytearray(CLUSTER)
used = (1 << (CL_BITMAP - 2)) | (1 << (CL_UPCASE - 2)) | (1 << (CL_ROOT - 2))
bitmap[0] = used & 0xFF
put(cluster_lba(CL_BITMAP) * SECTOR, bitmap)

# ---- Up-case table ------------------------------------------------
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

# ---- Root directory: just the system entries, then a zero sentinel.
root = bytearray()
e = bytearray(32); e[0] = 0x81
struct.pack_into("<I", e, 20, CL_BITMAP)
struct.pack_into("<Q", e, 24, len(bitmap))
root += e
e = bytearray(32); e[0] = 0x82
struct.pack_into("<I", e, 4, UPCASE_CHECKSUM)
struct.pack_into("<I", e, 20, CL_UPCASE)
struct.pack_into("<Q", e, 24, len(upcase))
root += e
e = bytearray(32); e[0] = 0x83
root += e
# Rest of the root cluster is zero -> end sentinel + spare slots.
root += b"\x00" * (CLUSTER - len(root))
put(cluster_lba(CL_ROOT) * SECTOR, bytes(root[:CLUSTER]))

with open(sys.argv[1], "wb") as f:
    f.write(img)
print("[gen] writable exFAT image: %d sectors, %d clusters (5.. free)"
      % (TOTAL_SECTORS, CLUSTER_COUNT))
PYEOF

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_exfat_write] (4/5) Boot QEMU with -device ich9-ahci + -device ide-hd"
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

echo "[test_exfat_write] --- captured ([exfat-w] lines) ---"
grep -aE '\[exfat-w\]' "$LOG" || true
echo "[test_exfat_write] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_exfat_write] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -aqF "[exfat-w] FAIL" "$LOG"; then
    echo "[test_exfat_write] FAIL: guest self-test reported an internal failure" >&2
    fail=1
fi

if ! grep -aqF "[exfat-w] PASS" "$LOG"; then
    echo "[test_exfat_write] MISS: self-test PASS banner ('[exfat-w] PASS')" >&2
    fail=1
fi

echo "[test_exfat_write] (5/5) Independently re-parse the mutated image"
set +e
python3 - "$DISK" <<'PYEOF'
import struct, sys

with open(sys.argv[1], "rb") as f:
    img = f.read()

def u16(o): return struct.unpack_from("<H", img, o)[0]
def u32(o): return struct.unpack_from("<I", img, o)[0]
def u64(o): return struct.unpack_from("<Q", img, o)[0]

assert img[3:11] == b"EXFAT   ", "not exFAT after write"
VOLUME_LENGTH = u64(72)
FAT_OFFSET = u32(80)
CLUSTER_HEAP_OFFSET = u32(88)
CLUSTER_COUNT = u32(92)
ROOT_FIRST_CLUSTER = u32(96)
bps = 1 << img[108]
spc = 1 << img[109]
SECTOR = bps
CLUSTER = bps * spc

def cluster_lba(n):
    return CLUSTER_HEAP_OFFSET + (n - 2) * spc

def fat_next(c):
    off = FAT_OFFSET * SECTOR + c * 4
    return u32(off)

def read_chain_bytes(first, length, nofatchain=False):
    out = bytearray()
    c = first
    while len(out) < length:
        base = cluster_lba(c) * SECTOR
        out += img[base: base + CLUSTER]
        if nofatchain:
            c += 1
        else:
            nxt = fat_next(c)
            if nxt >= 0xFFFFFFF8:
                break
            c = nxt
    return bytes(out[:length])

# Read the entire root directory chain.
root = read_chain_bytes(ROOT_FIRST_CLUSTER, 64 * CLUSTER)

# Walk entries; find the new file by name.
WANT = "WRITTEN_BY_HAMNIX.BIN"
EXP = bytes(((i * 13 + 5) & 0xFF) for i in range(5000))

def name_hash(name_utf16le):
    h = 0
    for b in name_utf16le:
        h = (((h << 15) | (h >> 1)) + b) & 0xFFFF
    return h

def entryset_checksum(es):
    cks = 0
    for bi, b in enumerate(es):
        if bi == 2 or bi == 3:
            continue
        cks = (((cks << 15) | (cks >> 1)) + b) & 0xFFFF
    return cks

found = False
i = 0
while i < len(root):
    t = root[i]
    if t == 0x00:
        break
    if t == 0x85:
        sec = root[i + 1]
        nentries = sec + 1
        es = root[i: i + nentries * 32]
        stream = es[32:64]
        assert stream[0] == 0xC0, "first secondary not stream ext"
        nlen = stream[3]
        first_clu = struct.unpack_from("<I", stream, 20)[0]
        data_len = struct.unpack_from("<Q", stream, 24)[0]
        valid_len = struct.unpack_from("<Q", stream, 8)[0]
        nh_stored = struct.unpack_from("<H", stream, 4)[0]
        sec_flags = stream[1]
        nofat = bool(sec_flags & 0x02)
        # reassemble the name
        name = ""
        units = bytearray()
        for k in range(2, nentries):
            ne = es[k * 32:(k + 1) * 32]
            if ne[0] != 0xC1:
                continue
            units += ne[2:2 + 30]
        name = units[:nlen * 2].decode("utf-16-le")
        if name == WANT:
            found = True
            # Validate SetChecksum.
            stored_cks = struct.unpack_from("<H", es, 2)[0]
            calc_cks = entryset_checksum(es)
            assert stored_cks == calc_cks, \
                "SetChecksum mismatch: stored=%#x calc=%#x" % (stored_cks, calc_cks)
            # Validate NameHash.
            calc_nh = name_hash(units[:nlen * 2])
            assert nh_stored == calc_nh, \
                "NameHash mismatch: stored=%#x calc=%#x" % (nh_stored, calc_nh)
            # Validate sizes.
            assert data_len == 5000, "DataLength=%d" % data_len
            assert valid_len == 5000, "ValidDataLength=%d" % valid_len
            # Read data via the FAT chain and compare.
            data = read_chain_bytes(first_clu, 5000, nofatchain=nofat)
            assert data == EXP, "data bytes mismatch"
            # Verify the cluster chain is bitmap-marked in-use.
            # Locate the bitmap (0x81) entry.
            j = 0
            bitmap_first = None
            bitmap_len = None
            while j < len(root):
                if root[j] == 0x81:
                    bitmap_first = struct.unpack_from("<I", root, j + 20)[0]
                    bitmap_len = struct.unpack_from("<Q", root, j + 24)[0]
                    break
                if root[j] == 0x00:
                    break
                if root[j] == 0x85:
                    j += (root[j + 1] + 1) * 32
                else:
                    j += 32
            assert bitmap_first is not None, "no bitmap entry"
            bm = read_chain_bytes(bitmap_first, bitmap_len)
            # Walk the file's FAT chain and assert each cluster's bit.
            c = first_clu
            seen = 0
            while c < 0xFFFFFFF8 and seen < 64:
                bit = c - 2
                assert (bm[bit // 8] >> (bit % 8)) & 1, \
                    "cluster %d not marked in bitmap" % c
                nxt = fat_next(c)
                if nxt >= 0xFFFFFFF8:
                    break
                c = nxt
                seen += 1
            print("[host-verify] new file '%s' OK: first_clu=%d len=%d "
                  "setck=%#x namehash=%#x chain+bitmap+data all valid"
                  % (name, first_clu, data_len, stored_cks, nh_stored))
        i += nentries * 32
    else:
        i += 32

assert found, "host re-parse did NOT find the guest-created file"
print("[host-verify] PASS")
PYEOF
host_rc=$?
set -e

if [ "$host_rc" -ne 0 ]; then
    echo "[test_exfat_write] FAIL: host independent re-parse failed" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_exfat_write] --- full log ---"
    cat "$LOG"
    echo "[test_exfat_write] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_exfat_write] PASS — guest created a new exFAT file (bitmap" \
     "alloc + FAT chain + data + entry-set with SetChecksum), read it" \
     "back, and an independent host decoder confirms the on-disk result"
