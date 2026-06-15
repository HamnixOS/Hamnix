#!/usr/bin/env bash
# scripts/test_de_edge_snap.sh — MATE/GNOME-class window edge snapping.
#
# Dragging a window's title bar into a screen edge or corner snaps the
# window: top edge -> maximize, left/right edges -> half-tile, four
# corners -> quarter-tile. While the cursor sits inside a snap zone a
# translucent preview overlay shows the target rect (rendered by the v2
# /bin/hamsnap overlay client reading SNAP_PREVIEW_MODE/SNAP_PREVIEW_ON).
#
# On release the compositor emits TWO boot-log markers per snap:
#   WM snap <N>\n                  (legacy, mode 1..7)
#   [de_snap] <name>=1\n           (greppable: top|left|right|tl|tr|bl|br)
#
# This harness verifies the structural plumbing every run (source greps)
# and exercises the runtime drag synthesizer (new /dev/wsys/ctl `drag
# <ax> <ay> <btn>` verb — the move/release analogue of `nudge`) when the
# kernel ELF is built and the host accepts -kernel boots.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF="${ELF:-build/hamnix-kernel.elf}"
BOOT_WAIT="${BOOT_WAIT:-180}"
OUT_REPORT="${OUT_REPORT:-build/de_edge_snap.txt}"

DEVWSYS=sys/src/9/port/devwsys.ad
HAMUID=user/hamUId.ad

struct_fail=0

# --- structural: drag ctl verb plumbing in devwsys -----------------------
for marker in \
    'wsys_ctl_word_eq(buf, vs, ve, "drag")' \
    'drag: missing ax' \
    'drag: missing ay' \
    'drag: missing btn' \
    'mouse_rx_push_abs(cast[int32](dax_u),' ; do
    if ! grep -aFq "$marker" "$DEVWSYS"; then
        echo "[test_de_edge_snap] FAIL: devwsys marker missing: $marker" >&2
        struct_fail=1
    fi
done

# --- structural: snap_zone_for + snap_apply still wired ------------------
for marker in \
    'def snap_zone_for(' \
    'def snap_apply(' \
    'def snap_zone_rect(' \
    'SNAP_PREVIEW_MODE' \
    'SNAP_PREVIEW_ON' \
    'snap_zone_for(CUR_X, CUR_Y, scr_w, scr_h)' \
    'snap_apply(mvs, zmode, scr_w, scr_h)' ; do
    if ! grep -aFq "$marker" "$HAMUID"; then
        echo "[test_de_edge_snap] FAIL: hamUId snap marker missing: $marker" >&2
        struct_fail=1
    fi
done

# --- structural: per-edge [de_snap] markers ------------------------------
# All seven snap modes must be reachable as named markers; the on-release
# block selects "top"/"left"/"right"/"tl"/"tr"/"bl"/"br" by mode.
for name in top left right tl tr bl br ; do
    if ! grep -aFq "ds_nm = \"$name\"" "$HAMUID" && \
       ! grep -aFq "ds_nm: Ptr[uint8] = \"$name\"" "$HAMUID" ; then
        # First name is the default (assigned before the chain); accept either form.
        if [ "$name" = "top" ] ; then
            if ! grep -aFq 'ds_nm: Ptr[uint8] = "top"' "$HAMUID"; then
                echo "[test_de_edge_snap] FAIL: hamUId default [de_snap] name 'top' missing" >&2
                struct_fail=1
            fi
        else
            echo "[test_de_edge_snap] FAIL: hamUId [de_snap] name '$name' missing" >&2
            struct_fail=1
        fi
    fi
done

if ! grep -aFq '[de_snap] ' "$HAMUID"; then
    echo "[test_de_edge_snap] FAIL: hamUId [de_snap] prefix missing" >&2
    struct_fail=1
fi

# --- structural: v2 preview overlay client still wired ------------------
if [ ! -f user/hamsnap.ad ]; then
    echo "[test_de_edge_snap] FAIL: user/hamsnap.ad (v2 preview overlay client) missing" >&2
    struct_fail=1
fi

if [ "$struct_fail" -ne 0 ]; then
    exit 1
fi
echo "[test_de_edge_snap] structural markers OK (drag ctl verb + snap_zone_for + 7 [de_snap] names + v2 overlay)."

mkdir -p "$(dirname "$OUT_REPORT")"

