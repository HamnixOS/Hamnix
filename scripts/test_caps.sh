#!/usr/bin/env bash
# scripts/test_caps.sh — capget(2)/capset(2) round-trip verification.
#
# Proves the Linux-ABI capability syscalls (linux_abi/u_caps.ad ucaps_capget /
# ucaps_capset, dispatched from linux_abi/u_syscalls.ad at nr 125/126) are
# backed by a REAL per-task capability-set store (ucaps_effective /
# ucaps_permitted / ucaps_inheritable, keyed by task slot, lazily defaulting an
# unseen task to the full root-like set) instead of returning ENOSYS. The
# in-kernel caps_selftest() (gated on the cpio marker /etc/caps-test) runs the
# four libcap-shaped checks:
#   (1) version-probe capget (data==NULL) -> header.version becomes 0x20080522
#   (2) capget(self) reports the seeded full effective/permitted sets
#   (3) capset(self) DROPping CAP_NET_RAW, then capget asserts it persisted
#   (4) capset trying to ADD a permitted bit back returns EPERM (-1)
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_caps] PASS   (kernel prints [CAPS] PASS)
# Fail marker:  [test_caps] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_CAPS_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_caps] (1/3) Build userland + plant /etc/caps-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_CAPS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_caps] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_caps] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_caps] --- caps self-test output ---"
grep -a -E "\[CAPS\]" "$LOG" || true
echo "[test_caps] --- end ---"

fail=0

if grep -a -F -q "[CAPS] FAIL" "$LOG"; then
    echo "[test_caps] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[CAPS] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[CAPS] PASS" "$LOG"; then
    echo "[test_caps] MISS: self-test PASS banner (expected '[CAPS] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_caps] --- full log ---"
    cat "$LOG"
    echo "[test_caps] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_caps] PASS — capget/capset round-trip through the per-task cap store" \
     "(qemu rc=$rc)"
