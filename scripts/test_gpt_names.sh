#!/usr/bin/env bash
# scripts/test_gpt_names.sh — GPT partition-NAME (UTF-16LE) decode.
#
# Proves drivers/block/partition.ad's parse_gpt() decodes a GPT entry's
# on-disk NAME field (entry byte offset +56, 36 UTF-16LE code units),
# stores it in the parallel partition_part_name table, surfaces it via
# partition_name_ptr(), and prints it on the [partition] log line as
# name="...". The scanner previously parsed the type-GUID + LBA fields
# but ignored the human-readable partition name entirely; this test
# exercises the new UTF-16LE -> ASCII decode path.
#
# Fixture (hand-authored raw GPT bytes — sgdisk/parted are not available
# in this environment, so we lay the header + 128-entry array down with
# Python + a real binascii.crc32, per the task's escalation rule). A
# 64 MiB raw image is attached as a SECOND virtio drive ("vdb"), so the
# kernel's partition_gpt_names_selftest() (chained off the existing
# partition_ebr_selftest, which init/main.ad already calls when
# /etc/partebr-test is present) finds it and asserts the decoded names.
#
# Two named GPT partitions:
#   p1: type=EFI System Partition GUID, name="EFI System"
#   p2: type=Linux filesystem  GUID,   name="ham-root"
#
# The EBR fixture (the same 3-EBR layout scripts/test_partebr.sh builds)
# rides on "vda" so the EBR self-test's vda check still passes and the
# chained GPT-names check fires.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_gpt_names] PASS   (kernel prints [gpt-names] PASS)
# Fail marker:  [test_gpt_names] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

GPTDISK=$(mktemp --suffix=.gptnames.img)
EBRDISK=$(mktemp --suffix=.ebr.img)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$GPTDISK" "$EBRDISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_gpt_names] (1/5) Author the raw GPT disk with two NAMED partitions (vdb)"
python3 - "$GPTDISK" <<'PY'
import sys, struct, binascii, uuid

img = sys.argv[1]
SECTOR = 512
NSEC = 131072            # 64 MiB / 512
ENTRY_SIZE = 128
ENTRY_COUNT = 128
ARRAY_LBA = 2            # primary partition array starts at LBA 2
ARRAY_SECTORS = (ENTRY_SIZE * ENTRY_COUNT + SECTOR - 1) // SECTOR  # 32

# Canonical type GUIDs. uuid.bytes_le matches the UEFI mixed-endian
# on-disk encoding (first three fields little-endian, last two big-endian),
# which is exactly how the kernel's _part_read_u32_le reads the type-short.
ESP_GUID   = uuid.UUID("C12A7328-F81F-11D2-BA4B-00A0C93EC93B").bytes_le
LINUX_GUID = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4").bytes_le

def part_guid(seed):
    return uuid.UUID(int=seed).bytes_le

def utf16_name(s):
    # 72-byte UTF-16LE name field, NUL-padded to 36 code units.
    raw = s.encode("utf-16-le")
    assert len(raw) <= 72, "GPT name too long"
    return raw + b"\x00" * (72 - len(raw))

def gpt_entry(type_guid, part_guid_bytes, first_lba, last_lba, name):
    # 128-byte GPT partition entry:
    #   +0  type GUID (16)   +16 unique GUID (16)
    #   +32 first LBA (u64)  +40 last LBA (u64)
    #   +48 attributes (u64) +56 name (72, UTF-16LE)
    e = bytearray(ENTRY_SIZE)
    e[0:16]   = type_guid
    e[16:32]  = part_guid_bytes
    struct.pack_into("<Q", e, 32, first_lba)
    struct.pack_into("<Q", e, 40, last_lba)
    struct.pack_into("<Q", e, 48, 0)
    e[56:128] = name
    return bytes(e)

# --- partition array (128 entries) ----------------------------------
entries = bytearray(ENTRY_SIZE * ENTRY_COUNT)
p1 = gpt_entry(ESP_GUID,   part_guid(1), 34,    2081, utf16_name("EFI System"))
p2 = gpt_entry(LINUX_GUID, part_guid(2), 2082, 30000, utf16_name("ham-root"))
entries[0:ENTRY_SIZE]              = p1
entries[ENTRY_SIZE:2*ENTRY_SIZE]   = p2
array_crc = binascii.crc32(bytes(entries)) & 0xFFFFFFFF

