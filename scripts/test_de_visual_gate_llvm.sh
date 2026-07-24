#!/usr/bin/env bash
# scripts/test_de_visual_gate_llvm.sh — THE LLVM-KERNEL DE VISUAL REGRESSION GATE.
#
# THIS LOCKS IN THE PROJECT'S #1 RESULT: the whole-kernel LLVM-compiled
# Hamnix kernel (init/main.ad closure -> Adder SSA IR -> textual LLVM IR ->
# clang -> ELF64, linked higher-half via scripts/build_kernel_llvm.sh) boots
# all the way to a RENDERED hamUI desktop — kernel scene compositor owning
# /dev/fb, the panel with a populated Applications menu, and several
# genuinely-windowed scene-DE apps (Files/Editor + the Calendar/Calculator/
# System-Monitor launch-queue trio) each self-serving a wsys window.
#
# It is the LLVM-lane sibling of scripts/test_de_visual_gate.sh (which gates
# the NATIVE kernel under OVMF). Here the kernel is the OPT-IN LLVM build and
# the boot is a BIOS-GRUB multiboot ISO (QEMU's -kernel loader rejects the
# 64-bit higher-half ELF; GRUB's multiboot loader accepts it — same trick as
# scripts/_kernel_iso.sh). A future codegen / LLVM-emitter / arm64-retarget
# change that regresses the DE-under-LLVM render is caught HERE.
#
# WHAT IT ASSERTS (all four must hold for exit 0):
#   (a) [scene_de] kernel scene compositor owns /dev/fb   — the rl5 fb flip
#   (b) [panel] appmenu entries:                          — panel came up with
#                                                           a populated menu
#   (c) >= WINDOW_MAP_MIN distinct                        — real scene-DE app
#       "[devwsys] window <wid> mapped pid=<pid>"           windows allocated
#   (d) a captured framebuffer screenshot that is NOT     — a genuine render,
#       a single flat color                                 not a blank/black fb
#
# INTERACTIVITY (best-effort, reported; gated by REQUIRE_INTERACT=1):
#   After the desktop settles the gate drives the DE's real app-launch path
#   from the host over the serial console — `echo /bin/hamtermscene >
#   /dev/wsys/run/launch`, the SAME queue the Applications menu / panel / a
#   desktop double-click use — and confirms a NEW window-mapped marker (a
#   higher wid than any seen at settle) appears afterward. This is the
#   ctl-file injection path the project prefers over the flaky /dev/mouse
#   route. If no interactive serial shell is reachable it is reported as a
#   documented limitation (the static render + boot-time app auto-launch
#   remains the hard bar) and does NOT fail the gate unless REQUIRE_INTERACT=1.
#
# HEAVINESS / CI: this gate rebuilds the whole Adder userland, the LLVM
# kernel, and boots it under KVM for ~2-3 min. It is therefore an ON-DEMAND
# gate, NOT registered in the sharded bare-metal CI battery (which is KVM-
# less and time-boxed). Run it by hand after any ssa*.ad / ssa_llvm.ad /
# codegen.ad / build_kernel_llvm.sh change:
#
#     bash scripts/test_de_visual_gate_llvm.sh
#
# All artifacts land under build/de_visual_gate_llvm/<timestamp>/.
#
# Env overrides:
#   KLLVM_ELF          prebuilt kernel ELF (default build/kllvm/hamnix_kernel_llvm.elf)
#   LLVM_CLANG_OPT     clang -O level for the kernel .ll->.o step (default -O0;
#                      -O2 also boots to the DE per docs/kernel_llvm_phase5b.md)
#   ACCEL              qemu accelerator     (default kvm; set tcg for a KVM-less
#                      run or to reproduce a TCG-masked/exposed dispatch bug —
#                      TCG is ~10-50x slower so bump BOOT_WAIT/SETTLE_WAIT)
#   MEM                guest RAM             (default 1024M — the documented-good size)
#   BOOT_WAIT          seconds to wait for the scene-DE fb-flip marker (default 240)
#   SETTLE_WAIT        seconds to wait for the DE to finish mapping windows (default 150)
#   WINDOW_MAP_MIN     minimum distinct mapped windows to PASS (default 4)
#   REQUIRE_INTERACT   1 = the interactivity probe MUST prove a new window (default 0)
#   HAMNIX_SKIP_BUILD  1 = require an existing KLLVM_ELF (no rebuild of anything)
#   HAMNIX_KLLVM_REBUILD 1 = force a rebuild of the kernel ELF even if present
#   OUT_DIR            output dir            (default build/de_visual_gate_llvm/<ts>)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KLLVM_ELF="${KLLVM_ELF:-build/kllvm/hamnix_kernel_llvm.elf}"
export LLVM_CLANG_OPT="${LLVM_CLANG_OPT:--O0}"
MEM="${MEM:-1024M}"
BOOT_WAIT="${BOOT_WAIT:-240}"
SETTLE_WAIT="${SETTLE_WAIT:-150}"
WINDOW_MAP_MIN="${WINDOW_MAP_MIN:-4}"
REQUIRE_INTERACT="${REQUIRE_INTERACT:-0}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-build/de_visual_gate_llvm/$TS}"

