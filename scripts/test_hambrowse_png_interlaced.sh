#!/usr/bin/env bash
# scripts/test_hambrowse_png_interlaced.sh — FAST, QEMU-free gate for Adam7
# INTERLACED PNG decode in the native browser (#98, real-web image fidelity).
#
# Real-web logos are frequently saved as Adam7-interlaced PNGs. debian.org's
# header logo (./Pics/openlogo-50.png) is an 8-bit RGBA interlaced PNG; the old
# lib/png.ad rejected any interlaced image (return -1) so the browser drew the
# broken-image placeholder. lib/png.ad now de-interlaces the 7 Adam7 passes and
# scatters their pixels into the final RGBA image.
#
# This gate renders tests/fixtures/hambrowse_img_interlaced.html, which shows:
#   * a deterministically-regenerated interlaced version of the SAME 48x32
#     quadrant test image the non-interlaced img gate uses — so the decoded
#     pixels must match the known quadrant colours EXACTLY (proves the pass
#     scatter geometry, not just "it decoded");
#   * the REAL checked-in debian.org logo bytes (tests/fixtures/debian_openlogo
#     .png, 50x61 Adam7 RGBA) — asserting it decodes to 50x61 and that its box
#     contains the Debian red swirl (not the grey broken-image placeholder).
#
# Built with the frozen Python seed compiler (no self-host bootstrap).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_gfx"
mkdir -p "$OUT"
fail=0

echo "[hb-il] compiling pixel backend (with PNG decode) ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_host_gfx.ad -o "$BIN" 2>"$OUT/il_compile.log"; then
    echo "[hb-il] FAIL: driver did not compile"; cat "$OUT/il_compile.log"; exit 1
fi
echo "[hb-il] PASS pixel backend compiled -> $BIN"

# Regenerate the interlaced sample deterministically (idempotent, self-contained)
# — SAME quadrant colours as the non-interlaced gate, but written as 7 Adam7
# passes with interlace method 1 in IHDR.
SAMPLE="tests/fixtures/hambrowse_img_interlaced.png"
python3 - "$SAMPLE" <<'PY'
import sys, zlib, struct
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t+d) & 0xffffffff)
w, h = 48, 32
def px(x, y):
    if x < 24 and y < 16:    return (220, 40, 40, 255)   # red   TL
    if x >= 24 and y < 16:   return (40, 200, 60, 255)   # green TR
    if x < 24 and y >= 16:   return (50, 90, 220, 255)   # blue  BL
    return (0, 0, 0, 128)                                # 50% black BR
passes = [(0,0,8,8),(4,0,8,8),(0,4,4,8),(2,0,4,4),(0,2,2,4),(1,0,2,2),(0,1,1,2)]
raw = bytearray()
for (x0, y0, dx, dy) in passes:
    pw = (w - x0 + dx - 1)//dx if w > x0 else 0
    ph = (h - y0 + dy - 1)//dy if h > y0 else 0
    if pw == 0 or ph == 0: continue
    for r in range(ph):
        raw.append(0)                                    # filter: None
        y = y0 + r*dy
        for c in range(pw):
            raw += bytes(px(x0 + c*dx, y))
idat = zlib.compress(bytes(raw), 9)
ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 1)      # interlace method = 1
data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(data)
PY
echo "[hb-il] interlaced sample: $(file -b "$SAMPLE" 2>/dev/null)"
echo "[hb-il] real logo fixture: $(file -b tests/fixtures/debian_openlogo.png 2>/dev/null)"

FIX="tests/fixtures/hambrowse_img_interlaced.html"
DUMP="$OUT/il_dump.txt"
PPM="$OUT/gfx_il.ppm"
PNG="$OUT/gfx_il.png"

echo "[hb-il] rendering $FIX (pass 1: geometry) ..."
if ! "$BIN" "$FIX" "$PPM" 640 >"$DUMP" 2>&1; then
    echo "[hb-il] FAIL: render exited non-zero"; cat "$DUMP"; exit 1
fi

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[hb-il] PASS $msg"
    else
        echo "[hb-il] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# 1. The interlaced sample decodes to its true 48x32 dimensions (rc 0).
assert_grep '^IMGDEC "hambrowse_img_interlaced.png" 0 48 32' \
    "Adam7 interlaced sample decodes to natural 48x32 (rc 0)"
