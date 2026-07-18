#!/usr/bin/env bash
# scripts/test_vk_hostgpu.sh — host gate for the HOST-GPU bridge.
#
# GPU track: "Vulkan back into work on Linux". Proves our composited vk
# framebuffer renders/round-trips through the dev host's REAL Vulkan
# (NVIDIA / Mesa / lavapipe), complementing the in-VM virtio-gpu path.
#
# FLOW (all QEMU-free, on the dev host):
#   1. Compile lib/vk/vk_hostgpu.ad -> a host harness that composites a scene
#      through the native vk 2D layer (lib/vk/vk_2d.ad) into an RGBA8888 vk
#      color image and dumps it as a PPM: the SOFTWARE REFERENCE framebuffer.
#   2. Build the C bridge scripts/vk_hostgpu_bridge.c against system
#      libvulkan.so.1 (no dev headers needed — minimal ABI is hand-declared).
#   3. REAL-GPU UPLOAD round-trip: hand the reference PPM to the bridge, which
#      uploads it to a real VkDevice, runs a real GPU transfer op, and reads it
#      back. Assert the readback is BYTE-IDENTICAL to the SW reference -> our
#      composited framebuffer marshals losslessly through real Linux Vulkan.
#   4. REAL-GPU CLEAR: bridge runs vkCmdClearColorImage on the GPU; assert the
#      corner pixel equals the requested color -> real GPU command execution.
#   5. If lavapipe (SW Vulkan ICD) is present, repeat the round-trip forced onto
#      it (VK_ICD_FILENAMES) -> validates the marshalling path with zero HW dep.
#
# If NO libvulkan is present, steps 3-5 are SKIPPED (reported INCONCLUSIVE) but
# the SW-reference render still asserts, so the gate never false-greens.
#
# Pass marker:  [test_vk_hostgpu] PASS   Fail marker:  [test_vk_hostgpu] FAIL

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
mkdir -p "$OUT"
fail=0
REF_PPM="$OUT/vk_hostgpu_ref.ppm"
REF_BIN="$OUT/vk_hostgpu_ref"
BRIDGE="$OUT/vk_hostgpu_bridge"
LIBVK="/usr/lib/x86_64-linux-gnu/libvulkan.so.1"

# ---- 1. SW reference render ------------------------------------------------
echo "[test_vk_hostgpu] (1/5) compiling Adder reference compositor ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        lib/vk/vk_hostgpu.ad -o "$REF_BIN" 2>"$OUT/vk_hostgpu_compile.log"; then
    echo "[test_vk_hostgpu] FAIL: reference harness did not compile"
    cat "$OUT/vk_hostgpu_compile.log"; exit 1
fi
DUMP="$OUT/vk_hostgpu_ref.txt"
if ! "$REF_BIN" "$REF_PPM" >"$DUMP" 2>&1; then
    echo "[test_vk_hostgpu] FAIL: reference harness exited non-zero"; cat "$DUMP"; exit 1
fi
echo "[test_vk_hostgpu] PASS reference framebuffer rendered -> $REF_PPM"
echo "[test_vk_hostgpu] --- reference sampled pixels ---"; cat "$DUMP"; echo "[test_vk_hostgpu] ---"

ref_pix() { awk -v k="$1" '$0 ~ ("^" k " ") {print $NF}' "$DUMP"; }

assert_ref() {
    local label="$1" line="$2" want="$3" got; got=$(ref_pix "$line")
    if [ "$got" = "$want" ]; then echo "[test_vk_hostgpu] PASS ref $label ($line=$want)"
    else echo "[test_vk_hostgpu] FAIL ref $label ($line: got '$got' want '$want')"; fail=1; fi
}
assert_ref "chrome bar (opaque fill)"   "PIX_BG 2 2"     "#2b3350"
assert_ref "page bg (opaque fill)"      "PIX_PAGE 2 60"  "#0d1220"
assert_ref "content card (opaque)"      "PIX_CARD 12 50" "#ffffff"
assert_ref "alpha panel (blended)"      "PIX_PANEL 30 30" "#7fe5ff"
assert_ref "icon blit (scaled)"         "PIX_ICON 74 20" "#00ff00"
assert_ref "separator line"             "PIX_LINE 40 58" "#ffff00"
assert_ref "rounded button interior"    "PIX_BTN 78 50"  "#ff33cc"

