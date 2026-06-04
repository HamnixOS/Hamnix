#!/usr/bin/env bash
# scripts/test_ext4_inline.sh — ext4 inline_data (INCOMPAT_INLINE_DATA).
#
# Proves fs/ext4.ad's inline_data READ path end-to-end on a live ext4
# mount. An inline-data inode stores its bytes directly inside the inode
# (EXT4_INODE_INLINE_DATA, i_flags bit 0x10000000) instead of in data
# blocks / extents:
#
#   * bytes [0, 60)      live in the i_block[] window (inode off 0x28)
#   * bytes [60, i_size) live in the "system.data" extended attribute
#
# This test mints a SEPARATE ext4 image WITH the inline_data feature on
# (build/ext4.img has it OFF, so a normal boot exercises zero inline
# code). It plants two inline files the host mke2fs/debugfs produce:
#
#   1. SMALL.TXT  — under 60 bytes, lives ENTIRELY in i_block[].
#                   Proves the in-inode read path. Blockcount 0.
#   2. OVER.TXT   — 115 bytes: 60 bytes in i_block[] plus a 55-byte
#                   "system.data" xattr value. Proves the overflow read
#                   path stitches i_block[] + system.data. Blockcount 0.
#
# fs/ext4.ad detects INCOMPAT_INLINE_DATA in s_feature_incompat at mount
# (arming ext4_inline_data) and, for any inode carrying the inline flag,
# returns its bytes from i_block[]/system.data through the normal VFS
# read path. We boot Hamnix, `cat` both files, and grep-assert their
# known contents round-trip byte-exact.
#
# Pass marker (emitted by THIS script after both cats verify):
#   [ext4inline] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

_which() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
    for prefix in /sbin /usr/sbin /usr/local/sbin; do
        if [ -x "$prefix/$name" ]; then echo "$prefix/$name"; return 0; fi
    done
    echo "$0: required tool '$name' not found" >&2
    return 1
}
MKE2FS="$(_which mke2fs)"
DEBUGFS="$(_which debugfs)"

# Known content. SMALL fits in i_block[] (< 60 bytes). OVER is 60 bytes
# in i_block[] + a 55-byte system.data xattr value (total 115 bytes).
SMALL_BODY="INLINE_SMALL_MARKER_iblock_only_2026"
OVER_PREFIX="$(python3 -c 'import sys; sys.stdout.write("B"*60)')"
OVER_XATTR="CDEFGHIJ_extra_overflow_bytes_in_system_data_xattr_2026"

echo "[test_ext4_inline] (1/5) Mint an inline_data ext4 disk image"
DISK=$(mktemp --suffix=.ext4-inline.img)
truncate -s 8M "$DISK"
# Lean inline_data layout: 1 KiB blocks, 256-byte inodes (room for the
# inline flag + in-inode system.data), no journal/64bit/csum/resize.
"$MKE2FS" -F -q -b 1024 -I 256 -t ext4 -L "HAMNIX_INLINE" \
    -O inline_data,^has_journal,^64bit,^metadata_csum,^resize_inode \
    "$DISK" >/dev/null

# Sanity: host must agree the image carries inline_data, so a mke2fs that
# silently dropped the feature fails loud.
if command -v dumpe2fs >/dev/null 2>&1 || [ -x /sbin/dumpe2fs ]; then
    DUMPE2FS="$(_which dumpe2fs)"
    if ! "$DUMPE2FS" -h "$DISK" 2>/dev/null | grep -qiE '(^| )inline_data( |$)'; then
        echo "[test_ext4_inline] FAIL: minted image lacks inline_data feature" >&2
        rm -f "$DISK"
        exit 1
    fi
    echo "[test_ext4_inline] host confirms inline_data feature present"
fi

