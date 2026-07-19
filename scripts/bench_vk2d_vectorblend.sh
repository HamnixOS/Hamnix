#!/usr/bin/env bash
# scripts/bench_vk2d_vectorblend.sh — REAL-SPEEDUP A/B for the SSE2 auto-vectorizer
# on a vk_2d-shaped TRANSLUCENT source-over fill (vk2d_raster_fill_rect_alpha's
# a<255 inner loop): out = (chan*a + dst*(255-a))/255 per channel, alpha=255.
#
# Builds the SAME program TWICE, both under --opt:
#     A = --opt            (auto-vectorizer ON:  4 ARGB px/iter SSE2 blend + tail)
#     B = --opt --no-vec   (auto-vectorizer OFF: the scalar per-byte blend loop)
# runs each ELF interleaved several times, and reports the wall-time ratio and a
# checksum that MUST match between the two (bit-exactness under speed). A neutral
# or negative ratio is reported honestly.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import sys, time, subprocess, statistics
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/bench_vk2d_blend"); WD.mkdir(parents=True, exist_ok=True)

# 256 KiB pixel buffer (65536 ARGB words), source-over blended REPS times. The
# inner loop is EXACTLY the vk2d_raster_fill_rect_alpha translucent shape the
# blend vectorizer targets. The source color's alpha varies per rep (defeats any
# invariant-store elimination) and the sampled checksum ties the result so
# neither build can elide the work.
NPIX = 65536
REPS = 3000
src = F.PRELUDE + f"""
g_pix: Array[{NPIX}, uint32]

def blend_words(base: uint64, n: int64, r: uint32, g: uint32, b: uint32, a: uint32):
    ia: uint32 = 255 - a
    rav: uint32 = r * a
    gav: uint32 = g * a
    bav: uint32 = b * a
    o: uint64 = base
    xc: int64 = 0
    while xc < n:
        dr: uint32 = cast[uint32](cast[Ptr[uint8]](o)[0])
        dg: uint32 = cast[uint32](cast[Ptr[uint8]](o + 1)[0])
        db: uint32 = cast[uint32](cast[Ptr[uint8]](o + 2)[0])
        cast[Ptr[uint8]](o)[0] = cast[uint8]((rav + dr * ia) / 255)
        cast[Ptr[uint8]](o + 1)[0] = cast[uint8]((gav + dg * ia) / 255)
        cast[Ptr[uint8]](o + 2)[0] = cast[uint8]((bav + db * ia) / 255)
        cast[Ptr[uint8]](o + 3)[0] = 255
        o = o + 4
        xc = xc + 1

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    base: uint64 = cast[uint64](&g_pix[0])
    i: int64 = 0
    while i < {NPIX}:
        g_pix[i] = cast[uint32](0x20304050)
        i = i + 1
    k: int64 = 0
    while k < {REPS}:
        a: uint32 = cast[uint32](1 + (k & 253))
        blend_words(base, {NPIX}, cast[uint32](200), cast[uint32](150),
                    cast[uint32](100), a)
        k = k + 1
    s: uint64 = 0
    idx: int64 = 0
    while idx < {NPIX}:
        s = s + cast[uint64](g_pix[idx] & 0xFF)
        s = s + cast[uint64]((g_pix[idx] >> 8) & 0xFF) * 3
        s = s + cast[uint64]((g_pix[idx] >> 16) & 0xFF) * 7
        idx = idx + 4096
    print_u64(s)
    return cast[int32](0)
"""

def build(seed, no_vec):
    r = h.run_through_codegen_ad(seed, src, WD, opt=True, no_vec=no_vec, keep=True)
    if r.kind != "ok":
        print(f"BUILD FAIL ({seed}): {r.kind} {r.detail}")
        sys.exit(1)
    return WD / f"ad_{seed}.elf", r

elf_vec, r_vec = build("vecblend_on", no_vec=False)
elf_sca, r_sca = build("vecblend_off", no_vec=True)
print(f"vectorizer fired (VEC): {getattr(r_vec,'vec',0)}   (control --no-vec VEC: {getattr(r_sca,'vec',0)})")

def run_once(elf):
    t0 = time.perf_counter()
    cp = subprocess.run([str(elf)], capture_output=True, text=True)
    t1 = time.perf_counter()
    return t1 - t0, cp.stdout.strip()

run_once(elf_vec); run_once(elf_sca)
tv, ts = [], []
csum_v = csum_s = None
for _ in range(9):
    dt, out = run_once(elf_vec); tv.append(dt); csum_v = out
    dt, out = run_once(elf_sca); ts.append(dt); csum_s = out

mv, ms = min(tv), min(ts)
print(f"checksum vec={csum_v}  scalar={csum_s}  MATCH={csum_v==csum_s}")
print(f"buffer={NPIX*4//1024} KiB x {REPS} blends = {NPIX*REPS/1e6:.0f}M px blended")
print(f"vectorized : min {mv*1e3:7.1f} ms   median {statistics.median(tv)*1e3:7.1f} ms")
print(f"scalar     : min {ms*1e3:7.1f} ms   median {statistics.median(ts)*1e3:7.1f} ms")
ratio = ms / mv if mv > 0 else 0.0
print(f"SPEEDUP (scalar/vector, min-of-9): {ratio:.2f}x")
if csum_v != csum_s:
    print("VERDICT: FAIL — checksums differ (miscompile)"); sys.exit(1)
if getattr(r_vec,'vec',0) < 1:
    print("VERDICT: FAIL — vectorizer did not fire"); sys.exit(1)
if ratio >= 1.15:
    print("VERDICT: REAL SPEEDUP — merge candidate")
elif ratio >= 0.98:
    print("VERDICT: NEUTRAL — correct but not faster here (park)")
else:
    print("VERDICT: REGRESSION — slower (do not merge)")
PY