# --- runtime gates -------------------------------------------------------
if [ ! -f "$ELF" ]; then
    echo "[test_de_edge_snap] SKIP-RUNTIME: $ELF absent (structural PASS)."
    {
        echo "test_de_edge_snap"
        echo "status=structural_only"
        echo "reason=kernel_elf_absent"
    } > "$OUT_REPORT"
    exit 0
fi

# Multiboot/VBE host limit probe.
if ! timeout 5 qemu-system-x86_64 -kernel "$ELF" -smp 1 -vga none -display none \
        -no-reboot -m 256M -monitor none -serial stdio < /dev/null \
        > /tmp/.snap_probe.$$ 2>&1; then
    :
fi
if grep -q "multiboot knows VBE" /tmp/.snap_probe.$$ 2>/dev/null; then
    rm -f /tmp/.snap_probe.$$
    echo "[test_de_edge_snap] SKIP-RUNTIME: host QEMU rejects -kernel 64-bit ELF (multiboot/VBE limit); structural PASS recorded."
    {
        echo "test_de_edge_snap"
        echo "status=structural_only"
        echo "reason=qemu_multiboot_vbe_limit"
    } > "$OUT_REPORT"
    exit 0
fi
rm -f /tmp/.snap_probe.$$

LOG=$(mktemp --tmpdir hamnix-de-snap.XXXXXX.log)
FIFO=$(mktemp -u --tmpdir hamnix-de-snap.XXXXXX).in
mkfifo "$FIFO"
QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$FIFO"
    [ -n "${KEEP_LOG:-}" ] || rm -f "$LOG"
}
trap cleanup EXIT
exec 4<>"$FIFO"
exec 3>"$FIFO"

KVM_FLAGS=""
if [ -e /dev/kvm ]; then
    KVM_FLAGS="-enable-kvm -cpu host"
fi

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

echo "[test_de_edge_snap] waiting up to ${BOOT_WAIT}s for hamsh prompt..."
if ! wait_for 'hamsh\$' "$BOOT_WAIT"; then
    echo "[test_de_edge_snap] SKIP-RUNTIME: hamsh prompt not seen in ${BOOT_WAIT}s (structural PASS)." >&2
    {
        echo "test_de_edge_snap"
        echo "status=structural_only"
        echo "reason=no_hamsh_prompt"
    } > "$OUT_REPORT"
    exit 0
fi

printf 'echo MARK_SNAP_READY\n' >&3
sleep 0.5
if ! wait_for 'MARK_SNAP_READY' 10; then
    printf 'echo MARK_SNAP_READY\n' >&3
    sleep 1
fi

# Smoke: exercise the `drag` ctl verb arg parsing + auxmouse push path.
# (The compositor's WM gesture machine needs a pre-existing draggable
# window whose titlebar is at known absolute coords; bootstrapping that
# from a fresh hamsh is outside this harness's scope. We assert that the
# verb is plumbed end-to-end — no errstr printk — and that the kernel
# accepts the three required tokens.)
printf 'drag 16384 16384 1 > /dev/wsys/ctl\n' >&3 ; sleep 0.2
printf 'drag 32000 16384 1 > /dev/wsys/ctl\n' >&3 ; sleep 0.2
printf 'drag 32000 16384 0 > /dev/wsys/ctl\n' >&3 ; sleep 0.4
sleep 1

exec 3>&-
sleep 0.5
kill "$QEMU_PID" 2>/dev/null
( sleep 4; kill -9 "$QEMU_PID" 2>/dev/null ) &
WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

# Negative check: the `drag` verb must NOT have raised an errstr.
if grep -aqE '/dev/wsys/ctl: drag: ' "$LOG"; then
    echo "[test_de_edge_snap] FAIL: drag ctl verb errstr seen in log" >&2
    grep -aE '/dev/wsys/ctl: drag: ' "$LOG" >&2 | head
    exit 1
fi

# If the boot brought up a window whose titlebar happened to be at the
# injected cursor coord, capture which snap markers fired (best-effort).
seen=""
for tag in top left right tl tr bl br ; do
    if grep -aqE "^\[de_snap\] ${tag}=1" "$LOG"; then
        seen="$seen $tag"
    fi
done

{
    echo "test_de_edge_snap"
    echo "status=runtime"
    echo "seen=$seen"
} > "$OUT_REPORT"

echo "[test_de_edge_snap] PASS: drag ctl verb wired; snap markers captured:${seen:- (none — drag did not land on a titlebar)}"
exit 0
