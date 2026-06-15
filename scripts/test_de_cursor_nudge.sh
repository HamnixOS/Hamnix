#!/usr/bin/env bash
# scripts/test_de_cursor_nudge.sh — measure REAL cursor refresh Hz via
# the in-guest `nudge`/`nudge_report` ctl verbs on /dev/wsys/ctl.
#
# Why this exists: the previous DE-perf harnesses (test_de_mouse_refresh.sh,
# test_de_fps.sh, test_de_multi_apps_load.sh) drive cursor motion through
# the QEMU monitor `mouse_move` HMP command. Under UEFI/OVMF + -vga std +
# virtio that command does NOT reach the guest input stack, so the perf
# numbers were noise instead of a cursor-refresh signal.
#
# This harness drives motion FROM INSIDE the guest:
#   1. Boot build/hamnix-kernel.elf via QEMU -kernel multiboot (the fast
#      path; matches test_de_runtime_smoke.sh).
#   2. Wait for the hamsh prompt.
#   3. Type a hamsh loop into the serial shell that bangs N `nudge`
#      writes to /dev/wsys/ctl. Each `nudge` synthesizes one absolute
#      mouse event on the auxmouse ring; the compositor's /dev/mouse
#      reader consumes it and re-presents the cursor.
#   4. Type `echo nudge_report > /dev/wsys/ctl`. The kernel emits one
#      line `[de_perf] cursor_fps=NN consumed=XX` on the serial log,
#      where consumed = events the compositor actually drained from
#      the ring (= real cursor refresh rate over the injection window).
#   5. Grep the serial log for the line and surface the number.
#
# Skips cleanly when /dev/kvm is missing.
#
# Env overrides:
#   ELF                kernel ELF path   (default: build/hamnix-kernel.elf)
#   BOOT_WAIT          hamsh prompt wait s (default: 120)
#   NUDGE_COUNT        synthetic events  (default: 100)
#   NUDGE_GAP_MS       sleep between nudges in ms (default: 20)
#   APPS_TO_OPEN       extra hamterm load (default: 0)
#   OUT_REPORT         summary path      (default: build/de_cursor_nudge.txt)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF="${ELF:-build/hamnix-kernel.elf}"
BOOT_WAIT="${BOOT_WAIT:-120}"
NUDGE_COUNT="${NUDGE_COUNT:-100}"
NUDGE_GAP_MS="${NUDGE_GAP_MS:-20}"
APPS_TO_OPEN="${APPS_TO_OPEN:-0}"
OUT_REPORT="${OUT_REPORT:-build/de_cursor_nudge.txt}"

# --- structural pre-check (always runs, even when no QEMU/boot path) ----
# These greps fail loud if a refactor silently drops the kernel-side
# `nudge` verb / its counter glue. They're the SAME shape every DE v2
# guard uses: "the source carries the load-bearing breadcrumb."
DEVWSYS=sys/src/9/port/devwsys.ad
struct_fail=0
for marker in \
    'wsys_ctl_word_eq(buf, vs, ve, "nudge")' \
    'wsys_ctl_word_eq(buf, vs, ve, "nudge_report")' \
    'mouse_rx_push_abs(' \
    '[de_perf] cursor_fps=%u' \
    'wsys_nudge_ok' ; do
    if ! grep -aFq "$marker" "$DEVWSYS"; then
        echo "[test_de_cursor_nudge] FAIL: structural marker missing: $marker" >&2
        struct_fail=1
    fi
done
if [ "$struct_fail" -ne 0 ]; then
    exit 1
fi
echo "[test_de_cursor_nudge] structural markers OK (nudge ctl verb wired)."

# --- gates --------------------------------------------------------------
if [ ! -f "$ELF" ]; then
    echo "[test_de_cursor_nudge] SKIP: $ELF absent (build via test_de_runtime_smoke or build_user+build_modules+build_initramfs+adder compile init/main.ad)" >&2
    exit 0
fi

