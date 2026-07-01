#!/usr/bin/env bash
# scripts/test_ext4_mkdir.sh — ext4 mkdir create-path verification.
#
# Proves the WIRED mkdir path: vfs_mkdir (fs/vfs.ad) routes an ext4-backed
# path to the existing ext4_mkdir_live (fs/ext4.ad), creating a REAL on-disk
# directory entry. The in-kernel ext4_mkdir_selftest() (gated on the cpio
# marker /etc/ext4-mkdir-test) mkdir's a fresh directory in the partition
# root of the live ext4 mount, then re-reads the parent directory and
# confirms the new entry exists carrying EXT4_FT_DIR (file_type 2) and that
# the new inode reports S_IFDIR. The selftest itself does all the work, so
# the host only has to attach a plain, empty ext4 scratch disk on virtio.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_ext4_mkdir] PASS   (kernel prints [ext4-mkdir] PASS)
# Fail marker:  [test_ext4_mkdir] FAIL

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

DISK=$(mktemp --suffix=.ext4mkdir.img)
LOG=$(mktemp)
trap 'rm -f "$LOG" "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_ext4_mkdir] (1/4) Mint a 1 KiB-block ext4 scratch image"
# 64 MiB headroom; 1 KiB blocks match the driver's well-trodden path. The
# kernel selftest creates the test directory itself, so the disk ships empty.
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_MKDIR" -O '^has_journal' "$DISK" >/dev/null

echo "[test_ext4_mkdir] (2/4) Build userland + plant /etc/ext4-mkdir-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_EXT4_MKDIR_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_ext4_mkdir] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ext4_mkdir] (4/4) Boot QEMU with the ext4 scratch image"
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

echo "[test_ext4_mkdir] --- ext4-mkdir self-test output ---"
grep -a -E "\[ext4-mkdir\]|\[vfs-named-mkdir\]" "$LOG" || true
echo "[test_ext4_mkdir] --- end ---"

fail=0

if grep -a -F -q "[ext4-mkdir] FAIL" "$LOG"; then
    echo "[test_ext4_mkdir] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[ext4-mkdir] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[ext4-mkdir] PASS" "$LOG"; then
    echo "[test_ext4_mkdir] MISS: self-test PASS banner (expected '[ext4-mkdir] PASS')" >&2
    fail=1
fi

# `#t`-prefix collision regression (vfs_named_mkdir_selftest): a
# multi-char `#t<word>` named root must mkdir onto ext4 via vfs_mkdir, not
# be captured by the `#t` tmpfs fast-path. Armed by the same marker.
if grep -a -F -q "[vfs-named-mkdir] FAIL" "$LOG"; then
    echo "[test_ext4_mkdir] FAIL: \`#t<word>\` named-root mkdir mis-routed" >&2
    grep -a -F "[vfs-named-mkdir] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[vfs-named-mkdir] PASS" "$LOG"; then
    echo "[test_ext4_mkdir] MISS: \`#t<word>\` regression PASS banner (expected '[vfs-named-mkdir] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4_mkdir] --- full log ---"
    cat "$LOG"
    echo "[test_ext4_mkdir] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_ext4_mkdir] PASS — mkdir creates a real DIR-typed entry on the" \
     "live ext4 mount via vfs_mkdir -> ext4_mkdir_live (qemu rc=$rc)"