# Markers.
FB_FLIP_MARKER='\[scene_de\] kernel scene compositor owns /dev/fb'
APPMENU_MARKER='\[panel\] appmenu entries:'
WINMAP_RE='\[devwsys\] window [0-9]+ mapped pid=[0-9]+'
# A late "DE settled" beacon rc.5 always emits (self-test or clean boot).
SETTLE_MARKER='\[visual_gate\] done|\[scene_de\] clean first-boot desktop|hamsh\$'

# --- environment gates -----------------------------------------------
if [ ! -e /dev/kvm ] || [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "[vg-llvm] SKIP: /dev/kvm not usable (KVM required for this gate)" >&2
    exit 0
fi
if ! command -v grub-mkrescue >/dev/null 2>&1; then
    echo "[vg-llvm] SKIP: grub-mkrescue not found (apt install grub-pc-bin grub-common xorriso)" >&2
    exit 0
fi
QEMU_BIN=""
for cand in /usr/bin/qemu-system-x86_64 /usr/local/bin/qemu-system-x86_64; do
    [ -x "$cand" ] && QEMU_BIN="$cand" && break
done
[ -z "$QEMU_BIN" ] && command -v qemu-system-x86_64 >/dev/null 2>&1 && \
    QEMU_BIN="$(command -v qemu-system-x86_64)"
if [ -z "$QEMU_BIN" ]; then
    echo "[vg-llvm] SKIP: qemu-system-x86_64 not found" >&2
    exit 0
fi
MON_DRIVER=""
if command -v socat >/dev/null 2>&1; then MON_DRIVER="socat"
elif command -v nc >/dev/null 2>&1; then MON_DRIVER="nc"
else
    echo "[vg-llvm] SKIP: no socat/nc to drive the QEMU monitor (screendump)" >&2
    exit 0
fi

mkdir -p "$OUT_DIR"
echo "[vg-llvm] output dir: $OUT_DIR"
echo "[vg-llvm] clang opt level: $LLVM_CLANG_OPT ; guest RAM: $MEM"

# --- build pipeline (idempotent; each step skipped when its artifact exists) ---
# The whole-kernel LLVM lane needs, in order:
#   1. build/cutover/host_ac.elf   — the Adder compiler with the LLVM backend
#   2. build/user/*.elf            — the compiled userland (/init + /bin/*),
#                                    which build_initramfs.py embeds into the cpio
#   3. build/initramfs_blob.S      — the cpio blob (built with HAMNIX_DE_SELFTEST=1
#                                    so the DE demo apps auto-launch + the
#                                    [visual_gate] launch-queue trio runs, giving
#                                    the >=4 windows this gate asserts)
#   4. build/kllvm/hamnix_kernel_llvm.elf — the linked higher-half LLVM kernel
build_all() {
    # 1) host_ac.elf (the LLVM-backend Adder compiler)
    # shellcheck source=_adder_cc.sh
    source "$PROJ_ROOT/scripts/_adder_cc.sh"
    if [ ! -x "$PROJ_ROOT/build/cutover/host_ac.elf" ]; then
        echo "[vg-llvm] build 1/4: bootstrapping host_ac.elf (LLVM backend)"
        adder_cc_bootstrap || { echo "[vg-llvm] FAIL: host_ac bootstrap" >&2; return 1; }
    fi
    # 2) userland binaries (/init + /bin/*). Without these the cpio has no
    #    /init and the kernel falls back to the baked user-demo stub (which
    #    NX-faults) instead of booting userspace + the DE.
    if [ ! -f "$PROJ_ROOT/build/user/init.elf" ]; then
        echo "[vg-llvm] build 2/4: compiling the Adder userland (build_user.sh, ~250 progs)"
        bash "$PROJ_ROOT/scripts/build_user.sh" \
            || { echo "[vg-llvm] FAIL: build_user.sh" >&2; return 1; }
    fi
    # 3) initramfs blob WITH the DE self-test fragment (demo apps + launch-queue
    #    trio) so the boot deterministically maps >=4 windows.
    if [ ! -f "$PROJ_ROOT/build/initramfs_blob.S" ] || [ "${HAMNIX_KLLVM_REBUILD:-0}" = "1" ]; then
        echo "[vg-llvm] build 3/4: initramfs blob (HAMNIX_DE_SELFTEST=1)"
        HAMNIX_DE_SELFTEST=1 HAMNIX_BUILD_DIR="$PROJ_ROOT/build" \
            python3 "$PROJ_ROOT/scripts/build_initramfs.py" \
            || { echo "[vg-llvm] FAIL: build_initramfs.py" >&2; return 1; }
    fi
    # 4) the LLVM kernel ELF.
    if [ ! -f "$KLLVM_ELF" ] || [ "${HAMNIX_KLLVM_REBUILD:-0}" = "1" ]; then
        echo "[vg-llvm] build 4/4: LLVM kernel ELF ($LLVM_CLANG_OPT)"
        HAMNIX_INITRAMFS_BLOB="$PROJ_ROOT/build/initramfs_blob.S" \
            bash "$PROJ_ROOT/scripts/build_kernel_llvm.sh" "$KLLVM_ELF" \
            || { echo "[vg-llvm] FAIL: build_kernel_llvm.sh" >&2; return 1; }
    fi
    return 0
}

if [ ! -f "$KLLVM_ELF" ] || [ "${HAMNIX_KLLVM_REBUILD:-0}" = "1" ]; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        echo "[vg-llvm] SKIP: $KLLVM_ELF absent and HAMNIX_SKIP_BUILD=1" >&2
        exit 0
    fi
    build_all || exit 1
fi
if [ ! -f "$KLLVM_ELF" ]; then
    echo "[vg-llvm] FAIL: kernel ELF still absent: $KLLVM_ELF" >&2
    exit 1
fi
echo "[vg-llvm] kernel ELF: $KLLVM_ELF ($(stat -c %s "$KLLVM_ELF") bytes)"

# --- build the BIOS-GRUB multiboot ISO -------------------------------
# QEMU's -kernel loader rejects the ELFCLASS64 higher-half kernel; GRUB's
# multiboot loader accepts it. timeout=0 -> boot immediately (headless).
ISO="$OUT_DIR/hamnix_llvm.iso"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/boot/grub"
cp "$KLLVM_ELF" "$STAGE/boot/hamnix.elf"
cat > "$STAGE/boot/grub/grub.cfg" <<'GRUB_CFG_EOF'
set timeout=0
set default=0
menuentry "Hamnix-LLVM" {
    multiboot /boot/hamnix.elf
    boot
}
GRUB_CFG_EOF
if ! grub-mkrescue -o "$ISO" "$STAGE" >/dev/null 2>&1; then
    echo "[vg-llvm] FAIL: grub-mkrescue failed" >&2
    rm -rf "$STAGE"; exit 1
fi
rm -rf "$STAGE"
echo "[vg-llvm] ISO: $ISO"

# --- boot QEMU: FIFO-backed serial (input+capture) + monitor socket --
LOG="$OUT_DIR/serial.log"; : > "$LOG"
MON="$(mktemp -u --tmpdir hamnix-vg-llvm-mon.XXXXXX)"
FIFO="$(mktemp -u --tmpdir hamnix-vg-llvm.XXXXXX).in"
mkfifo "$FIFO"

QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null || true
    exec 4<&- 2>/dev/null || true
    rm -f "$MON" "$FIFO"
}
trap cleanup EXIT
# Hold the FIFO open both ways so writes to fd 3 reach the guest console and
# QEMU never sees EOF on stdin.
exec 4<>"$FIFO"
exec 3>"$FIFO"

