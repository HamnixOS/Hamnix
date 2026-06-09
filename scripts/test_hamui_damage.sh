#!/usr/bin/env bash
# scripts/test_hamui_damage.sh — acceptance gate for DEPERF #409: the
# hamUId compositor's PER-WINDOW BACKBUFFER CACHE (and, transitively, the
# damage-clipped present path it rides on).
#
# The compositor is fully procedural: daemon_pixel() re-derives every
# window's surface (border + title + body glyphs/app paint) from model
# state for every pixel it touches. Before this change a window that merely
# MOVED re-rasterised its identical content on every presented pixel. Now
# each window caches its last-rendered surface; a pure move reuses the
# cache verbatim and only a CONTENT change re-renders one window. The
# composited output stays pixel-identical to a full procedural recomposite.
#
# The proof is a DETERMINISTIC serial self-test driven through the daemon's
# own sub-command (no QEMU mouse/key injection):
#   - hamUId daemon decache -> "[DECACHE] ..." OK lines + "[DECACHE] PASS"
#     Every assertion is pure model state run through the SAME functions the
#     live DE uses (window_cache_sync, daemon_pixel, window_render_self,
#     window_content_dirty), with WCACHE_LAST_RERENDERED / _REUSED counting
#     real cache hits/misses and daemon_pixel-vs-window_render_self proving
#     pixel identity — so it runs with NO real framebuffer under -serial.
#
# Like the other -vga std hamUI self-tests this SKIPS CLEANLY (exit 0) when
# the daemon can't bring up a framebuffer under QEMU multiboot/VBE on this
# host; the authoritative GOP render gate is scripts/test_img_uefi_hamui.sh.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_hamui_damage] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamui_damage] (2/4) Build initramfs"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamui_damage] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s build/user/hamUId.elf ]; then
    echo "[test_hamui_damage] FAIL: build/user/hamUId.elf missing/empty"
    exit 1
fi

echo "[test_hamui_damage] (4/4) Boot QEMU + run the per-window backbuffer self-test"

LOG="$(mktemp)"
FIFO="$(mktemp -u).in"
mkfifo "$FIFO"
trap 'rm -f "$LOG" "$FIFO"' EXIT

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
exec 3>"$FIFO"

if wait_for 'hamsh\$' 90; then
    # DECACHE backbuffer-cache proof. RE-SEND until the [DECACHE] marker
    # lands (the freshly-booted shell drops the first serial command line).
    send_selftest 'echo MARK_DECACHE_BEGIN; hamUId daemon decache' '\[DECACHE\] (PASS|FAIL)' 60 3
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
    echo "[test_hamui_damage] FAIL: kernel panic / trap"
    tail -n 60 "$LOG"
    exit 1
fi

# SKIP CLEANLY when the hamUId daemon never came up under -vga std on this
# host (QEMU multiboot1 VBE + 64-bit ELF limitation). Authoritative GOP
# gate: scripts/test_img_uefi_hamui.sh.
if ! grep -aq 'DAEMON up screen=' "$LOG"; then
    echo "[test_hamui_damage] SKIP: hamUId daemon did not come up under -vga std on this host (QEMU multiboot VBE+64-bit limitation). Authoritative GOP gate: scripts/test_img_uefi_hamui.sh." >&2
    exit 0
fi

echo "[test_hamui_damage] --- captured serial markers ---"
grep -aE 'DAEMON up|\[DECACHE\]|MARK_' "$LOG" | head -80
echo "[test_hamui_damage] --- end ---"

fail=0

assert_marker() {
    if grep -aq "$1" "$LOG"; then
        echo "[test_hamui_damage] OK: $2"
    else
        echo "[test_hamui_damage] MISS: $2 (expected marker: '$1')"
        fail=1
    fi
}

# --- 1. a new window renders into its cache ------------------------------
assert_marker '\[DECACHE\] new window rendered into its cache OK' '1: a freshly-spawned window is rendered into its backbuffer on first composite'

# --- 2. a PURE MOVE reuses the cache (0 re-renders) ----------------------
assert_marker '\[DECACHE\] pure move reuses the backbuffer (0 re-renders) OK' '2: relocating a window (X/Y only) re-renders ZERO windows — all served from cache'

# --- 3. the composited pixel is pixel-identical from cache ---------------
assert_marker '\[DECACHE\] composited pixel is identical from cache after move OK' '3: daemon_pixel (cache path) == window_render_self (procedural) at the new offset'

# --- 4. a content change re-renders ONLY the dirtied window --------------
assert_marker '\[DECACHE\] a content change re-renders ONLY that window OK' '4: marking one window content-dirty re-renders exactly that one window'

# --- 5. overlapping windows still stack correctly through the cache ------
assert_marker '\[DECACHE\] overlapping windows still stack correctly through the cache OK' '5: where a front window covers a back one, the cache composite is the FRONT surface'

assert_marker '\[DECACHE\] PASS' 'DECACHE: per-window backbuffer self-test ran to completion'

# Any explicit FAIL marker from the self-test is a hard failure.
if grep -aqE '\[DECACHE\] FAIL' "$LOG"; then
    echo "[test_hamui_damage] FAIL: the self-test reported a failure:"
    grep -aE '\[DECACHE\] FAIL' "$LOG" | head
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamui_damage] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamui_damage] capture method: drives the real 'hamUId daemon decache' self-test over serial; deterministic [DECACHE] markers, no QEMU mouse/key injection"
echo "[test_hamui_damage] PASS"