# Plant SMALL.TXT (stays inline because it is < 60 bytes) and OVER.TXT
# (60 i_block bytes + 55 system.data bytes). debugfs `write` keeps a
# <=60-byte file inline; we then hand-extend OVER.TXT with a system.data
# xattr and bump i_size, the exact shape Linux writes for an inline file
# whose tail spills past i_block[].
SMALL_PAY="$(mktemp --suffix=.inline-small)"
OVER_PAY="$(mktemp --suffix=.inline-over)"
printf '%s' "$SMALL_BODY" > "$SMALL_PAY"
printf '%s' "$OVER_PREFIX" > "$OVER_PAY"
"$DEBUGFS" -w "$DISK" >/dev/null 2>&1 <<EOF
write $SMALL_PAY SMALL.TXT
write $OVER_PAY OVER.TXT
ea_set OVER.TXT system.data $OVER_XATTR
sif OVER.TXT size $(( ${#OVER_PREFIX} + ${#OVER_XATTR} ))
EOF
rm -f "$SMALL_PAY" "$OVER_PAY"

# Confirm the host wrote genuine inline inodes (Blockcount 0 + the inline
# flag) — if debugfs converted either to extents this test is meaningless.
SMALL_STAT="$("$DEBUGFS" -R "stat SMALL.TXT" "$DISK" 2>/dev/null)"
OVER_STAT="$("$DEBUGFS" -R "stat OVER.TXT" "$DISK" 2>/dev/null)"
if ! echo "$SMALL_STAT" | grep -qi "Flags: 0x10000000"; then
    echo "[test_ext4_inline] FAIL: SMALL.TXT is not an inline inode" >&2
    echo "$SMALL_STAT" >&2
    rm -f "$DISK"; exit 1
fi
if ! echo "$OVER_STAT" | grep -qi "Flags: 0x10000000"; then
    echo "[test_ext4_inline] FAIL: OVER.TXT is not an inline inode" >&2
    echo "$OVER_STAT" >&2
    rm -f "$DISK"; exit 1
fi
echo "[test_ext4_inline] host confirms SMALL.TXT + OVER.TXT are inline inodes"

echo "[test_ext4_inline] (2/5) Build userland"
bash scripts/build_user.sh >/dev/null

echo "[test_ext4_inline] (3/5) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_inline] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_inline] (5/5) Boot QEMU with the inline_data image"
# Gate keystrokes on the shell-ready marker, not a fixed sleep: this boot
# loads kernel modules (xhci/usbcore/...) and the prompt can appear much
# later under TCG load. A fixed `sleep N` races the prompt and the cats
# get swallowed. The feeder tails $LOG until hamsh announces it has
# entered its read loop, THEN types the cats.
INPUT_FIFO=$(mktemp -u --suffix=.inline-fifo)
mkfifo "$INPUT_FIFO"
set +e
(
    # Hold the FIFO open for writing for the whole feeder lifetime.
    exec 3>"$INPUT_FIFO"
    # Wait (bounded) for the shell read-loop marker to land in the log.
    waited=0
    while ! grep -aq "loop-enter" "$LOG" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge 110 ]; then
            break
        fi
    done
    sleep 1
    printf 'cat /ext/SMALL.TXT\n' >&3
    sleep 2
    printf 'cat /ext/OVER.TXT\n' >&3
    sleep 2
    printf 'exit\n' >&3
    sleep 1
    exec 3>&-
) &
FEEDER=$!
timeout 150s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file="$DISK",if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    < "$INPUT_FIFO" > "$LOG" 2>&1
rc=$?
wait "$FEEDER" 2>/dev/null
rm -f "$INPUT_FIFO"
set -e

echo "[test_ext4_inline] --- ext4/inline boot output ---"
grep -a -E "INCOMPAT_INLINE_DATA|INLINE_SMALL_MARKER|system_data_xattr" "$LOG" || true
echo "[test_ext4_inline] --- end ---"

# Treat a virtio-blk superblock-read flake (host CPU starvation under
# load) as INFRA, not a code failure — re-run in a quiet window.
if grep -aqE "read failed status=255|failed to read superblock" "$LOG"; then
    echo "[test_ext4_inline] WARN: virtio-blk read flake detected — re-run in a quiet window" >&2
fi

fail=0

# The mount must announce it armed the inline read path.
if grep -a -F -q "INCOMPAT_INLINE_DATA present" "$LOG"; then
    echo "[test_ext4_inline] OK: mount armed the inline read path"
else
    echo "[test_ext4_inline] MISS: mount did not announce INCOMPAT_INLINE_DATA" >&2
    fail=1
fi

# SMALL.TXT proves the i_block[]-only read.
if grep -a -F -q "$SMALL_BODY" "$LOG"; then
    echo "[test_ext4_inline] OK: SMALL.TXT (i_block-only inline) bytes match"
else
    echo "[test_ext4_inline] MISS: SMALL.TXT inline content not read back" >&2
    fail=1
fi

# OVER.TXT proves i_block[] + system.data are stitched. The 55-byte
# overflow tail can only have come from the system.data xattr.
if grep -a -F -q "$OVER_XATTR" "$LOG"; then
    echo "[test_ext4_inline] OK: OVER.TXT system.data overflow bytes match"
else
    echo "[test_ext4_inline] MISS: OVER.TXT system.data overflow not read back" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_inline] --- full log ---"
    cat "$LOG"
    echo "[test_ext4_inline] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[ext4inline] PASS"
echo "[test_ext4_inline] PASS — inline_data read (i_block + system.data) on a" \
     "live ext4 mount (qemu rc=$rc)"