mon_cmd() {
    if [ "$MON_DRIVER" = "socat" ]; then
        printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MON" >/dev/null 2>&1
    else
        printf '%s\n' "$1" | nc -U -q1 "$MON" >/dev/null 2>&1
    fi
}

# Capture one framebuffer screendump PPM, convert to PNG via the repo's
# stdlib-only converter. Returns 0 and echoes the PPM path on success.
snapshot() {
    local label="$1"
    local ppm="$OUT_DIR/$label.ppm"
    local png="$OUT_DIR/$label.png"
    mon_cmd "screendump $ppm" || return 1
    local i=0
    while [ "$i" -lt 40 ]; do
        [ -s "$ppm" ] && break
        sleep 0.1; i=$((i + 1))
    done
    [ -s "$ppm" ] || return 1
    sleep 0.3
    python3 "$PROJ_ROOT/scripts/ppm_to_png.py" "$ppm" "$png" >/dev/null 2>&1 || true
    echo "$ppm"
    return 0
}

# ppm_stats <ppm> -> prints "W H DISTINCT TOPFRAC" where DISTINCT is the number
# of distinct RGB colors (capped) and TOPFRAC is the fraction (percent) of the
# most common color. A blank/flat framebuffer has DISTINCT<=2 and TOPFRAC~100.
ppm_stats() {
    python3 - "$1" <<'PYEOF'
import sys
def load(path):
    d=open(path,'rb').read()
    if not d.startswith(b'P6'): return None
    i=2; t=[]
    while len(t)<3:
        while i<len(d) and d[i:i+1].isspace(): i+=1
        if i<len(d) and d[i:i+1]==b'#':
            while i<len(d) and d[i:i+1]!=b'\n': i+=1
            continue
        s=i
        while i<len(d) and not d[i:i+1].isspace(): i+=1
        t.append(int(d[s:i]))
    i+=1
    w,h,_=t
    return w,h,d[i:i+w*h*3]
r=load(sys.argv[1])
if r is None:
    print("0 0 0 100"); sys.exit(0)
w,h,p=r
from collections import Counter
c=Counter()
n=min(len(p),w*h*3)
# sample every 4th pixel for speed on a 1280x800 frame
step=12
for off in range(0,n-2,step):
    c[(p[off],p[off+1],p[off+2])]+=1
    if len(c)>100000: break
total=sum(c.values()) or 1
top=max(c.values()) if c else total
print(f"{w} {h} {len(c)} {top*100//total}")
PYEOF
}

