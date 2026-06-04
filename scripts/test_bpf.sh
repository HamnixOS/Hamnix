#!/usr/bin/env bash
# scripts/test_bpf.sh — bpf(2) eBPF interpreter + map/prog verification.
#
# Proves the Linux-ABI bpf syscall (linux_abi/u_bpf.ad bpf_syscall, dispatched
# from linux_abi/u_syscalls.ad at nr 321, with the map/prog fds tagged
# FD_BPF_MAP_MARK / FD_BPF_PROG_MARK and freed via the close arm) is a REAL
# in-kernel eBPF implementation — a working bytecode interpreter plus a lite
# verifier backed by real per-program/per-map state — instead of returning
# ENOSYS. The in-kernel bpf_selftest() (gated on the cpio marker /etc/bpf-test)
# runs the bpf-shaped checks:
#   (1) MAP_CREATE a HASH map; UPDATE + LOOKUP a key and assert the value
#       round-trips byte-for-byte; LOOKUP a missing key -> ENOENT; DELETE it
#   (2) MAP_CREATE an ARRAY map; UPDATE + LOOKUP index 3
#   (3) PROG_LOAD a real eBPF program computing r0 = ctx[0]+ctx[1]; TEST_RUN it
#       and assert the exact sum (1337)
#   (4) PROG_LOAD a stack STX/LDX round-trip program; assert the loaded value
#   (5) PROG_LOAD an invalid program (no BPF_EXIT) -> EINVAL
#   (6) PROG_LOAD an invalid program (out-of-range register) -> EINVAL
#   (7) PROG_LOAD an invalid program (out-of-bounds stack store) -> EACCES
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_bpf] PASS   (kernel prints [bpf] PASS)
# Fail marker:  [test_bpf] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_BPF_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_bpf] (1/3) Build userland + plant /etc/bpf-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_BPF_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_bpf] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_bpf] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_bpf] --- bpf self-test output ---"
grep -a -E "\[BPF\]|\[bpf\]" "$LOG" || true
echo "[test_bpf] --- end ---"

fail=0

if grep -a -F -q "[bpf] FAIL" "$LOG"; then
    echo "[test_bpf] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[bpf] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[bpf] PASS" "$LOG"; then
    echo "[test_bpf] MISS: self-test PASS banner (expected '[bpf] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_bpf] --- full log ---"
    cat "$LOG"
    echo "[test_bpf] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_bpf] PASS — bpf(2) eBPF interpreter + maps + verifier over real" \
     "per-program/per-map state (qemu rc=$rc)"
