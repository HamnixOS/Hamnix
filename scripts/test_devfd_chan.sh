#!/usr/bin/env bash
# scripts/test_devfd_chan.sh — Phase 4c `#d/<N>` DEV_DEVFD inline-chan gate.
#
# Proves the FD_DEVFD_MARK → DEV_DEVFD fold (namespace-purity Phase 4c):
# an `#d/<N>` open lands an FD_CHAN_MARK fd carrying a DEV_DEVFD INLINE
# chan id whose wid byte is the /fd-table index, and every I/O surface
# routes through namec's DEV_DEVFD arms:
#
#   * open `#d/5` / `#d/6` → chan id round-trips the fd number
#     (namec_chan_devfd_num).
#   * write via the /fd/5 pipe write-bind, read via the /fd/6 read-bind
#     — payload carries through (namec _devtab_read/_devtab_write).
#   * vfs_waitfds_probe flips 1 → 0 across the drain — the mandated
#     namec_poll_readable DEV_DEVFD arm. The LEGACY mark would have
#     regressed /fd/N polls to always-ready, so probe-after-drain == 0
#     is the tripwire this gate exists for.
#   * lseek on a dup-style #d fd is rejected (no cursor).
#
# All the work happens in the in-kernel devfdchan_selftest() (devfd.ad),
# gated on the cpio marker /etc/devfdchan-test — NO serial input needed
# (same input-free shape as test_procfd.sh), so the gate is immune to
# the host's QEMU stdin behavior.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO.
#
# Pass marker:  [test_devfd_chan] PASS   (kernel prints [DEVFDCHAN] PASS)
# Fail marker:  [test_devfd_chan] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_DEVFDCHAN_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_devfd_chan] (1/3) Build userland + plant /etc/devfdchan-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_DEVFDCHAN_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_devfd_chan] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devfd_chan] (3/3) Boot QEMU (no extra disk needed)"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_devfd_chan] --- devfdchan self-test output ---"
grep -a -E "\[DEVFDCHAN\]" "$LOG" || true
echo "[test_devfd_chan] --- end ---"

fail=0

if grep -a -F -q "[DEVFDCHAN] FAIL" "$LOG"; then
    echo "[test_devfd_chan] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[DEVFDCHAN] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[DEVFDCHAN] PASS" "$LOG"; then
    echo "[test_devfd_chan] MISS: self-test PASS banner (expected '[DEVFDCHAN] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devfd_chan] --- full log ---"
    cat "$LOG"
    echo "[test_devfd_chan] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devfd_chan] PASS — #d/<N> rides DEV_DEVFD chans" \
     "(qemu rc=$rc)"