echo "[vg-llvm] booting LLVM kernel under KVM (-cpu host, -m $MEM)..."
"$QEMU_BIN" \
    -accel kvm -cpu host \
    -m "$MEM" \
    -cdrom "$ISO" -boot d \
    -vga std -display none -no-reboot \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio -nic none \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

wait_marker() {
    local pat="$1" timeout="$2"
    local deadline=$(( SECONDS + timeout ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        grep -aqE "$pat" "$LOG" && return 0
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

count_windows() { grep -aoE "$WINMAP_RE" "$LOG" | sort -u | grep -c 'mapped' || true; }
max_wid() {
    grep -aoE "$WINMAP_RE" "$LOG" \
        | sed -nE 's/.*window ([0-9]+) mapped.*/\1/p' \
        | sort -n | tail -1
}

# --- wait for the scene-DE framebuffer flip --------------------------
echo "[vg-llvm] waiting up to ${BOOT_WAIT}s for the scene-DE fb flip..."
if ! wait_marker "$FB_FLIP_MARKER" "$BOOT_WAIT"; then
    echo "[vg-llvm] FAIL: '[scene_de] kernel scene compositor owns /dev/fb' not seen in ${BOOT_WAIT}s" >&2
    echo "----- last 60 serial lines -----" >&2
    tail -60 "$LOG" >&2
    exit 1
fi
echo "[vg-llvm] scene-DE fb flip reached; waiting up to ${SETTLE_WAIT}s for windows to map..."

# Wait for the DE to settle: either enough windows mapped or the settle beacon.
deadline=$(( SECONDS + SETTLE_WAIT ))
while [ "$SECONDS" -lt "$deadline" ]; do
    wc=$(count_windows); wc=${wc:-0}
    if [ "$wc" -ge "$WINDOW_MAP_MIN" ] && grep -aqE "$SETTLE_MARKER" "$LOG"; then
        break
    fi
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 2
done

# Give any in-flight launch-queue app a moment to finish painting, then snap.
sleep 3
SETTLE_WINDOWS=$(count_windows); SETTLE_WINDOWS=${SETTLE_WINDOWS:-0}
SETTLE_MAXWID=$(max_wid); SETTLE_MAXWID=${SETTLE_MAXWID:-0}
echo "[vg-llvm] windows mapped at settle: $SETTLE_WINDOWS (max wid=$SETTLE_MAXWID)"

DESKTOP_PPM="$(snapshot "10-desktop" || true)"
if [ -n "$DESKTOP_PPM" ] && [ -s "$DESKTOP_PPM" ]; then
    echo "[vg-llvm] captured desktop screenshot: $OUT_DIR/10-desktop.png"
else
    echo "[vg-llvm] WARN: desktop screendump failed" >&2
fi

# --- interactivity probe (host-driven app launch over the serial shell) ---
# The scene-DE Applications menu / panel / desktop double-click all spawn an
# app by bumping /dev/wsys/run/launch, which the live panel drains and spawns;
# the new app self-`newwindow`s (kernel emits a fresh [devwsys] window marker).
# Drive that same path from the host by writing the launch verb to the guest's
# interactive serial console — the project's preferred ctl-file injection over
# the flaky /dev/mouse route. A NEW higher wid after the write proves the DE
# responds to input under the LLVM kernel.
INTERACT_RESULT="not-attempted"
NEW_WINDOWS=0
if kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "[vg-llvm] interactivity: injecting an app launch over the serial console..."
    # Nudge the console and confirm the shell echoes (interactive serial present).
    printf '\n' >&3
    printf 'echo VG_LLVM_SHELL_READY\n' >&3
    shell_live=0
    if wait_marker 'VG_LLVM_SHELL_READY' 15; then shell_live=1; fi
    if [ "$shell_live" -eq 1 ]; then
        # Launch a fresh terminal window via the DE's real launch queue.
        printf 'echo /bin/hamtermscene > /dev/wsys/run/launch\n' >&3
        # Wait for a window with a wid higher than any seen at settle.
        idl=$(( SECONDS + 40 ))
        while [ "$SECONDS" -lt "$idl" ]; do
            nw=$(max_wid); nw=${nw:-0}
            if [ "$nw" -gt "$SETTLE_MAXWID" ]; then break; fi
            kill -0 "$QEMU_PID" 2>/dev/null || break
            sleep 2
        done
        POST_MAXWID=$(max_wid); POST_MAXWID=${POST_MAXWID:-0}
        POST_WINDOWS=$(count_windows); POST_WINDOWS=${POST_WINDOWS:-0}
        NEW_WINDOWS=$(( POST_WINDOWS - SETTLE_WINDOWS ))
        if [ "$POST_MAXWID" -gt "$SETTLE_MAXWID" ]; then
            INTERACT_RESULT="pass (new wid $POST_MAXWID > settle max $SETTLE_MAXWID; +$NEW_WINDOWS windows)"
            snapshot "20-after-launch" >/dev/null 2>&1 || true
        else
            INTERACT_RESULT="no-new-window (max wid stayed $POST_MAXWID)"
        fi
    else
        INTERACT_RESULT="no-interactive-serial-shell (static render + boot auto-launch is the bar)"
    fi
fi
echo "[vg-llvm] interactivity: $INTERACT_RESULT"

# --- tear down QEMU --------------------------------------------------
kill "$QEMU_PID" 2>/dev/null
( sleep 5; kill -9 "$QEMU_PID" 2>/dev/null ) & WD=$!
wait "$QEMU_PID" 2>/dev/null
kill "$WD" 2>/dev/null
QEMU_PID=""

# --- collect evidence ------------------------------------------------
FINAL_WINDOWS=$(count_windows); FINAL_WINDOWS=${FINAL_WINDOWS:-0}
WINMAP_LINES=$(grep -aoE "$WINMAP_RE" "$LOG" | sort -u || true)
APPMENU_LINE=$(grep -aoE "$APPMENU_MARKER[^\"]*" "$LOG" | head -1 || true)
FB_FLIP_LINE=$(grep -aoE "$FB_FLIP_MARKER[^\"]*" "$LOG" | head -1 || true)

STATS=""
if [ -f "$OUT_DIR/10-desktop.ppm" ]; then
    STATS="$(ppm_stats "$OUT_DIR/10-desktop.ppm")"
fi
SW=$(echo "$STATS" | awk '{print $1}'); SW=${SW:-0}
SH=$(echo "$STATS" | awk '{print $2}'); SH=${SH:-0}
SDISTINCT=$(echo "$STATS" | awk '{print $3}'); SDISTINCT=${SDISTINCT:-0}
STOPFRAC=$(echo "$STATS" | awk '{print $4}'); STOPFRAC=${STOPFRAC:-100}

# --- summary ---------------------------------------------------------
SUMMARY="$OUT_DIR/SUMMARY.txt"
{
    echo "test_de_visual_gate_llvm summary ($TS)"
    echo "======================================"
    echo "kernel ELF        = $KLLVM_ELF"
    echo "clang opt         = $LLVM_CLANG_OPT"
    echo "guest RAM         = $MEM"
    echo
    echo "(a) fb flip       = ${FB_FLIP_LINE:-MISSING}"
    echo "(b) appmenu       = ${APPMENU_LINE:-MISSING}"
    echo "(c) windows mapped= $FINAL_WINDOWS (min $WINDOW_MAP_MIN)"
    echo "(d) screenshot    = ${SW}x${SH}, distinct_colors=$SDISTINCT, top_color=${STOPFRAC}%"
    echo "    interactivity = $INTERACT_RESULT"
    echo
    echo "distinct window-mapped markers:"
    printf '%s\n' "$WINMAP_LINES" | sed 's/^/  /'
} > "$SUMMARY"
cat "$SUMMARY"

# --- pass/fail -------------------------------------------------------
fail=0
if [ -z "$FB_FLIP_LINE" ]; then
    echo "[vg-llvm] FAIL (a): scene-DE fb-flip marker missing" >&2; fail=1
fi
if [ -z "$APPMENU_LINE" ]; then
    echo "[vg-llvm] FAIL (b): '[panel] appmenu entries:' marker missing" >&2; fail=1
fi
if [ "$FINAL_WINDOWS" -lt "$WINDOW_MAP_MIN" ]; then
    echo "[vg-llvm] FAIL (c): only $FINAL_WINDOWS distinct windows mapped (< $WINDOW_MAP_MIN)" >&2; fail=1
fi
# (d) non-blank: a real DE render has many distinct colors and the dominant
# color is well under the whole frame. A blank/flat fb is <=2 colors ~100%.
if [ "$SW" -eq 0 ] || [ "$SH" -eq 0 ]; then
    echo "[vg-llvm] FAIL (d): no screenshot captured" >&2; fail=1
elif [ "$SDISTINCT" -lt 8 ] || [ "$STOPFRAC" -ge 99 ]; then
    echo "[vg-llvm] FAIL (d): screenshot looks blank (distinct=$SDISTINCT top=${STOPFRAC}%)" >&2; fail=1
fi
if [ "$REQUIRE_INTERACT" = "1" ]; then
    case "$INTERACT_RESULT" in
        pass*) ;;
        *) echo "[vg-llvm] FAIL: interactivity required but: $INTERACT_RESULT" >&2; fail=1 ;;
    esac
fi

if [ "$fail" -eq 0 ]; then
    echo "[vg-llvm] PASS: LLVM kernel booted to a rendered hamUI desktop — fb-flip OK, appmenu OK, $FINAL_WINDOWS windows mapped, screenshot ${SW}x${SH} non-blank ($SDISTINCT colors). interactivity: $INTERACT_RESULT"
    echo "[vg-llvm] artifacts: $OUT_DIR"
    exit 0
else
    echo "[vg-llvm] FAIL (artifacts: $OUT_DIR)" >&2
    exit 1
fi