# --- GPT header @ LBA 1 ---------------------------------------------
disk_guid = uuid.UUID(int=0xC0FFEE).bytes_le
hdr = bytearray(SECTOR)
hdr[0:8]   = b"EFI PART"
struct.pack_into("<I", hdr, 8,  0x00010000)        # revision 1.0
struct.pack_into("<I", hdr, 12, 92)                # header size
struct.pack_into("<I", hdr, 16, 0)                 # header CRC (filled below)
struct.pack_into("<I", hdr, 20, 0)                 # reserved
struct.pack_into("<Q", hdr, 24, 1)                 # current LBA
struct.pack_into("<Q", hdr, 32, NSEC - 1)          # backup LBA
struct.pack_into("<Q", hdr, 40, 34)                # first usable LBA
struct.pack_into("<Q", hdr, 48, NSEC - 34)         # last usable LBA
hdr[56:72] = disk_guid
struct.pack_into("<Q", hdr, 72, ARRAY_LBA)         # partition array LBA
struct.pack_into("<I", hdr, 80, ENTRY_COUNT)       # number of entries
struct.pack_into("<I", hdr, 84, ENTRY_SIZE)        # entry size
struct.pack_into("<I", hdr, 88, array_crc)         # array CRC32
hdr_crc = binascii.crc32(bytes(hdr[0:92])) & 0xFFFFFFFF
struct.pack_into("<I", hdr, 16, hdr_crc)

# --- protective MBR @ LBA 0 (type 0xEE spanning the disk) -----------
mbr = bytearray(SECTOR)
off = 0x1BE
# boot flag, CHS start, type 0xEE, CHS end, LBA start=1, sector count.
mbr[off]   = 0x00
mbr[off+4] = 0xEE
struct.pack_into("<I", mbr, off+8, 1)
span = NSEC - 1
struct.pack_into("<I", mbr, off+12, span if span <= 0xFFFFFFFF else 0xFFFFFFFF)
mbr[0x1FE] = 0x55
mbr[0x1FF] = 0xAA

disk = bytearray(NSEC * SECTOR)
disk[0:SECTOR] = mbr
disk[SECTOR:2*SECTOR] = hdr
disk[ARRAY_LBA*SECTOR:ARRAY_LBA*SECTOR+len(entries)] = entries

open(img, "wb").write(disk)
print("[test_gpt_names] wrote %d-sector GPT disk: p1=\"EFI System\" p2=\"ham-root\"" % NSEC)
PY

echo "[test_gpt_names] (2/5) Author the EBR fixture disk (vda) so the chained self-test fires"
python3 - "$EBRDISK" <<'PY'
import sys, struct

img = sys.argv[1]
SECTOR = 512
NSEC = 131072
EXT_BASE = 2048

def mbr_entry(ptype, lba_start, nsec):
    return struct.pack("<B3sB3sII", 0, b"\x00\x00\x00", ptype,
                       b"\x00\x00\x00", lba_start, nsec)

EMPTY = b"\x00" * 16

def sector_with_table(entries):
    s = bytearray(SECTOR)
    off = 0x1BE
    for e in entries:
        s[off:off+16] = e
        off += 16
    s[0x1FE] = 0x55
    s[0x1FF] = 0xAA
    return bytes(s)

disk = bytearray(NSEC * SECTOR)
ext_span = NSEC - EXT_BASE
disk[0:SECTOR] = sector_with_table([
    mbr_entry(0x05, EXT_BASE, ext_span), EMPTY, EMPTY, EMPTY])
disk[EXT_BASE*SECTOR:(EXT_BASE+1)*SECTOR] = sector_with_table([
    mbr_entry(0x83, 2048, 2048), mbr_entry(0x05, 6144, 2048), EMPTY, EMPTY])
EBR2 = 8192
disk[EBR2*SECTOR:(EBR2+1)*SECTOR] = sector_with_table([
    mbr_entry(0x83, 2048, 4096), mbr_entry(0x05, 14336, 4096), EMPTY, EMPTY])
EBR3 = 16384
disk[EBR3*SECTOR:(EBR3+1)*SECTOR] = sector_with_table([
    mbr_entry(0x83, 2048, 8192), EMPTY, EMPTY, EMPTY])
open(img, "wb").write(disk)
print("[test_gpt_names] wrote EBR fixture (vda)")
PY

echo "[test_gpt_names] (3/5) Build userland (init) + plant /etc/partebr-test marker"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf ENABLE_PARTEBR_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_gpt_names] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_gpt_names] (5/5) Boot QEMU: EBR disk on vda, named-GPT disk on vdb"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$EBRDISK",if=virtio,format=raw \
    -drive file="$GPTDISK",if=virtio,format=raw \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_gpt_names] --- GPT-name self-test output ---"
grep -a -E "\[gpt-names\]|name=\"" "$LOG" || true
echo "[test_gpt_names] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_gpt_names] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -a -F -q "[gpt-names] FAIL" "$LOG"; then
    echo "[test_gpt_names] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[gpt-names] FAIL" "$LOG" >&2 || true
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_gpt_names] OK: $label"
    else
        echo "[test_gpt_names] MISS: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"               "[gpt-names] self-test start"
check "p1 name decoded"             "[gpt-names] idx=0 name=\"EFI System\""
check "p2 name decoded"             "[gpt-names] idx=1 name=\"ham-root\""
check "name on partition log line"  "name=\"EFI System\""
check "self-test PASS banner"       "[gpt-names] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_gpt_names] --- full log ---"
    cat "$LOG"
    echo "[test_gpt_names] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_gpt_names] PASS — GPT UTF-16LE partition names decoded:" \
     "p1=\"EFI System\", p2=\"ham-root\" (qemu rc=$rc)"
