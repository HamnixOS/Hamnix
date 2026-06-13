#!/usr/bin/env bash
# scripts/test_pgrpoom.sh — F10-10 (#457) per-Pgrp oom_score_adj field +
# clone-independence verification.
#
# Proves the per-NAMESPACE OOM-killer bias surface added in #457: every
# Pgrp carries an int64 oom_score_adj DEFAULT (-1000..1000) that every
# task in the namespace inherits as its OOM baseline; the per-task slot
# in g_oom_score_adj[] (#457 F10-8 / earlier oomadj store) layers on as a
# DELTA. The badness heuristic in mm/reclaim.ad computes the effective
# bias as `pgrp_default + task_delta`. The control surface is the
# `oompgrpadj <int>` verb on /proc/<pid>/ctl (devproc.ad), parallel to
# the per-task `oomadj` verb.
#
# In-kernel pgrp_oomadj_selftest() (sys/src/9/port/chan.ad, gated on the
# cpio marker /etc/pgrpoom-test) drives the REAL accessors and the REAL
# pgrp_clone path:
#   * round-trip a safe-range value (250) through set/get
#   * upper clamp at +1000 (set 5000, expect 1000)
#   * lower clamp at -1000 (set -5000, expect -1000)
#   * pgrp_clone INDEPENDENCE: set parent=300, clone, confirm child
#     inherited 300; then set child=-400 and parent=700 in turn and
#     confirm neither mutation perturbs the other.
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_pgrpoom] PASS   (kernel prints [PGRPOOM] PASS)
# Fail marker:  [test_pgrpoom] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_PGRPOOM_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_pgrpoom] (1/3) Build userland + plant /etc/pgrpoom-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_PGRPOOM_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_pgrpoom] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_pgrpoom] (3/3) Boot QEMU (no extra disk needed)"
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

echo "[test_pgrpoom] --- pgrpoom self-test output ---"
grep -a -E "\[PGRPOOM\]" "$LOG" || true
echo "[test_pgrpoom] --- end ---"

fail=0

if grep -a -F -q "[PGRPOOM] FAIL" "$LOG"; then
    echo "[test_pgrpoom] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[PGRPOOM] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[PGRPOOM] PASS" "$LOG"; then
    echo "[test_pgrpoom] MISS: self-test PASS banner (expected '[PGRPOOM] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_pgrpoom] --- full log ---"
    cat "$LOG"
    echo "[test_pgrpoom] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_pgrpoom] PASS — per-Pgrp oom_score_adj clamp + clone-independence verified" \
     "(qemu rc=$rc)"
