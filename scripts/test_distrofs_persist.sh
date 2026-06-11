#!/usr/bin/env bash
# scripts/test_distrofs_persist.sh — distrofs ext4-backed durable
# store: prove a file written into the distrofs 9P namespace SURVIVES
# A REBOOT.
#
# distrofs (user/distrofs.ad) is the userland 9P file-server that
# backs the distro-shaped namespace. It serves from RAM tables for
# speed, but snapshots those tables to "#part0/distrofs<inst>.dat" on
# the ext4 volume — ordinary namespace file I/O plus a /dev/sync
# durability barrier (the old SYS_DFS_LOAD/SAVE private kernel channel
# is RETIRED) — on every Tclunk of a written fid + at clean EOF, and
# reloads the snapshot on startup. The ext4 image is distrofs's
# PRIVATE backing store — not a globally-mounted path; the namespace
# VIEW stays ephemeral, the STATE is durable.
#
# Two-boot proof (same shape as scripts/test_ext4_fsync.sh):
#
#   Boot 1 — `test_distrofs_persist write`
#     Spawns distrofs over a 9P pipe pair, creates /var/lib/dpkg/
#     pkgfile, writes a uniquely-marked payload, clunks it (snapshot
#     to ext4), then EOFs the daemon (final snapshot). Halts.
#
#   Boot 2 — `test_distrofs_persist read`
#     SAME ext4.img re-attached — NOT regenerated. Spawns a FRESH
#     distrofs, which loads the snapshot off the ext4 volume on
#     startup. Walks /var/lib/dpkg/pkgfile, opens, reads, asserts the
#     boot-1 marker comes back byte-for-byte.
#
# If the snapshot reached the disk image, the marker survives the
# reboot — durable distrofs backing proven.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_distrofs_persist.elf

# mkfs.ext4 / debugfs live in /sbin which isn't always on PATH.
find_tool() {
    local n="$1" p
    if command -v "$n" >/dev/null 2>&1; then command -v "$n"; return; fi
    for p in /sbin /usr/sbin /usr/local/sbin; do
        if [ -x "$p/$n" ]; then echo "$p/$n"; return; fi
    done
    echo ""
}
MKFS_EXT4=$(find_tool mkfs.ext4)
if [ -z "$MKFS_EXT4" ]; then
    echo "[test_distrofs_persist] SKIP — mkfs.ext4 not available"
    exit 0
fi

echo "[test_distrofs_persist] (1/6) Build userland (hamsh + distrofs)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
if [ ! -x build/user/distrofs.elf ]; then
    echo "[test_distrofs_persist] FAIL: build/user/distrofs.elf missing"
    exit 1
fi

echo "[test_distrofs_persist] (2/6) Build tests/test_distrofs_persist.ad"
mkdir -p build/user
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_distrofs_persist.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_distrofs_persist] (3/6) Plant /init = hamsh + fixture in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_distrofs_persist] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# Mint a fresh, empty ext4 scratch image — 16 MiB, 1 KiB blocks, no
# journal (the proven build_diskimg.py shape). This is distrofs's
# durable backing volume; it is the SAME file across both boots.
echo "[test_distrofs_persist] (5/6) Mint a fresh ext4 backing image"
DISK=$(mktemp --suffix=.distrofs-persist.img)
dd if=/dev/zero of="$DISK" bs=1M count=16 status=none
"$MKFS_EXT4" -F -q -b 1024 -t ext4 -L HAMNIX_DFS \
    -O '^has_journal' "$DISK"

LOG1=$(mktemp)
LOG2=$(mktemp)
trap 'rm -f "$LOG1" "$LOG2" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_distrofs_persist] (6/6) Boot #1 — write the marked file, snapshot, halt"
set +e

# Marker-gated feeder (same proven shape as test_9p_concurrency.sh):
# a freshly-booted hamsh sometimes drops the FIRST serial command line
# (it never echoes), and fixed sleeps race a slowing boot. Gate on the
# shell-ready marker, then RE-SEND the command until its echo shows up
# in the log — keyed on the echo (immediate on receipt), NOT the
# fixture marker, so a slow but received run is never double-driven.
#   $1 = serial log file   $2 = fixture argv word (write|read)
#   $3 = fixture finish regex (grep -E)
drive_boot() {
    local log="$1" word="$2" donere="$3"
    (
        for _ in $(seq 1 40); do
            grep -q "loop-enter" "$log" 2>/dev/null && break
            sleep 0.5
        done
        sleep 1
        printf '/bin/test_distrofs_persist %s\n' "$word"
        for _ in $(seq 1 10); do
            sleep 1.5
            grep -q "bin/test_distrofs_persist" "$log" 2>/dev/null && break
            printf '/bin/test_distrofs_persist %s\n' "$word"
        done
        # Wait for the fixture to finish (PASS or FAIL), then exit.
        for _ in $(seq 1 60); do
            grep -Eq "$donere" "$log" 2>/dev/null && break
            sleep 0.5
        done
        sleep 1
        printf 'exit\n'
        sleep 1
    ) | timeout 90s qemu-system-x86_64 \
        -kernel "$ELF" \
        -drive file="$DISK",if=virtio,format=raw \
        -smp 2 \
        -nographic \
        -no-reboot \
        -m 256M \
        -monitor none \
        -serial stdio \
        > "$log" 2>&1
}

