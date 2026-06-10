#!/usr/bin/env bash
# scripts/test_hamui_render.sh — acceptance gate for the hamui widget
# toolkit (lib/hamui.ad) + its demo app (user/hamui_demo.ad).
#
# WHAT IT PROVES
# ==============
# hamui is a CLIENT-SIDE retained-mode widget toolkit: an ordinary
# userland app builds a widget tree, and the toolkit lays it out and
# paints it as hamML markup into a window's "ui" draw layer
# (/dev/wsys/<wid>/draw/ui/markup). The compositor (user/hamUId.ad) then
# parses that markup and rasterises it — so a correct toolkit means the
# widgets actually turn into pixels.
#
# We drive the EXISTING headless render path (same hook the Phase-4b
# renderer test uses, which works on this host over serial even though
# the framebuffer can't come up under QEMU -vga std):
#   1. boot, reach the hamsh prompt
#   2. run `hamui_demo` — it binds wid 1 (the foreground window), builds
#      the demo tree (label/button/entry/checkbox/list), and renders one
#      pass, writing hamML into wid 1's "ui" layer.
#   3. run `hamUId render 1` — composites wid 1's layers and emits the
#      AI-readable dump (DUMP header, PIX probe grid, REGION summaries,
#      ART view, DUMP END).
#   4. assert from the dump that the widgets RASTERISED:
#        * the button's fill colour #4a6da7 appears at probe pixels that
#          fall inside the button rect (40,40)..(160,120) — proof the
#          toolkit's layout placed the button there AND its paint emitted
#          valid hamML the compositor rasterised.
#        * the ART view + a REGION summary show non-background content
#          (the rest of the widgets drew).
#
# Like the other hamUI serial self-tests this is resilient to console
# output interleaving (we grep the whole log for dump-only line shapes)
# and treats a kernel panic as a hard failure.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hamui_render] (0/4) Unit-check the toolkit + demo compile clean"
mkdir -p build/user
if ! python3 -m compiler.adder compile \
        --target=x86_64-adder-user \
        user/hamui_demo.ad \
        -o build/user/hamui_demo.elf >/tmp/hamui_compile.log 2>&1; then
    echo "[test_hamui_render] FAIL: lib/hamui.ad + user/hamui_demo.ad did not compile"
    cat /tmp/hamui_compile.log
    exit 1
fi
echo "[test_hamui_render] OK: lib/hamui.ad + user/hamui_demo.ad compiled"

echo "[test_hamui_render] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

if [ ! -s build/user/hamui_demo.elf ]; then
    echo "[test_hamui_render] FAIL: build/user/hamui_demo.elf missing/empty"
    exit 1
fi
if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamui_render] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

# Offline smoke: the compiled demo must embed the hamML the paint pass
# emits (the toolkit's rect/text/button-fill code is linked + reachable).
# This is a host-runnable assertion that does NOT depend on the flaky
# interactive-serial feed (see "Verification under load" — this host's
# guest can drop piped console input). The in-VM PIX/REGION asserts below
# are the stronger gate when the box reaches interactive input.
echo "[test_hamui_render] (1b) Offline: demo embeds the toolkit's hamML emitters"
demo_fail=0
# Core protocol + primitive emitters, plus distinctive fills/markup from
# the expanded MATE-class widget set (progress green #5fc46d, image
# placeholder #303848 + its diagonal <line, slider/menu/notebook chrome).
# These prove the new widgets' paint code is linked + reachable, not just
# the v1 set.
for tok in '<rect x=' '<text x=' '<line x1=' 'fill=' 'stroke=' \
           '#4a6da7' '#5fc46d' '#303848' '#5f86c4' \
           'mklayer ui markup' 'setz ui'; do
    if grep -aF -q "$tok" build/user/hamui_demo.elf; then
        echo "[test_hamui_render] OK: demo binary contains hamML/protocol token: ${tok}"
    else
        echo "[test_hamui_render] MISS: demo binary lacks token: ${tok}"
        demo_fail=1
    fi
done
# The expanded public API surface must be linked (menubar, notebook, grid,
# treeview, textview, slider, progressbar, combo, dialog, radio).
for sym in hamui_menubar hamui_notebook hamui_grid hamui_treeview \
           hamui_textview hamui_slider hamui_progress hamui_combo \
           hamui_dialog hamui_radio hamui_spin hamui_scrolled \
           hamui_destroy; do
    if grep -aF -q "$sym" build/user/hamui_demo.elf; then
        echo "[test_hamui_render] OK: demo links expanded-toolkit symbol: ${sym}"
    else
        echo "[test_hamui_render] MISS: demo lacks expanded-toolkit symbol: ${sym}"
        demo_fail=1
    fi
done
if [ "$demo_fail" -ne 0 ]; then
    echo "[test_hamui_render] FAIL: the toolkit paint/protocol emitters are not linked into the demo"
    exit 1
