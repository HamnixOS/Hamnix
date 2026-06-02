#!/usr/bin/env bash
# scripts/test_fstat_backend.sh — per-backend fstat metadata verification.
#
# Proves do_fstat (sys/src/9/port/sysfile.ad) now returns REAL metadata
# (size + a stable qid) for the tmpfs and ext4 fd backends instead of the
# old "fstat: backend not supported". The in-kernel fstat_backend_selftest()
# (gated on the cpio marker /etc/fstat-backend-test) writes a known-length
# file on tmpfs and on the live ext4 mount, fstat's each fd, and asserts the
# Dir-record length[8] field matches the bytes written. The selftest itself
# does all the work, so the host only attaches a plain, empty ext4 scratch
# disk on virtio (so the ext4 leg has a real filesystem to create into).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_fstat_backend] PASS   (kernel prints [FSTAT_BACKEND] PASS)
# Fail marker:  [test_fstat_backend] FAIL

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

DISK=$(mktemp --suffix=.fstatbk.img)
LOG=${HAMNIX_FSTAT_LOG:-$(mktemp)}
trap 'rm -f "$DISK"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_fstat_backend] (1/4) Mint a 1 KiB-block ext4 scratch image"
truncate -s 64M "$DISK"
"$MKFS" -F -q -b 1024 -t ext4 -L "HAMNIX_FSTAT" -O '^has_journal' "$DISK" >/dev/null

echo "[test_fstat_backend] (2/4) Build userland + plant /etc/fstat-backend-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_FSTAT_BACKEND_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_fstat_backend] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_fstat_backend] (4/4) Boot QEMU with the ext4 scratch image"
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

echo "[test_fstat_backend] --- fstat-backend self-test output ---"
grep -a -E "\[FSTAT_BACKEND\]" "$LOG" || true
echo "[test_fstat_backend] --- end ---"

fail=0

if grep -a -F -q "[FSTAT_BACKEND] FAIL" "$LOG"; then
    echo "[test_fstat_backend] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[FSTAT_BACKEND] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[FSTAT_BACKEND] PASS" "$LOG"; then
    echo "[test_fstat_backend] MISS: self-test PASS banner (expected '[FSTAT_BACKEND] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_fstat_backend] --- full log ---"
    cat "$LOG"
    echo "[test_fstat_backend] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_fstat_backend] PASS — do_fstat returns real size/qid metadata for" \
     "tmpfs + ext4 fd backends (qemu rc=$rc)"
