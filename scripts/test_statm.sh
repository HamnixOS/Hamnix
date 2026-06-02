#!/usr/bin/env bash
# scripts/test_statm.sh — /proc/<pid>/statm verification.
#
# Proves the new Linux-ABI /proc/<pid>/statm file is REAL: its first two
# PAGE-count fields are computed on demand from the VMA iterator
# (mm/vma.ad task_vsize_bytes / task_rss_pages):
#   statm field 1 (size, pages)     = task_vsize_bytes / 4096,
#   statm field 2 (resident, pages) = task_rss_pages.
# The remaining five (shared text lib data dt) render 0, exactly as Linux
# does for lib/dt. The in-kernel statm_selftest() (gated on the cpio
# marker /etc/statm-test) builds a demand-paged anonymous VMA, faults its
# pages in, renders the statm line via the PUBLIC emit_statm, parses the
# first two fields, and asserts they are non-zero and match the on-demand
# VMA helpers. The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_statm] PASS   (kernel prints [STATM] PASS)
# Fail marker:  [test_statm] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_STATM_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_statm] (1/3) Build userland + plant /etc/statm-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_STATM_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_statm] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_statm] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_statm] --- statm self-test output ---"
grep -a -E "\[STATM\]" "$LOG" || true
echo "[test_statm] --- end ---"

fail=0

if grep -a -F -q "[STATM] FAIL" "$LOG"; then
    echo "[test_statm] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[STATM] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[STATM] PASS" "$LOG"; then
    echo "[test_statm] MISS: self-test PASS banner (expected '[STATM] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_statm] --- full log ---"
    cat "$LOG"
    echo "[test_statm] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_statm] PASS — /proc/<pid>/statm size+resident real" \
     "(qemu rc=$rc)"
