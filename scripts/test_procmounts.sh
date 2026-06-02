#!/usr/bin/env bash
# scripts/test_procmounts.sh — real /proc/mounts (per-namespace mount
# table enumeration).
#
# Boots the kernel once with /etc/procmounts-test planted
# (ENABLE_PROCMOUNTS_TEST=1); init/main.ad at boot:37.pmt calls
# procmounts_selftest() (fs/procfs.ad), which renders /proc/mounts into
# a scratch buffer and asserts:
#   * the root-pinned base filesystem lines are present (ext4 /ext, the
#     procfs /proc line) — no regression vs the old static view
#   * after a runtime mnttab_bind, re-rendering shows the new bind as a
#     6-field /proc/mounts line
#     ("/proc-mounts-test-src /proc-mounts-test-dst none bind,rw 0 0")
#
# This proves render_mounts() enumerates the calling process's REAL
# Plan-9 namespace mount table (via chan.ad's pgrp_render_ns) rather
# than emitting a fixed hardcoded list.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_procmounts] PASS
# Fail marker:  [test_procmounts] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_procmounts] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_procmounts] (2/3) Build kernel with /etc/procmounts-test marker"
INIT_ELF=build/user/init.elf ENABLE_PROCMOUNTS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_procmounts] (3/3) Boot QEMU and run the procmounts self-test"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_procmounts] --- procmounts self-test output ---"
grep -E "\[PROCMOUNTS\]" "$LOG" || true
echo "[test_procmounts] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_procmounts] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[PROCMOUNTS] FAIL" "$LOG"; then
    echo "[test_procmounts] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

if grep -qF "[PROCMOUNTS] PASS" "$LOG"; then
    echo "[test_procmounts] PASS: kernel self-test reported PASS"
else
    echo "[test_procmounts] FAIL: no [PROCMOUNTS] PASS line in serial log" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_procmounts] FAIL"
    exit 1
fi

echo "[test_procmounts] PASS — /proc/mounts enumerates the real per-namespace mount table including a runtime bind"
