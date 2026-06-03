#!/usr/bin/env bash
# scripts/test_p9wstat_ext4.sh — wstat chmod/truncate round-trip on ext4.
#
# Proves the Plan 9 wstat handler (sys/src/9/port/sysfile.ad::_apply_wstat)
# now HONOURS the mode (chmod) and length (truncate) legs against a live ext4
# mount instead of dropping the mode / rejecting the length. The in-kernel
# wstat_apply_selftest() (gated on the cpio marker /etc/wstat-apply-test):
#   1. creates /ext/WSTATAP.TXT with 16 bytes of content + mode 0644,
#   2. drives do_wstat with a Dir record carrying mode=0600 + length=4,
#   3. re-reads i_mode (ext4_inode_owner_at) and the do_stat length and
#      asserts mode==0600 AND length==4 — the chmod/truncate round-trip.
# The selftest does all the work, so the host just attaches a plain, empty
# ext4 scratch disk on virtio (a real superblock + writable mount).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_p9wstat_ext4] PASS  (kernel prints [WSTAT_APPLY] PASS)
# Fail marker:  [test_p9wstat_ext4] FAIL

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

DISK=$(mktemp --suffix=.wstatap.img)
LOG=${HAMNIX_WSTAT_APPLY_LOG:-$(mktemp)}
trap 'rm -f "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_p9wstat_ext4] (1/4) Mint a 1 KiB-block ext4 scratch image"
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_WSTATAP" -O '^has_journal' "$DISK" >/dev/null

echo "[test_p9wstat_ext4] (2/4) Build userland + plant /etc/wstat-apply-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_WSTAT_APPLY_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_p9wstat_ext4] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_p9wstat_ext4] (4/4) Boot QEMU with the ext4 scratch image"
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

echo "[test_p9wstat_ext4] --- wstat apply self-test output ---"
grep -a -E "\[WSTAT_APPLY\]" "$LOG" || true
echo "[test_p9wstat_ext4] --- end ---"

fail=0

if grep -a -F -q "[WSTAT_APPLY] FAIL" "$LOG"; then
    echo "[test_p9wstat_ext4] FAIL: kernel self-test reported a failure" >&2
    grep -a -F "[WSTAT_APPLY] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[WSTAT_APPLY] PASS" "$LOG"; then
    echo "[test_p9wstat_ext4] MISS: self-test PASS banner (expected '[WSTAT_APPLY] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_p9wstat_ext4] --- full log ---"
    cat "$LOG"
    echo "[test_p9wstat_ext4] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_p9wstat_ext4] PASS — wstat honours chmod (mode) + truncate" \
     "(length) on ext4 (qemu rc=$rc)"
