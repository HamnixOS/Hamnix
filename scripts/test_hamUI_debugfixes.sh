#!/usr/bin/env bash
# scripts/test_hamUI_debugfixes.sh — acceptance gate for the cluster of
# hamUI desktop-environment bug fixes reported by a real user running the
# graphical session:
#
#   P0a — the boot fb-text console and the DE both wrote /dev/fb, so the
#         desktop "ripped open" (console text tore through the composited
#         frame). hamUId now takes EXCLUSIVE framebuffer ownership: on
#         start it writes "suspend" to the new /dev/fbctl control file,
#         which silences the kernel fb-text console + printk; on exit it
#         writes "resume" to restore the boot shell.
#   P0b — keystrokes typed into a DE terminal used to reach the boot shell
#         (both it and hamUId pop the same shared kbd/UART rings). The
#         takeover also GRABS console input (console_input_grab, keyed on
#         pid) so only hamUId drains the physical keyboard while the
#         session is up; each keystroke is routed to the focused window's
#         shell pipe.
#   P1b — the file manager (/bin/hamfm) opens a real browser window rooted
#         at the directory passed as argv[1] (the Places path previously
#         fed a dead "cd <dir>" to a shell that hamfm is not).
#   P2a — the "Welcome to Hamnix" banner dismisses on a WALL-CLOCK deadline
#         (sys_get_jiffies), so it expires after a few seconds regardless
#         of the (now dirty-rect, cadence-variable) present rate.
#   P2b — the right-edge panel applet chain (pager / window-selector /
#         status-notifier / notification stub / show-desktop / clock) tiles
#         WITHOUT overlap; the green/blue status bars near the clock no
#         longer draw on top of each other.
#
# All proofs are DETERMINISTIC serial markers driven through the daemon's
# own *selftest sub-commands (no QEMU mouse/key injection):
#   - hamUId daemon traylayoutselftest -> "[DETRAY] ..." / "[DETRAY] PASS"
#       asserts the applet-chain + per-cell layout has no overlap (P2b).
#   - hamUId daemon debugfixselftest   -> "[DEBUG] ..." / "[DEBUG] PASS"
#       asserts the banner wall-clock dismissal (P2a) and that /bin/hamfm
#       opens a real window and signals HAMFM_READY (P1b).
#   - hamUId daemon terminalselftest   -> "TERM IO ... PASS"
#       asserts a keystroke written to a window's stdin pipe lands in THAT
#       window's terminal grid (the focused-window keystroke routing that
#       P0b's input grab protects from the boot shell).
#   - the "DAEMON console takeover OK (fb-text suspended)" marker proves
#       P0a's exclusive framebuffer ownership engaged on daemon start.
#
# Like the other -vga std hamUI self-tests this SKIPS CLEANLY (exit 0) when
# the daemon can't bring up a framebuffer under QEMU multiboot/VBE on this
# host; the authoritative GOP render gate is scripts/test_img_uefi_hamui.sh.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hamUI_debugfixes] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamUI_debugfixes] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamUI_debugfixes] (3/4) Rebuild kernel image (fbctl + input-grab plumbing)"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamUI_debugfixes] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi
if [ ! -s build/user/hamfm.elf ]; then
    echo "[test_hamUI_debugfixes] FAIL: build/user/hamfm.elf missing/empty (file manager did not build)"
    exit 1
fi

echo "[test_hamUI_debugfixes] (4/4) Boot QEMU + run the DE bug-fix self-tests"

LOG="$(mktemp)"
FIFO="$(mktemp -u).in"
mkfifo "$FIFO"
trap 'rm -f "$LOG" "$FIFO"' EXIT