# Probe the multiboot/VBE host-QEMU limit (project_qemu_multiboot_vbe_limit):
# QEMU 10.x rejects 64-bit kernel ELFs through -kernel because the stub
# advertises VBE. If we hit that, fall back to STRUCTURAL-only PASS — the
# orchestrator's authoritative UEFI/GOP gate
# (scripts/test_installer_de_runlevel5.sh) covers the live boot path.
if ! timeout 5 qemu-system-x86_64 -kernel "$ELF" -smp 1 -vga none -display none \
        -no-reboot -m 256M -monitor none -serial stdio < /dev/null \
        > /tmp/.nudge_probe.$$ 2>&1; then
    :
fi
if grep -q "multiboot knows VBE" /tmp/.nudge_probe.$$ 2>/dev/null; then
    rm -f /tmp/.nudge_probe.$$
    echo "[test_de_cursor_nudge] SKIP-RUNTIME: host QEMU rejects -kernel 64-bit ELF (multiboot/VBE limit); structural PASS recorded."
    mkdir -p "$(dirname "$OUT_REPORT")"
    {
        echo "test_de_cursor_nudge"
        echo "status=structural_only"
        echo "reason=qemu_multiboot_vbe_limit"
    } > "$OUT_REPORT"
    exit 0
fi
rm -f /tmp/.nudge_probe.$$

LOG=$(mktemp --tmpdir hamnix-de-nudge.XXXXXX.log)
FIFO=$(mktemp -u --tmpdir hamnix-de-nudge.XXXXXX).in
mkfifo "$FIFO"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$FIFO"
    if [ -n "${KEEP_LOG:-}" ]; then
        cp "$LOG" "${KEEP_LOG}" 2>/dev/null || true
    fi
    [ -n "${KEEP_LOG:-}" ] || rm -f "$LOG"
}
trap cleanup EXIT

# Keep FIFO open so QEMU stdin doesn't EOF when we close.
exec 4<>"$FIFO"
exec 3>"$FIFO"

KVM_FLAGS=""
if [ -e /dev/kvm ]; then
    KVM_FLAGS="-enable-kvm -cpu host"
fi

# QEMU multiboot can't load a 64-bit ELF when -vga std requests the VBE
# extension on this host's QEMU 10.x (the standing limit recorded in
# project_qemu_multiboot_vbe_limit). Use -nographic, like the heartbeat
# test does: the nudge metric is event-driven (kernel printk on the
# auxmouse ring consumed count) so it does NOT need a framebuffer.
qemu-system-x86_64 \
    -kernel "$ELF" \
    $KVM_FLAGS \
    -smp 2 \
    -vga none \
    -display none \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

