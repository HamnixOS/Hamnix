#!/usr/bin/env bash
# scripts/test_oomadj.sh — per-task oom_score_adj store + OOM-killer
# exemption/clamp verification.
#
# Proves the NATIVE per-task OOM-killer bias surface: each task carries an
# oom_score_adj value (-1000..1000, -1000 = never kill) that the OOM badness
# heuristic in mm/reclaim.ad consults. Linux exposes this via the
# /proc/<pid>/oom_score_adj file (read here) and a write — in Hamnix the write
# is the `oomadj <int>` verb on /proc/<pid>/ctl ("everything is a file"). The
# in-kernel oomadj_selftest() (gated on the cpio marker /etc/oomadj-test) drives
# the REAL oom_adj_set/get/is_exempt store: it asserts that -1000 stores and is
# exempt, that an out-of-range 5000 clamps to 1000 and is NOT exempt, then
# restores 0. The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_oomadj] PASS   (kernel prints [OOMADJ] PASS)
# Fail marker:  [test_oomadj] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_OOMADJ_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_oomadj] (1/3) Build userland + plant /etc/oomadj-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_OOMADJ_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_oomadj] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_oomadj] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_oomadj] --- oomadj self-test output ---"
grep -a -E "\[OOMADJ\]" "$LOG" || true
echo "[test_oomadj] --- end ---"

fail=0

if grep -a -F -q "[OOMADJ] FAIL" "$LOG"; then
    echo "[test_oomadj] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[OOMADJ] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[OOMADJ] PASS" "$LOG"; then
    echo "[test_oomadj] MISS: self-test PASS banner (expected '[OOMADJ] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_oomadj] --- full log ---"
    cat "$LOG"
    echo "[test_oomadj] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_oomadj] PASS — per-task oom_score_adj exemption (-1000) + clamp (1000) verified" \
     "(qemu rc=$rc)"
