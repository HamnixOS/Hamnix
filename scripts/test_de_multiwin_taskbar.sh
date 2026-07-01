#!/usr/bin/env bash
# scripts/test_de_multiwin_taskbar.sh — multi-window panel taskbar.
#
# Regression guard for the user-reported bug: with a terminal, a calculator,
# and a file manager all open at once, the DE panel's window-list taskbar
# showed only ONE of them.
#
# ROOT CAUSE: /dev/wsys/ctl is a SHARED file and `newwindow` returned the
# assigned wid via a single GLOBAL result slot (wsys_last_alloc_wid). When the
# panel launches several apps concurrently, each app's `newwindow` (write) +
# separate open/read of /dev/wsys/ctl interleaves with its siblings'; a peer's
# write clobbered the global, so two apps read the SAME wid and drove ONE
# window. The losers never set `decorate`/`title`, so they never appeared in
# the /dev/wsys/windows enumeration the taskbar parses.
#
# FIX: the assigned wid is delivered via a PER-PID pending table in
# sys/src/9/port/devwsys.ad (_wsys_pending_put / _wsys_pending_take); every
# concurrently-launching app reads back its OWN wid.
#
# This boots the kernel and drives wsys_multitask_taskbar_selftest() (run at
# boot:37.dein, chained off wsys_close_box_selftest). It asserts:
#   * THREE distinct live decorated windows all enumerate in /dev/wsys/windows
#     (the producer emits one line per live app window, not just one);
#   * an interleaved 3-pid newwindow/readback returns each pid its OWN wid.
#
# QA-N4 regression (same chain, wsys_raise_enum_selftest): a LIVE on-screen
# window used to DROP OUT of the panel window-list after a single click. Root
# cause: the pointer-router raise (_wsys_raise) used _wsys_win_top_z() which
# includes the panel/menu CHROME (z>=100), so raising a clicked app window put
# its z >=101 — above the z<100 floor /dev/wsys/windows uses to distinguish
# app windows from chrome — and it silently vanished from the enumerated list
# while staying visible. The self-test drives the REAL router with a content
# click and asserts every live window still enumerates.
#
# Pass markers:  [MULTITASK_BAR] PASS  +  [RAISE_ENUM] PASS
# Fail marker:   [test_de_multiwin_taskbar] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${MULTIWIN_TASKBAR_BOOT_TIMEOUT:-120}"

echo "[test_de_multiwin_taskbar] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_de_multiwin_taskbar] (2/3) Build initramfs + kernel"
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

echo "[test_de_multiwin_taskbar] (3/3) Boot QEMU and run the multi-window taskbar self-test"
set +e
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
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

echo "[test_de_multiwin_taskbar] --- self-test output ---"
grep -a -E "\[MULTITASK_BAR\]|\[TASKBAR_CHURN\]|\[RAISE_ENUM\]|\[boot:37.dein\]" "$LOG" || true
echo "[test_de_multiwin_taskbar] --- end ---"

fail=0

# rc=124 = expected timeout kill (kernel halts without powering off qemu);
# rc=0 = clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_de_multiwin_taskbar] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -a -qF "[MULTITASK_BAR] FAIL" "$LOG"; then
    echo "[test_de_multiwin_taskbar] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[MULTITASK_BAR] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[MULTITASK_BAR] PASS" "$LOG"; then
    echo "[test_de_multiwin_taskbar] FAIL: '[MULTITASK_BAR] PASS' not found in serial log." >&2
    fail=1
fi

# QA-N4: a click must not drop a live window from the enumerated list.
if grep -a -qF "[RAISE_ENUM] FAIL" "$LOG"; then
    echo "[test_de_multiwin_taskbar] FAIL: click-raise dropped a live window from the window-list" >&2
    grep -a -F "[RAISE_ENUM] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[RAISE_ENUM] PASS" "$LOG"; then
    echo "[test_de_multiwin_taskbar] FAIL: '[RAISE_ENUM] PASS' not found in serial log." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_de_multiwin_taskbar] FAIL"
    exit 1
fi

echo "[test_de_multiwin_taskbar] PASS — N concurrent windows each enumerate in /dev/wsys/windows + read back their own wid"