# ---- 2. build the C bridge -------------------------------------------------
if [ ! -e "$LIBVK" ]; then
    echo "[test_vk_hostgpu] SKIP real-GPU arms: $LIBVK not present (no host Vulkan)."
    echo "[test_vk_hostgpu] (SW reference render asserted; real-GPU path INCONCLUSIVE here.)"
    if [ "$fail" -eq 0 ]; then echo "[test_vk_hostgpu] PASS (SW-reference only)"; exit 0; fi
    echo "[test_vk_hostgpu] FAIL"; exit 1
fi

echo "[test_vk_hostgpu] (2/5) building C bridge against libvulkan ..."
if ! gcc -O2 -Wall scripts/vk_hostgpu_bridge.c -o "$BRIDGE" "$LIBVK" \
        2>"$OUT/vk_hostgpu_cc.log"; then
    echo "[test_vk_hostgpu] FAIL: bridge did not build"; cat "$OUT/vk_hostgpu_cc.log"; exit 1
fi
echo "[test_vk_hostgpu] PASS bridge built -> $BRIDGE"

# ---- 3. real-GPU upload round-trip ----------------------------------------
echo "[test_vk_hostgpu] (3/5) real-GPU upload round-trip ..."
GPU_PPM="$OUT/vk_hostgpu_gpu.ppm"
if "$BRIDGE" upload "$REF_PPM" "$GPU_PPM" >"$OUT/vk_hostgpu_gpu.log" 2>&1; then
    DEV=$(awk '/^VK_DEVICE/{sub(/^VK_DEVICE /,""); print; exit}' "$OUT/vk_hostgpu_gpu.log")
    echo "[test_vk_hostgpu] real GPU device: ${DEV:-unknown}"
    if cmp -s "$REF_PPM" "$GPU_PPM"; then
        echo "[test_vk_hostgpu] PASS GPU readback BYTE-IDENTICAL to SW reference"
    else
        echo "[test_vk_hostgpu] FAIL GPU readback differs from SW reference"; fail=1
    fi
else
    echo "[test_vk_hostgpu] FAIL bridge upload op errored"; cat "$OUT/vk_hostgpu_gpu.log"; fail=1
fi

# ---- 4. real-GPU clear -----------------------------------------------------
echo "[test_vk_hostgpu] (4/5) real-GPU vkCmdClearColorImage ..."
CLR_PPM="$OUT/vk_hostgpu_clear.ppm"
if "$BRIDGE" clear 8 8 0x1122ccff "$CLR_PPM" >"$OUT/vk_hostgpu_clear.log" 2>&1; then
    GOT=$(python3 - "$CLR_PPM" <<'PY'
import sys
f=open(sys.argv[1],'rb'); f.readline(); f.readline(); f.readline()
p=f.read(3); print("#%02x%02x%02x"%(p[0],p[1],p[2]))
PY
)
    if [ "$GOT" = "#1122cc" ]; then
        echo "[test_vk_hostgpu] PASS GPU clear corner == #1122cc"
    else
        echo "[test_vk_hostgpu] FAIL GPU clear corner got '$GOT' want '#1122cc'"; fail=1
    fi
else
    echo "[test_vk_hostgpu] FAIL bridge clear op errored"; cat "$OUT/vk_hostgpu_clear.log"; fail=1
fi

# ---- 5. lavapipe (SW Vulkan) validation, if available ----------------------
LVP=/usr/share/vulkan/icd.d/lvp_icd.json
if [ -e "$LVP" ]; then
    echo "[test_vk_hostgpu] (5/5) lavapipe (SW Vulkan) round-trip ..."
    LVP_PPM="$OUT/vk_hostgpu_lvp.ppm"
    if VK_ICD_FILENAMES="$LVP" "$BRIDGE" upload "$REF_PPM" "$LVP_PPM" \
            >"$OUT/vk_hostgpu_lvp.log" 2>&1 && cmp -s "$REF_PPM" "$LVP_PPM"; then
        echo "[test_vk_hostgpu] PASS lavapipe round-trip BYTE-IDENTICAL"
    else
        echo "[test_vk_hostgpu] FAIL lavapipe round-trip"; cat "$OUT/vk_hostgpu_lvp.log"; fail=1
    fi
else
    echo "[test_vk_hostgpu] (5/5) SKIP lavapipe: $LVP not present."
fi

# ---- no leaked bridge processes -------------------------------------------
if pgrep -x vk_hostgpu_bridge >/dev/null 2>&1; then
    echo "[test_vk_hostgpu] FAIL leaked vk_hostgpu_bridge process"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_vk_hostgpu] PASS — vk framebuffer renders + round-trips through real Linux Vulkan"
    exit 0
fi
echo "[test_vk_hostgpu] FAIL"; exit 1