wait_for() {
    local pat="$1" timeout="$2"
    local deadline=$(( SECONDS + timeout ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

echo "[test_de_cursor_nudge] waiting up to ${BOOT_WAIT}s for hamsh prompt..."
if ! wait_for 'hamsh\$' "$BOOT_WAIT"; then
    echo "[test_de_cursor_nudge] FAIL: hamsh prompt not seen in ${BOOT_WAIT}s" >&2
    tail -40 "$LOG" >&2
    exit 1
fi

# Wake the freshly-booted shell (drops first line).
printf 'echo MARK_NUDGE_READY\n' >&3
sleep 0.5
# Re-send if needed to ensure shell is responsive.
if ! wait_for 'MARK_NUDGE_READY' 10; then
    printf 'echo MARK_NUDGE_READY\n' >&3
    sleep 1
fi

# Optional extra load: spawn hamterm windows.
i=0
while [ "$i" -lt "$APPS_TO_OPEN" ]; do
    printf 'hamterm &\n' >&3
    sleep 0.3
    i=$((i + 1))
done
sleep 1

# Reset counters via an initial nudge_report. Capture log offset so we
# only consider lines AFTER the reset.
printf 'echo nudge_report > /dev/wsys/ctl\n' >&3
sleep 0.5
RESET_OFFSET=$(wc -c < "$LOG")

step=$(( 32767 / NUDGE_COUNT ))
if [ "$step" -lt 1 ]; then step=1; fi
GAP_SLEEP=$(awk -v ms="$NUDGE_GAP_MS" 'BEGIN{ printf "%.3f", ms/1000.0 }')

echo "[test_de_cursor_nudge] injecting ${NUDGE_COUNT} nudges (gap=${NUDGE_GAP_MS}ms)..."

INJ_START_NS=$(date +%s%N)

n=0
while [ "$n" -lt "$NUDGE_COUNT" ]; do
    x=$(( n * step ))
    y=$(( (n * step) % 32768 ))
    printf 'echo nudge %d %d > /dev/wsys/ctl\n' "$x" "$y" >&3 2>/dev/null || break
    sleep "$GAP_SLEEP" 2>/dev/null || sleep 0.02
    n=$((n + 1))
done

# Let the last events flush.
sleep 1

# Emit the report.
printf 'echo nudge_report > /dev/wsys/ctl\n' >&3
# Wait for the report to actually appear in the log.
deadline=$(( SECONDS + 10 ))
while [ "$SECONDS" -lt "$deadline" ]; do
    tail -c +$((RESET_OFFSET + 1)) "$LOG" | grep -aqE '^\[de_perf\] dropped=' && break
    sleep 0.5
done

INJ_END_NS=$(date +%s%N)
WALL_WINDOW_S=$(awk -v s="$INJ_START_NS" -v e="$INJ_END_NS" 'BEGIN{ printf "%.3f", (e-s)/1.0e9 }')

exec 3>&-
sleep 0.5
kill "$QEMU_PID" 2>/dev/null
( sleep 4; kill -9 "$QEMU_PID" 2>/dev/null ) &
WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

mkdir -p "$(dirname "$OUT_REPORT")"
TAIL_LOG=$(tail -c +$((RESET_OFFSET + 1)) "$LOG")

REPORT_LINE_A=$(printf '%s\n' "$TAIL_LOG" | grep -aE '^\[de_perf\] cursor_fps=' | tail -1 || true)
REPORT_LINE_B=$(printf '%s\n' "$TAIL_LOG" | grep -aE '^\[de_perf\] dropped=' | tail -1 || true)

if [ -z "$REPORT_LINE_A" ]; then
    echo "[test_de_cursor_nudge] FAIL: no '[de_perf] cursor_fps=' line found" >&2
    echo "--- tail of serial log ---" >&2
    tail -60 "$LOG" >&2
    exit 1
fi

CURSOR_FPS=$(printf '%s' "$REPORT_LINE_A" | sed -nE 's/.*cursor_fps=([0-9]+).*/\1/p')
CONSUMED=$(printf '%s' "$REPORT_LINE_A" | sed -nE 's/.*consumed=([0-9]+).*/\1/p')
DROPPED=$(printf '%s' "$REPORT_LINE_B" | sed -nE 's/.*dropped=([0-9]+).*/\1/p')
WINDOW_MS=$(printf '%s' "$REPORT_LINE_B" | sed -nE 's/.*window_ms=([0-9]+).*/\1/p')

CURSOR_FPS=${CURSOR_FPS:-0}
CONSUMED=${CONSUMED:-0}
DROPPED=${DROPPED:-0}
WINDOW_MS=${WINDOW_MS:-0}

{
    echo "test_de_cursor_nudge"
    echo "injected=$NUDGE_COUNT"
    echo "gap_ms=$NUDGE_GAP_MS"
    echo "apps_load=$APPS_TO_OPEN"
    echo "wall_window_s=$WALL_WINDOW_S"
    echo "kernel_window_ms=$WINDOW_MS"
    echo "consumed=$CONSUMED"
    echo "dropped=$DROPPED"
    echo "cursor_fps=$CURSOR_FPS"
    echo "raw_report_a=$REPORT_LINE_A"
    echo "raw_report_b=$REPORT_LINE_B"
} > "$OUT_REPORT"

echo "[test_de_cursor_nudge] cursor_fps=$CURSOR_FPS consumed=$CONSUMED dropped=$DROPPED kernel_window_ms=$WINDOW_MS"
echo "[test_de_cursor_nudge] report: $OUT_REPORT"
echo "[test_de_cursor_nudge] PASS"
exit 0