drive_boot "$LOG1" write '\[dfsp\] (WRITE PASS|FAIL)'
rc1=$?

echo "[test_distrofs_persist]        Boot #2 — re-attach the SAME disk, read it back"
drive_boot "$LOG2" read '\[dfsp\] (READ PASS|FAIL)'
rc2=$?
set -e

echo "[test_distrofs_persist] --- boot #1 distrofs/dfsp lines ---"
grep -a -E '\[dfsp\]|\[distrofs\]' "$LOG1" || true
echo "[test_distrofs_persist] --- boot #2 distrofs/dfsp lines ---"
grep -a -E '\[dfsp\]|\[distrofs\]' "$LOG2" || true
echo "[test_distrofs_persist] --- end ---"

fail=0

# Any fixture FAIL line on either boot fails the test.
if grep -a -F -q "[dfsp] FAIL:" "$LOG1"; then
    echo "[test_distrofs_persist] MISS: boot #1 fixture FAIL line(s):"
    grep -a -F "[dfsp] FAIL:" "$LOG1" | sed 's/^/  /'
    fail=1
fi
if grep -a -F -q "[dfsp] FAIL:" "$LOG2"; then
    echo "[test_distrofs_persist] MISS: boot #2 fixture FAIL line(s):"
    grep -a -F "[dfsp] FAIL:" "$LOG2" | sed 's/^/  /'
    fail=1
fi

# Boot 1: the file was created, written and clunked.
if grep -a -F -q "[dfsp] write done" "$LOG1"; then
    echo "[test_distrofs_persist] OK: boot #1 created + wrote pkgfile"
else
    echo "[test_distrofs_persist] MISS: boot #1 did not finish the write"
    fail=1
fi
if grep -a -F -q "[dfsp] WRITE PASS" "$LOG1"; then
    echo "[test_distrofs_persist] OK: boot #1 snapshot taken (WRITE PASS)"
else
    echo "[test_distrofs_persist] MISS: boot #1 WRITE PASS missing"
    fail=1
fi

# Boot 1: distrofs must have persisted to the ext4 backing (not the
# silent no-backing path). The startup banner confirms a backing.
if grep -a -F -q "[distrofs] persist failed" "$LOG1"; then
    echo "[test_distrofs_persist] MISS: boot #1 reported persist failure"
    fail=1
fi

# Boot 2: a FRESH distrofs restored the snapshot from the ext4 volume.
if grep -a -F -q "[distrofs] restored snapshot from ext4 backing" "$LOG2"; then
    echo "[test_distrofs_persist] OK: boot #2 distrofs restored its ext4 snapshot"
else
    echo "[test_distrofs_persist] MISS: boot #2 did not restore a snapshot"
    fail=1
fi

# THE PROOF: boot 2 read the boot-1 marker back byte-for-byte.
if grep -a -F -q "[dfsp] read match OK" "$LOG2"; then
    echo "[test_distrofs_persist] OK: marker survived the reboot (persistence)"
else
    echo "[test_distrofs_persist] MISS: marker NOT recovered after reboot"
    fail=1
fi
if grep -a -F -q "[dfsp] READ PASS" "$LOG2"; then
    echo "[test_distrofs_persist] OK: boot #2 READ PASS"
else
    echo "[test_distrofs_persist] MISS: boot #2 READ PASS missing"
    fail=1
fi

# No CPU exception on either boot.
if grep -a -F -q "TRAP: vector" "$LOG1" || grep -a -F -q "TRAP: vector" "$LOG2"; then
    echo "[test_distrofs_persist] DIAG: kernel reported a CPU exception"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_distrofs_persist] FAIL (qemu rc1=$rc1 rc2=$rc2)"
    echo "[test_distrofs_persist] --- boot #2 full log (last 120 lines) ---"
    tail -n 120 "$LOG2"
    exit 1
fi

echo "[test_distrofs_persist] PASS — a file written into the distrofs 9P" \
     "namespace was snapshotted to the ext4 backing volume and survived" \
     "a full reboot: a fresh distrofs reloaded it and served it back"
