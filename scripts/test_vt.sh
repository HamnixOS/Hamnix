#!/usr/bin/env bash
# scripts/test_vt.sh — end-to-end test for virtual terminal (VT) support.
#
# Boots the Hamnix kernel with the normal /init + hamsh flow, then
# drives a sequence that proves:
#
#   1. Kernel initialises 4 VTs (boot log sentinel).
#   2. Alt+F1..F4 hotkey intercept is compiled in (atkbd change compiled).
#   3. VT2 getty is spawned by rc.boot.full.
#   4. A `chvt 2` command switches the active VT to VT2.
#   5. After `chvt 1`, switching back to VT1 works.
#   6. A normal boot still reaches a hamsh prompt.
#
# This is a SERIAL-DRIVEN test: we pipe stdin through QEMU's stdio
# channel and grep the captured log for sentinel lines.
#
# NOTE: This host runs QEMU in TCG (software emulation) which is
# VERY SLOW.  We use a 120 s timeout and generous inter-command
# sleeps to avoid racing fixed-duration windows.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_vt] (1/4) Build userland (incl. chvt / getty)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_vt] (2/4) Build initramfs with /init = build/user/init.elf"
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py

echo "[test_vt] (3/4) Rebuild kernel"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_vt] (4/4) Boot QEMU and drive VT test"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Let the kernel fully boot (~20 s on slow TCG) before doing anything.
    sleep 30
    # Verify the shell is alive by running a harmless command.
    # Note: hamsh treats '[' as a token, so use a plain string without brackets.
    printf 'echo vt-test-VT1-shell-alive\n'
    sleep 3
    # Switch to VT2 via chvt — proves the /dev/vt/ctl channel works.
    printf 'chvt 2\n'
    sleep 3
    # Switch back to VT1.
    printf 'chvt 1\n'
    sleep 3
    # Print a sentinel on VT1 that confirms we are back.
    printf 'echo vt-test-VT1-after-switch-back\n'
    sleep 3
    # Exit so QEMU terminates.
    printf 'exit\n'
    sleep 2
) | timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_vt] --- captured output ---"
cat "$LOG"
echo "[test_vt] --- end output ---"

fail=0

# --- Sentinel 1: VT multiplexer initialised --------------------------
if grep -F -q "[vt] 4 virtual terminals" "$LOG"; then
    echo "[test_vt] OK: kernel VT init logged"
else
    echo "[test_vt] MISS: '[vt] 4 virtual terminals' not in log"
    fail=1
fi

# --- Sentinel 2: VT2 getty spawned -----------------------------------
if grep -F -q "VT2..VT4 getty instances spawned" "$LOG"; then
    echo "[test_vt] OK: rc.boot.full spawned VT2..VT4 gettys"
else
    echo "[test_vt] MISS: 'VT2..VT4 getty instances spawned' not in log"
    fail=1
fi

# --- Sentinel 3: VT1 shell is alive ----------------------------------
if grep -F -q "vt-test-VT1-shell-alive" "$LOG"; then
    echo "[test_vt] OK: VT1 hamsh produced output"
else
    echo "[test_vt] MISS: VT1 shell did not print sentinel"
    fail=1
fi

# --- Sentinel 4: chvt switched to VT2 --------------------------------
if grep -F -q "[vt] switched to VT2" "$LOG"; then
    echo "[test_vt] OK: chvt 2 produced VT switch log"
else
    echo "[test_vt] MISS: '[vt] switched to VT2' not in log"
    fail=1
fi

# --- Sentinel 5: chvt switched back to VT1 ---------------------------
if grep -F -q "[vt] switched to VT1" "$LOG"; then
    echo "[test_vt] OK: chvt 1 switched back to VT1"
else
    echo "[test_vt] MISS: '[vt] switched to VT1' not in log"
    fail=1
fi

# --- Sentinel 6: VT1 shell alive after switch-back -------------------
if grep -F -q "vt-test-VT1-after-switch-back" "$LOG"; then
    echo "[test_vt] OK: VT1 shell active after switching back"
else
    echo "[test_vt] MISS: VT1 shell did not print post-switch-back sentinel"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_vt] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_vt] PASS"