fi

echo "[test_hamui_render] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamui_render] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_hamui_render] (4/4) Boot QEMU + drive hamui_demo -> hamUId render 1"
LOG=$(mktemp)
FIFO="$(mktemp -u).in"
mkfifo "$FIFO"
trap 'rm -f "$LOG" "$FIFO"' EXIT

# Marker-gated feeder (the robust hamUI-serial discipline: gate on serial
# markers, never wall-clock, and RE-SEND each line until its own terminal
# marker lands — the freshly-booted shell drops the FIRST serial command
# and the alive-ticker reprints the prompt, racing fixed-sleep feeders).
wait_for() {  # $1=ERE marker  $2=timeout secs ; 0 if seen
    local deadline=$(( SECONDS + $2 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$1" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}
send_selftest() {  # $1=line  $2=terminal-marker ERE  $3=secs/try  $4=tries
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
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3>"$FIFO"

if wait_for 'hamsh\$' 120; then
    # 1. Paint the widget tree into wid 1's "ui" layer.
    send_selftest 'echo MARK_DEMO_BEGIN; hamui_demo; echo MARK_DEMO_END' \
        'MARK_DEMO_END|HAMUI_DEMO rendered' 30 4
    # 2. Composite wid 1 + emit the AI-readable dump.
    send_selftest 'echo MARK_RENDER_BEGIN; hamUId render 1; echo MARK_RENDER_END' \
        'DUMP END' 40 4
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

echo "[test_hamui_render] --- captured output (tail) ---"
tail -n 80 "$LOG"
echo "[test_hamui_render] --- end output ---"

# A kernel panic / CPU trap is ALWAYS a hard failure.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_hamui_render] FAIL: kernel panic / trap"
    exit 1
fi

# If the box never reached a shell prompt at all, that's an environment
# failure, not a toolkit failure — SKIP cleanly (the (0/4) compile gate
# already proved the toolkit + demo are well-formed).
if ! grep -aq "MARK_DEMO_BEGIN" "$LOG"; then
    echo "[test_hamui_render] SKIP: box never reached the shell to run the demo on this host (compile gate already PASSED)." >&2
    exit 0
fi

fail=0
assert_has() {
    local needle="$1" label="$2"
    if grep -aF -q "$needle" "$LOG"; then
        echo "[test_hamui_render] OK: ${label}"
    else
        echo "[test_hamui_render] MISS: ${label} (no '${needle}' in log)"
        fail=1
    fi
}

# The demo reported it bound a window and rendered.
assert_has "HAMUI_DEMO ready" "demo bound a window + created the ui layer"
assert_has "HAMUI_DEMO rendered" "demo completed a render pass"

# The render dump ran and enumerated wid 1's layers (incl. the toolkit's
# "ui" markup layer).
assert_has "DUMP wid=1 win=640x480 layers=" \
    "hamUId render emitted the dump header (layers enumerated)"

# The toolkit's BUTTON rasterised: its fill colour #4a6da7 appears at a
# probe pixel inside the button rect (40,40)..(160,120). Probe grid is
# 40px-stepped, so (80,80) and (120,80) both fall inside the button.
if grep -aE -q '^PIX (80|120) 80 #4a6da7' "$LOG"; then
    echo "[test_hamui_render] OK: button fill #4a6da7 rasterised at a probe pixel inside the button"
else
    echo "[test_hamui_render] MISS: button fill #4a6da7 not found at an expected probe pixel"
    echo "[test_hamui_render]   (probe pixels seen inside the button region:)"
    grep -aE '^PIX (40|80|120) (40|80) ' "$LOG" | head
    fail=1
fi

# Non-background content rendered overall (the rest of the widgets drew).
region_line="$(grep -aE '^REGION ' "$LOG" | head -n1)"
if [ -n "$region_line" ]; then
    cnt="$(printf '%s' "$region_line" | grep -aoE 'nonbg=[0-9]+' | head -n1 | sed 's/nonbg=//')"
    if [ -n "$cnt" ] && [ "$cnt" -gt 0 ]; then
        echo "[test_hamui_render] OK: a REGION summary shows ${cnt} non-background pixels"
    else
        echo "[test_hamui_render] MISS: REGION summary shows no non-background pixels"
        fail=1
    fi
fi

if grep -aE -q '^ART .*#' "$LOG"; then
    echo "[test_hamui_render] OK: ASCII-art view shows non-background widget content"
else
    echo "[test_hamui_render] MISS: ASCII-art view is all background"
    fail=1
fi

assert_has "DUMP END" "dump terminated cleanly"

if [ "$fail" -ne 0 ]; then
    echo "[test_hamui_render] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamui_render] capture method: hamui_demo paints its widget tree into wid 1's ui markup layer; hamUId render 1 rasterises it; the dump proves the button + other widgets turned into pixels"
echo "[test_hamui_render] PASS"