# 2. The REAL debian.org logo bytes decode to 50x61 (rc 0) — no longer -1.
assert_grep '^IMGDEC "debian_openlogo.png" 0 50 61' \
    "real debian.org Adam7 logo decodes to 50x61 (rc 0, was broken-box)"
# 3. Neither <img> is a placeholder slot (-2).
if grep -Eq '^IMGSEG slot -2 ' "$DUMP"; then
    echo "[hb-il] FAIL an interlaced image fell back to a placeholder box"; fail=1
else
    echo "[hb-il] PASS no interlaced image drew the broken placeholder"
fi

# ---- pixel-colour assertions inside the interlaced quadrant box ----
# EXACT-match the known quadrant colours: proves the pass-scatter geometry, not
# merely that inflate produced bytes.
read IMGX IMGTOP < <(awk '/^IMGSEG slot 0 w 48 /{print $9, $11; exit}' "$DUMP")
if [ -z "${IMGX:-}" ] || [ -z "${IMGTOP:-}" ]; then
    echo "[hb-il] FAIL could not read interlaced box geometry"; fail=1
else
    RX=$((IMGX + 12));  RY=$((IMGTOP + 8))
    GX=$((IMGX + 36));  GY=$((IMGTOP + 8))
    BX=$((IMGX + 12));  BY=$((IMGTOP + 24))
    KX=$((IMGX + 36));  KY=$((IMGTOP + 24))
    SDUMP="$OUT/il_samples.txt"
    "$BIN" "$FIX" "$PPM" 640 "$RX" "$RY" "$GX" "$GY" "$BX" "$BY" "$KX" "$KY" \
        >"$SDUMP" 2>&1
    assert_pix() {
        local x="$1" y="$2" col="$3" msg="$4"
        if grep -Eq -- "^PIX $x $y #$col\$" "$SDUMP"; then
            echo "[hb-il] PASS $msg (#$col at $x,$y)"
        else
            local got=$(grep -E "^PIX $x $y " "$SDUMP" | head -1)
            echo "[hb-il] FAIL $msg: expected #$col at $x,$y, got: $got"; fail=1
        fi
    }
    assert_pix "$RX" "$RY" "dc2828" "interlaced red quadrant reconstructs"
    assert_pix "$GX" "$GY" "28c83c" "interlaced green quadrant reconstructs"
    assert_pix "$BX" "$BY" "325adc" "interlaced blue quadrant reconstructs"
    assert_pix "$KX" "$KY" "7f7f7f" "interlaced 50%-alpha black blends to grey"
fi

# ---- the real debian logo box must contain the Debian red swirl, not paper ----
read LOGX LOGTOP < <(awk '/^IMGSEG slot 1 w 50 /{print $9, $11; exit}' "$DUMP")
if [ -z "${LOGX:-}" ] || [ -z "${LOGTOP:-}" ]; then
    echo "[hb-il] FAIL could not read debian logo box geometry"; fail=1
else
    if python3 - "$PPM" "$LOGX" "$LOGTOP" <<'PY'
import sys
ppm, x0, y0 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
f = open(ppm, 'rb')
assert f.readline().strip() == b'P6'
w, h = map(int, f.readline().split()); f.readline()
d = f.read()
def get(x, y):
    o = (y*w + x)*3; return d[o], d[o+1], d[o+2]
reddish = 0
for yy in range(y0, min(y0+61, h)):
    for xx in range(x0, min(x0+50, w)):
        r, g, b = get(xx, yy)
        if r > 120 and g < 120 and b < 130:   # Debian swirl red (~#d70751)
            reddish += 1
print("reddish swirl pixels in logo box:", reddish)
sys.exit(0 if reddish > 20 else 1)
PY
    then
        echo "[hb-il] PASS real debian logo renders its red swirl (not a grey box)"
    else
        echo "[hb-il] FAIL debian logo box lacks the Debian red swirl"; fail=1
    fi
fi

# Render the PPM to a PNG for eyeballing.
if python3 scripts/ppm_to_png.py "$PPM" "$PNG" 2>"$OUT/il_png.log"; then
    echo "[hb-il] PASS rendered $PNG ($(file -b "$PNG" 2>/dev/null))"
else
    echo "[hb-il] FAIL png conversion"; cat "$OUT/il_png.log"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[hb-il] PASS"
else
    echo "[hb-il] FAIL"; exit 1
fi
