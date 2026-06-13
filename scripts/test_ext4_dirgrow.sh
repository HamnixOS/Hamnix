#!/usr/bin/env bash
# scripts/test_ext4_dirgrow.sh — ext4 truncate-of-index-node-file +
# linear directory growth into htree.
#
# Closes the TODO §10/§16 follow-up: "ext4 truncate on index-node files;
# growing a full ext4 dir block". Two write paths in one in-kernel
# self-test (ext4_dirgrow_selftest, gated on /etc/ext4-dirgrow-test):
#
#   (A) Truncate of an index-node file. Build a file by appending
#       deliberately non-contiguous one-block extents until the inode's
#       extent tree promotes to eh_depth >= 1 (forcing index-node /
#       leaf-block metadata). Truncate it down to ONE block, then prove:
#         * i_size lands at exactly one block,
#         * the tree FOLDED back to inline depth-0 (no orphaned
#           index/leaf metadata blocks),
#         * the surviving block bytes are byte-identical to the
#           pre-truncate content,
#         * a read past EOF returns 0 bytes,
#         * the filesystem free-block count rises by AT LEAST the freed
#           data-block count (the truncate path returned every freed
#           block to the allocator).
#       This is the complement of the existing depth-1/2 truncate-to-0
#       round-trips (ext4_extentidx_selftest / ext4_extentd2_selftest):
#       proves a partial truncate of an index-node file preserves the
#       surviving content AND reclaims the freed blocks.
#
#   (B) Linear -> htree directory growth. mkdir a fresh subdir of root
#       (a single-block linear directory: only "." + ".."). Create files
#       in it until the single block overflows; the new
#       _ext4_convert_linear_to_htree path in fs/ext4.ad rebuilds the
#       directory as a real dx_root htree (dx_root_info + 2 leaf blocks).
#       Then assert:
#         * the subdir carries EXT4_INDEX_FL after the overflow,
#         * dx_root indirect_levels stays sane (0 = 1-level htree),
#         * EVERY name added BEFORE and AFTER the conversion still
#           resolves via the standard lookup path (both htree hash
#           descent and the linear-scan oracle agree),
#         * the FIRST-inserted name still resolves to its original
#           inum (the conversion preserved identity, not just presence).
#
# Fixture: a host-minted 1 KiB-block ext4 image (no journal, no
# metadata_csum) — same recipe as test_ext4_htree_insert.sh. We use a
# FRESH image rather than build/ext4.img so the pre-existing fixture's
# crowded root directory doesn't interact with the unconditional kernel
# smoke tests (which create files in root and rely on it having slack).
#
# Pass marker:  [test_ext4_dgrow] PASS   (kernel prints [ext4dgrow] PASS)
# Fail marker:  [test_ext4_dgrow] FAIL

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
MKFS="$(_which mkfs.ext4)"

DISK=$(mktemp --suffix=.ext4dgrow.img)
LOG=$(mktemp)
cleanup() {
    rm -f "$LOG" "$DISK"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_ext4_dgrow] (1/5) Mint a 1 KiB-block ext4 image (no journal, no csum)"
# 64 MiB headroom @ 1 KiB blocks: room for the ~200 fragmented file-data
# + spacer blocks the truncate test allocates and the ~200 child-files
# the dir-growth test mints, plus the unconditional kernel smoke tests
# that run before our gated self-test (rename / truncate / fsync each
# create a small file in root).
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_DGROW" \
    -O '^has_journal,^metadata_csum' "$DISK" >/dev/null

echo "[test_ext4_dgrow] (2/5) Build userland + plant /etc/ext4-dirgrow-test"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4_DIRGROW_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_dgrow] (3/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ext4_dgrow] (4/5) Boot QEMU with the fresh ext4 image"
set +e
timeout 240s qemu-system-x86_64 \
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

echo "[test_ext4_dgrow] --- ext4dgrow self-test output ---"
grep -a -E "\[ext4dgrow\]" "$LOG" || true
echo "[test_ext4_dgrow] --- end ---"

fail=0

if grep -a -F -q "[ext4dgrow] FAIL" "$LOG"; then
    echo "[test_ext4_dgrow] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4dgrow] FAIL" "$LOG" >&2 || true
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_ext4_dgrow] OK: $label"
    else
        echo "[test_ext4_dgrow] MISS: $label (expected '$needle')" >&2
        fail=1
    fi
}

# (A) Truncate-index-node assertions.
check "index-node file forced (eh_depth>=1)"   "[ext4dgrow] PASS forced index-node file"
check "truncate folded tree back to depth 0"   "[ext4dgrow] PASS truncate folded index tree"
check "surviving block intact + EOF clean"     "[ext4dgrow] PASS surviving block bytes intact"
check "truncate returned the data blocks"      "[ext4dgrow] PASS truncate returned"

# (B) Linear -> htree conversion assertions.
check "fresh subdir starts as linear"          "[ext4dgrow] PASS fresh dgrowdir starts as linear"
check "dir overflowed + converted to htree"    "[ext4dgrow] PASS dir converted to EXT4_INDEX_FL"
check "all names resolve after convert"        "[ext4dgrow] PASS all"
check "first-inserted name kept its inum"      "[ext4dgrow] PASS first-inserted name kept"

# Overall self-test verdict (last [ext4dgrow] PASS without a label).
check "self-test PASS banner"                  "[ext4dgrow] PASS"

echo "[test_ext4_dgrow] (5/5) verdict"
if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_dgrow] --- full log ---"
    cat "$LOG"
    echo "[test_ext4_dgrow] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_ext4_dgrow] PASS — ext4 truncate on an index-node file folds the" \
     "extent tree back, reclaims the data blocks, and leaves the surviving" \
     "block byte-intact; a single-block linear dir promoted to an htree" \
     "(dx_root + 2 leaves) keeps every name resolvable through the standard" \
     "lookup path (qemu rc=$rc)"