# Robust feeder. Two boot realities forced this design:
#   1) Gate on serial markers, never wall-clock — a blind `sleep N` raced
#      boot under -vga std + SMP TCG.
#   2) The freshly-booted shell is not yet draining the serial console when
#      its first prompt prints, so the FIRST command line sent is dropped at
#      the input layer (its characters never even echo). That is why the tray
#      self-test — whichever command goes first — silently vanished. So each
#      self-test is RE-SENT until its own terminal marker appears; the first
#      try priming the console, a later try landing once the shell reads.
wait_for() {  # $1=ERE marker  $2=timeout secs ; returns 0 if seen
    local deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$1" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

send_selftest() {  # $1=shell line  $2=terminal-marker ERE  $3=secs/try  $4=tries
    local t=0
    while [ "$t" -lt "$4" ]; do
        printf '%s\n' "$1" >&3
        wait_for "$2" "$3" && return 0
        t=$(( t + 1 ))
    done
    return 1
}

set +e
qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -vga std \
    -display none \
    -no-reboot \
    -m 256M \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
# Hold the FIFO open for writing so qemu's stdin never sees EOF mid-run.
exec 3>"$FIFO"

if wait_for 'hamsh\$' 90; then
    # P2b tray-layout proof (the command the old feeder silently dropped).
    send_selftest 'echo MARK_TRAY_BEGIN; hamUId daemon traylayoutselftest' '\[DETRAY\] (PASS|FAIL)' 30 3
    # P2a banner + P1b file-manager proof (banner wait ~4s + hamfm launch).
    send_selftest 'echo MARK_DEBUG_BEGIN; hamUId daemon debugfixselftest' '\[DEBUG\] (PASS|FAIL)' 60 2
    # P0b focused-window keystroke routing proof.
    send_selftest 'echo MARK_TERM_BEGIN; hamUId daemon terminalselftest' 'TERM IO (PASS|FAIL)' 60 2
    # DEPERF dirty-rect present scaling proof: a single-window content update
    # presents ONLY that window's rect and the presented area does NOT grow
    # with the open-window count (the user's "slower with each window" bug).
    send_selftest 'echo MARK_DEPERF_BEGIN; hamUId daemon deperfselftest' '\[DEPERF\] (PASS|FAIL)' 60 2
    # DEUSE DE-usability proofs: (1) NO keystroke loss under a slow-frame
    # backlog, (2) the panel context menu box fits its widest label (no clip),
    # (3) pointer-move stays off the full-present path AND per-pixel compositing
    # is window-count bounded (occlusion skip).
    send_selftest 'echo MARK_DEUSE_BEGIN; hamUId daemon deusabilityselftest' '\[DEUSE\] (PASS|FAIL)' 60 2
    # DEAPPS proofs: the icon-grid file manager (enumerate + classify +
    # folder-click navigation + up affordance) and the Kate-like text editor
    # (keystroke buffer edits through the real focused-window key path + a
    # file load/save round-trip).
    send_selftest 'echo MARK_DEAPPS_BEGIN; hamUId daemon deappsselftest' '\[DEAPPS\] (PASS|FAIL)' 60 2
fi

exec 3>&-
sleep 1
kill "$QEMU_PID" 2>/dev/null
( sleep 4; kill -9 "$QEMU_PID" 2>/dev/null ) &
WD=$!
wait "$QEMU_PID" 2>/dev/null
rc=$?
kill "$WD" 2>/dev/null
set -e

# A kernel panic / CPU trap is ALWAYS a hard failure.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_hamUI_debugfixes] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

# SKIP CLEANLY when the hamUId daemon never came up under -vga std on this
# host (QEMU multiboot1 VBE + 64-bit ELF limitation). Authoritative GOP
# gate: scripts/test_img_uefi_hamui.sh.
if ! grep -aq 'DAEMON up screen=' "$LOG"; then
    echo "[test_hamUI_debugfixes] SKIP: hamUId daemon did not come up under -vga std on this host (QEMU multiboot VBE+64-bit limitation). Authoritative GOP gate: scripts/test_img_uefi_hamui.sh." >&2
    exit 0
fi

echo "[test_hamUI_debugfixes] --- captured serial markers ---"
grep -aE 'DAEMON up|DAEMON console takeover|DAEMON fbctl absent|\[DETRAY\]|\[DEBUG\]|\[DEPERF\]|\[DEUSE\]|\[DEAPPS\]|TERM IO|HAMFM_READY|MARK_' "$LOG" | head -80
echo "[test_hamUI_debugfixes] --- end ---"

fail=0

assert_marker() {
    if grep -aq "$1" "$LOG"; then
        echo "[test_hamUI_debugfixes] OK: $2"
    else
        echo "[test_hamUI_debugfixes] MISS: $2 (expected marker: '$1')"
        fail=1
    fi
}

# --- P0a: exclusive framebuffer ownership (no console bleed) ---------
# The daemon must report it suspended the boot fb-text console on start.
# (If /dev/fbctl were missing, "DAEMON fbctl absent" would appear instead
# and this assertion fails — the takeover plumbing must be present.)
assert_marker 'DAEMON console takeover OK' 'P0a: DE took exclusive framebuffer ownership (fb-text console suspended — no bleed)'
if grep -aq 'DAEMON fbctl absent' "$LOG"; then
    echo "[test_hamUI_debugfixes] FAIL: P0a /dev/fbctl not present — console takeover never engaged"
    fail=1
fi

# --- P2b: tray / right-edge applet chain has no overlap -------------
assert_marker '\[DETRAY\] chain-no-overlap OK' 'P2b: right-edge applet chain tiles without overlap'
assert_marker '\[DETRAY\] statnot-cells OK'    'P2b: status-notifier indicator cells tile without overlap'
assert_marker '\[DETRAY\] notif-cells OK'      'P2b: notification-stub icon cells tile without overlap'
assert_marker '\[DETRAY\] PASS'                'P2b: tray-layout self-test ran to completion'

# --- P2a + P1b: banner wall-clock dismissal + file manager ----------
assert_marker '\[DEBUG\] banner wall-clock dismissal OK' 'P2a: Welcome banner dismisses on a wall-clock deadline (no presents)'
assert_marker '\[DEBUG\] file-manager window opened'     'P1b: the DE file manager (in-compositor APP_FILEMGR) opened rooted at the requested dir'
assert_marker '\[DEBUG\] PASS'                           'P2a/P1b self-test ran to completion'

# --- P0b: a keystroke lands in the FOCUSED DE window, not elsewhere --
# terminalselftest writes a sentinel to a window's stdin pipe and asserts
# it shows up in THAT window's terminal grid. With the console-input grab
# (P0b) the boot shell can no longer steal these bytes from the daemon.
assert_marker 'TERM IO window0 OK' 'P0b: keystroke written to a window stdin landed in that window grid'
if grep -aq 'TERM IO PASS' "$LOG"; then
    echo "[test_hamUI_debugfixes] OK: P0b: per-window terminal I/O + focus-switch routing PASS"
elif grep -aq 'TERM IO PASS (single-window)' "$LOG"; then
    echo "[test_hamUI_debugfixes] OK: P0b: per-window terminal I/O PASS (single-window variant)"
else
    echo "[test_hamUI_debugfixes] MISS: P0b: terminal I/O self-test did not reach a PASS"
    fail=1
fi

# --- DEPERF: dirty-rect present scales with the changed rect, not -------
# O(screen * windows), and is independent of the open-window count.
assert_marker '\[DEPERF\] single-window content update presents ONLY that window' 'DEPERF: a single-window update presents only that window rect (not the full screen)'
assert_marker '\[DEPERF\] single-window present area is window-count INDEPENDENT OK' 'DEPERF: presented area does NOT grow with the number of open windows'
assert_marker '\[DEPERF\] whole-screen change still escalates to a full present OK' 'DEPERF: a genuine whole-screen change still does a full present'
assert_marker '\[DEPERF\] PASS' 'DEPERF: dirty-rect present scaling self-test ran to completion'

# --- DEUSE: the three user-reported DE-usability fixes -----------------
# BUG 1: no keystrokes are lost even when far more bytes than the old
# 16x256 per-frame cap are queued (slow-frame backlog).
assert_marker '\[DEUSE\] keystroke integrity: NONE dropped under backlog OK' 'DEUSE BUG1: no keystroke loss under a slow-frame backlog'
# BUG 3: the panel context menu box is wide enough for its widest label.
assert_marker '\[DEUSE\] panel context menu box fits its widest label OK' 'DEUSE BUG3: panel context menu box fits its widest label (no clip)'
# BUG 2: pointer-move stays off the full-present path; per-pixel compositing
# is window-count independent (occlusion skip).
assert_marker '\[DEUSE\] hover-only pointer move stays off the full-present path OK' 'DEUSE BUG2a: hover-only pointer move does not force a full present'
assert_marker '\[DEUSE\] per-pixel compositing is window-count INDEPENDENT (occlusion) OK' 'DEUSE BUG2b: per-pixel compositing cost does not grow with window count'
assert_marker '\[DEUSE\] PASS' 'DEUSE: DE-usability self-test ran to completion'

# --- DEAPPS: the two new in-compositor desktop apps --------------------
# The user reported the text-based file manager needs an icon grid and the
# vi editor doesn't work / wants a Kate-like GUI editor. APP_FILEMGR is an
# icon-grid file manager; APP_EDITOR is a GUI text editor. Both are proved
# through the real DE code paths with no framebuffer.
assert_marker '\[DEAPPS\] file manager enumerated /tmp entries=' 'DEAPPS FM: the icon-grid file manager enumerated a directory + classified dir-vs-file cells'
assert_marker '\[DEAPPS\] file manager folder-click navigation /->/etc OK' 'DEAPPS FM: clicking a folder cell navigates into it (model current path changes)'
assert_marker '\[DEAPPS\] file manager up-affordance /etc->/ OK' 'DEAPPS FM: the ".." up affordance returns to the parent directory'
assert_marker '\[DEAPPS\] editor keystrokes (insert/backspace/enter/arrow) buffer+caret OK' 'DEAPPS ED: keystrokes through the focused-window key path edit the buffer + move the caret exactly'
assert_marker '\[DEAPPS\] editor load+save round-trip bytes=' 'DEAPPS ED: load-from-path + save-to-path round-trip (re-read bytes match)'
assert_marker '\[DEAPPS\] PASS' 'DEAPPS: file-manager + text-editor self-test ran to completion'

# Any explicit FAIL marker from a self-test is a hard failure.
if grep -aqE '\[DETRAY\] FAIL|\[DEBUG\] FAIL|TERM IO FAIL|\[DEPERF\] FAIL|\[DEUSE\] FAIL|\[DEAPPS\] FAIL' "$LOG"; then
    echo "[test_hamUI_debugfixes] FAIL: a self-test reported a failure:"
    grep -aE '\[DETRAY\] FAIL|\[DEBUG\] FAIL|TERM IO FAIL|\[DEPERF\] FAIL|\[DEUSE\] FAIL|\[DEAPPS\] FAIL' "$LOG" | head
    fail=1
fi

# The serial markers are the source of truth, not the qemu exit code (the
# feeder tears qemu down with a signal once the last marker lands, so a
# nonzero rc here is expected and ignored).
if [ "$fail" -ne 0 ]; then
    echo "[test_hamUI_debugfixes] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamUI_debugfixes] capture method: drives the real daemon self-tests (traylayout/debugfix/terminal) over serial; deterministic markers, no QEMU mouse/key injection"
echo "[test_hamUI_debugfixes] PASS"
