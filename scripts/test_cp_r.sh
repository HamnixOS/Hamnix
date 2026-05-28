#!/usr/bin/env bash
# scripts/test_cp_r.sh - verify `cp -r` (recursive copy) end-to-end.
#
# This is the regression test for the small-commands #5 item:
#
#   * Kernel: vfs_mkdir wires /ext/* to ext4_mkdir_live so the on-disk
#     mount can receive new directories live.
#   * Userland: user/cp.ad grew a -r flag that walks SRC depth-first,
#     mkdir's each subdir, copies each file.
#
# Phase A (offline): rebuild + assert cp.elf is non-empty.
# Phase B (QEMU smoke): drive hamsh through two scenarios:
#
#   tmpfs-only:
#     mkdir /tmp/src && mkdir /tmp/src/sub
#     echo hello-a > /tmp/src/a.txt
#     echo hello-b > /tmp/src/sub/b.txt
#     cp -r /tmp/src /tmp/dst
#     cat /tmp/dst/a.txt      -> "hello-a"
#     cat /tmp/dst/sub/b.txt  -> "hello-b"
#
#   ext4 destination (exercises the new vfs_mkdir wire):
#     cp -r /tmp/dst /ext/dst-on-disk
#     cat /ext/dst-on-disk/a.txt      -> "hello-a"
#     cat /ext/dst-on-disk/sub/b.txt  -> "hello-b"
#
#   Big-file copy (exercises the multi-block ext4 write path):
#     seq 1 5000 > /tmp/big.bin       # ~24 KiB of "<line>\n" text
#     cp /tmp/big.bin /ext/big.bin
#     wc < /tmp/big.bin -> "<lines> <words> <bytes>"
#     wc < /ext/big.bin -> identical triple
#   The pre-multi-block kernel write capped the destination at one
#   ext4 block (1 KiB / 4 KiB depending on mkfs), so the byte count
#   on ext would have been much lower than tmpfs's. With the
#   ext4_write_open_file streaming writer, both numbers match.
#
# Uses the readiness-marker driver from _qemu_drive.sh so the test
# is stable across orchestrator host loads.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
ROOTFS_IMG=build/hamnix-rootfs.img

echo "[test_cp_r] (A1) build_user.sh"
bash scripts/build_user.sh > /tmp/test_cp_r.build_user.log 2>&1 || {
    echo "[test_cp_r] FAIL: build_user.sh failed. Tail of log:"
    tail -30 /tmp/test_cp_r.build_user.log
    exit 1
}
if [ ! -s build/user/cp.elf ]; then
    echo "[test_cp_r] FAIL: build/user/cp.elf missing or empty"
    exit 1
fi
echo "[test_cp_r] OK: cp.elf produced ($(stat -c%s build/user/cp.elf) bytes)"

echo "[test_cp_r] (A2) build initramfs + kernel + rootfs.img"
python3 scripts/build_initramfs.py > /tmp/test_cp_r.initramfs.log 2>&1
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" \
    > /tmp/test_cp_r.kernel.log 2>&1 || {
    echo "[test_cp_r] FAIL: kernel compile failed. Tail of log:"
    tail -30 /tmp/test_cp_r.kernel.log
    exit 1
}
python3 scripts/build_rootfs_img.py > /tmp/test_cp_r.rootfs.log 2>&1
echo "[test_cp_r] OK: build artifacts produced"

# Distinct, easy-to-grep markers for each phase of the test. The cat
# outputs land between matching <PHASE>_BEGIN / <PHASE>_END lines so
# the parser only sees the file content for that phase.
LOG=$(mktemp /tmp/test-cp-r.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

echo "[test_cp_r] (B1) Boot QEMU + drive recursive cp scenarios"
set +e
# Notes on the command sequence:
#   * `echo X > FILE` -> hamsh redirects stdout via sys_open_write,
#     plants "X\n" in the file. (8 chars per file, well below 8 KiB.)
#   * We bracket each `cat` output with echo markers so the test can
#     extract just the file content from the noisy boot log.
QEMU_EXTRA_ARGS="-drive file=$ROOTFS_IMG,if=virtio,format=raw" \
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 120 \
    -- "mkdir /tmp/src"                                       2 \
       "mkdir /tmp/src/sub"                                   2 \
       "/bin/echo hello-a > /tmp/src/a.txt"                   2 \
       "/bin/echo hello-b > /tmp/src/sub/b.txt"               2 \
       "cp -r /tmp/src /tmp/dst"                              3 \
       "echo TMPFS_A_BEGIN"                                   2 \
       "cat /tmp/dst/a.txt"                                   2 \
       "echo TMPFS_A_END"                                     2 \
       "echo TMPFS_B_BEGIN"                                   2 \
       "cat /tmp/dst/sub/b.txt"                               2 \
       "echo TMPFS_B_END"                                     2 \
       "cp -r /tmp/dst /ext/dst-on-disk"                      4 \
       "echo EXT_A_BEGIN"                                     2 \
       "cat /ext/dst-on-disk/a.txt"                           2 \
       "echo EXT_A_END"                                       2 \
       "echo EXT_B_BEGIN"                                     2 \
       "cat /ext/dst-on-disk/sub/b.txt"                       2 \
       "echo EXT_B_END"                                       2 \
       "seq 1 5000 > /tmp/big.bin"                            5 \
       "echo BIG_TMPFS_WC_BEGIN"                              2 \
       "wc < /tmp/big.bin"                                    3 \
       "echo BIG_TMPFS_WC_END"                                2 \
       "cp /tmp/big.bin /ext/big.bin"                         6 \
       "echo BIG_EXT_WC_BEGIN"                                2 \
       "wc < /ext/big.bin"                                    4 \
       "echo BIG_EXT_WC_END"                                  2 \
       "echo CP_R_DONE"                                       2 \
       "exit"                                                 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_cp_r] --- captured ---"
