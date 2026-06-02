#!/usr/bin/env bash
# scripts/test_partebr.sh — MBR extended/logical partition (EBR chain) walk.
#
# Proves drivers/block/partition.ad follows an MBR EXTENDED partition
# (type 0x05) whose first sector is an EBR (Extended Boot Record) forming a
# singly-linked list of LOGICAL partitions — the classic BIOS/MBR way of
# carrying more than four partitions, which Linux enumerates as /dev/sdaN
# for N>=5. The scanner used to parse only the four primary entries + GPT;
# this test exercises the new _parse_ebr_chain() walker.
#
# Fixture (built here as raw 512-byte sectors with `dd`/Python — the most
# deterministic way to author an extended/logical MBR layout, per the
# escalation rule in the task brief). A 64 MiB raw image attached on
# virtio as "vda":
#
#   MBR @ LBA 0:
#     primary[0] = extended container, type 0x05, start=2048, span=129024.
#   EBR1 @ LBA 2048 (== ext_base):
#     entry[0] = logical, rel=2048  -> abs 4096,  nsec=2048  (p5 4096..6143)
#     entry[1] = link 0x05, rel(ext_base)=6144  -> EBR2 @ 8192
#   EBR2 @ LBA 8192:
#     entry[0] = logical, rel=2048  -> abs 10240, nsec=4096  (p6 10240..14335)
#     entry[1] = link 0x05, rel(ext_base)=14336 -> EBR3 @ 16384
#   EBR3 @ LBA 16384:
#     entry[0] = logical, rel=2048  -> abs 18432, nsec=8192  (p7 18432..26623)
#     entry[1] = empty -> chain ends.
#
# The 3-EBR chain makes the relative-offset arithmetic load-bearing: the
# EBR2->EBR3 link field (14336) is RELATIVE TO ext_base (2048), NOT to EBR2
# (8192). A buggy walker would compute EBR3 @ 8192+14336 and mis-read p7.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_partebr] PASS   (kernel prints [part-ebr] PASS)
# Fail marker:  [test_partebr] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

DISK=$(mktemp --suffix=.partebr.img)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_partebr] (1/4) Author the raw MBR + 3-EBR extended layout"
python3 - "$DISK" <<'PY'
import sys, struct

img = sys.argv[1]
SECTOR = 512
NSEC = 131072            # 64 MiB / 512
EXT_BASE = 2048          # start LBA of the extended container

def mbr_entry(ptype, lba_start, nsec):
    # 16-byte MBR/EBR partition entry. boot flag 0, CHS fields zeroed
    # (LBA is authoritative); type byte at +4; LBA start at +8; sector
    # count at +12 — all little-endian.
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

# --- MBR @ LBA 0: one extended container (type 0x05) ----------------
ext_span = NSEC - EXT_BASE       # 129024 sectors
mbr = sector_with_table([
    mbr_entry(0x05, EXT_BASE, ext_span),
    EMPTY, EMPTY, EMPTY,
])
disk[0:SECTOR] = mbr

# --- EBR1 @ LBA 2048 == ext_base ------------------------------------
# logical p5: rel=2048 -> abs 4096, nsec=2048 (end 6143)
# link entry[1] rel(ext_base)=6144 -> EBR2 @ 8192
ebr1 = sector_with_table([
    mbr_entry(0x83, 2048, 2048),
    mbr_entry(0x05, 6144, 2048),   # next-EBR link; nsec is conventional
    EMPTY, EMPTY,
])
disk[EXT_BASE*SECTOR:(EXT_BASE+1)*SECTOR] = ebr1

# --- EBR2 @ LBA 8192 ------------------------------------------------
# logical p6: rel=2048 -> abs 10240, nsec=4096 (end 14335)
# link entry[1] rel(ext_base)=14336 -> EBR3 @ 16384
EBR2 = 8192
ebr2 = sector_with_table([
    mbr_entry(0x83, 2048, 4096),
    mbr_entry(0x05, 14336, 4096),  # rel to ext_base, NOT to EBR2
    EMPTY, EMPTY,
])
disk[EBR2*SECTOR:(EBR2+1)*SECTOR] = ebr2

# --- EBR3 @ LBA 16384: terminal -------------------------------------
# logical p7: rel=2048 -> abs 18432, nsec=8192 (end 26623)
# entry[1] empty -> chain ends
EBR3 = 16384
ebr3 = sector_with_table([
    mbr_entry(0x83, 2048, 8192),
    EMPTY, EMPTY, EMPTY,
])
disk[EBR3*SECTOR:(EBR3+1)*SECTOR] = ebr3

open(img, "wb").write(disk)
print("[test_partebr] wrote %d-sector image with 3-EBR logical chain" % NSEC)
PY

echo "[test_partebr] (2/4) Build userland (init) + plant /etc/partebr-test"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf ENABLE_PARTEBR_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_partebr] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_partebr] (4/4) Boot QEMU with the extended-partition disk on vda"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$DISK",if=virtio,format=raw \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_partebr] --- EBR self-test output ---"
grep -a -E "\[part-ebr\]" "$LOG" || true
echo "[test_partebr] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_partebr] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -a -F -q "[part-ebr] FAIL" "$LOG"; then
    echo "[test_partebr] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[part-ebr] FAIL" "$LOG" >&2 || true
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_partebr] OK: $label"
    else
        echo "[test_partebr] MISS: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"               "[part-ebr] self-test start"
check "p5 enumerated at 4096..6143" "[partition] disk=vda idx=4 lba=4096..6143 type=0x83"
check "p6 enumerated at 10240..."   "[partition] disk=vda idx=5 lba=10240..14335 type=0x83"
check "p7 enumerated at 18432..."   "[partition] disk=vda idx=6 lba=18432..26623 type=0x83"
check "self-test PASS banner"       "[part-ebr] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_partebr] --- full log ---"
    cat "$LOG"
    echo "[test_partebr] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_partebr] PASS — MBR extended partition walked: three logical" \
     "partitions enumerate at exact absolute LBAs across a 3-EBR chain" \
     "(qemu rc=$rc)"
