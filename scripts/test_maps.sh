#!/usr/bin/env bash
# scripts/test_maps.sh — /proc/self/maps open verification (Firefox blocker #2).
#
# Proves a Linux-ABI process CAN open("/proc/self/maps") and read its own
# memory map — the capability glibc's __pthread_getattr_np (main thread) needs
# to learn the main-thread stack bounds (it scans the map for the line whose
# [from,to) contains __libc_stack_end). Without it pthread_getattr_np fails and
# callers that assert on success abort (Firefox: MOZ_RELEASE_ASSERT(!res) in
# pthread_attr_init). Also a general capability (ASan, debuggers, many tools).
#
# The in-kernel maps_open_selftest() (gated on the cpio marker /etc/maps-test)
# builds a demand-paged anonymous VMA, synthesizes a main-thread user-stack
# range on the boot slot, then drives the EXACT userspace open path a Debian
# ELF's SYS_openat takes — vfs_open("/proc/self/maps"), which resolve_path
# rewrites to "#p/self/maps" through the `/proc -> #p` bind, dispatching to
# devproc DEVPROC_KIND_MAPS -> mm/vma.ad vma_maps_render — reads the rendered
# map, and asserts it opened and carries an address-range line AND the [stack]
# line. The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_maps] PASS   (kernel prints [MAPS] PASS)
# Fail marker:  [test_maps] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_MAPS_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_maps] (1/3) Build userland + plant /etc/maps-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_MAPS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_maps] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_maps] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_maps] --- maps self-test output ---"
grep -a -E "\[MAPS\]" "$LOG" || true
echo "[test_maps] --- end ---"

fail=0

if grep -a -F -q "[MAPS] FAIL" "$LOG"; then
    echo "[test_maps] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[MAPS] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[MAPS] PASS" "$LOG"; then
    echo "[test_maps] MISS: self-test PASS banner (expected '[MAPS] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_maps] --- full log ---"
    cat "$LOG"
    echo "[test_maps] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_maps] PASS — /proc/self/maps opens + renders range+[stack]" \
     "(qemu rc=$rc)"