cat "$LOG"
echo "[test_cp_r] --- end ---"

fail=0

# Shell came up at all.
if ! grep -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[test_cp_r] FAIL: hamsh never reached the interactive loop"
    trap - EXIT
    echo "[test_cp_r] preserved log: $LOG"
    exit 1
fi

# Markers seen at all (driver-actually-fed sanity).
if ! grep -F -q "CP_R_DONE" "$LOG"; then
    echo "[test_cp_r] FAIL: end marker CP_R_DONE never appeared - boot/feed wedged"
    trap - EXIT
    echo "[test_cp_r] preserved log: $LOG"
    exit 1
fi

# Helper: extract a bracketed block by name, return its inner content.
extract_block() {
    local tag="$1"
    sed -n "/${tag}_BEGIN/,/${tag}_END/p" "$LOG"
}

check_block_has() {
    local tag="$1"; local needle="$2"
    local block
    block=$(extract_block "$tag")
    if echo "$block" | grep -F -q "$needle"; then
        echo "[test_cp_r] OK: $tag block contains '$needle'"
    else
        echo "[test_cp_r] MISS: $tag block does NOT contain '$needle'"
        echo "[test_cp_r]   block was:"
        echo "$block" | sed 's/^/    /'
        fail=1
    fi
}

check_block_has TMPFS_A hello-a
check_block_has TMPFS_B hello-b
check_block_has EXT_A   hello-a
check_block_has EXT_B   hello-b

# Multi-block writer assertions. `wc` writes "<lines> <words> <bytes>\n";
# the source is `seq 1 5000`, which produces 5000 newlines and bytes
# = 9*2 + 90*3 + 900*4 + 4001*5 = 18 + 270 + 3600 + 20005 = 23893.
# Extract the byte_ct (third field) from each wc block and assert
# (a) tmpfs reports >8192 bytes, (b) ext4 byte_ct == tmpfs byte_ct.
#
# Heuristic: wc's "<lines> <words> <bytes>\n" line in the log is
# prefixed with printk-frame garbage like "<binary><binary>[" before
# the digits. We grep for any line containing "5000 5000 <num>" (the
# line + word counts are deterministic from `seq 1 5000`), strip
# everything up to "5000 5000 ", and read the byte count off the
# remainder.
extract_wc_bytes() {
    local tag="$1"
    local block
    block=$(extract_block "$tag")
    # Run awk in the C locale so it doesn't choke on the binary
    # printk-frame prefix that sometimes precedes the digits. Match
    # "5000 5000 <num>" anywhere in a line, return the third number.
    printf '%s\n' "$block" \
        | LANG=C awk '
            match($0, /5000 5000 [0-9]+/) {
                m = substr($0, RSTART+10, RLENGTH-10);
                print m;
                exit
            }
        '
}

big_tmpfs_bytes=$(extract_wc_bytes BIG_TMPFS_WC)
big_ext_bytes=$(extract_wc_bytes BIG_EXT_WC)

if [ -z "$big_tmpfs_bytes" ]; then
    echo "[test_cp_r] MISS: could not extract tmpfs big.bin byte count"
    fail=1
elif [ "$big_tmpfs_bytes" -lt 8193 ]; then
    echo "[test_cp_r] MISS: tmpfs big.bin only $big_tmpfs_bytes bytes (expected >8 KiB)"
    fail=1
else
    echo "[test_cp_r] OK: tmpfs big.bin = $big_tmpfs_bytes bytes (>8 KiB)"
fi

if [ -z "$big_ext_bytes" ]; then
    echo "[test_cp_r] MISS: could not extract ext4 big.bin byte count"
    fail=1
elif [ "$big_ext_bytes" != "$big_tmpfs_bytes" ]; then
    echo "[test_cp_r] MISS: ext4 big.bin = $big_ext_bytes bytes, tmpfs = $big_tmpfs_bytes (multi-block write cap?)"
    fail=1
else
    echo "[test_cp_r] OK: ext4 big.bin = $big_ext_bytes bytes (matches tmpfs)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_cp_r] FAIL (qemu rc=$rc)"
    trap - EXIT
    echo "[test_cp_r] preserved log: $LOG"
    exit 1
fi
echo "[test_cp_r] PASS (qemu rc=$rc)"
