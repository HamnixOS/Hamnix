#!/usr/bin/env bash
# scripts/bench_vk2d_vecglyph.sh — REAL-SPEEDUP A/B for the SSE2 auto-vectorizer on
# the vk_2d GLYPH coverage-mask blend (vk2d_raster_cov_mask / anti-aliased text):
# a solid opaque ink over the destination through a PER-PIXEL coverage byte:
#     ia = 255 - cov ; out = (chan*cov + dst*ia)/255 per channel, alpha=255.
#
# Builds the SAME program TWICE, both under --opt:
#     A = --opt            (auto-vectorizer ON:  4 px/iter SSE2 glyph blend + tail)
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

WD = Path("build/bench_vk2d_glyph"); WD.mkdir(parents=True, exist_ok=True)

# 256 KiB pixel buffer (65536 px) + a coverage row, glyph-blended REPS times. The
# inner loop is EXACTLY the vk2d_raster_cov_mask per-pixel-coverage shape the glyph
# vectorizer targets. The coverage pattern varies per pixel and the ink colour
# varies per rep (defeats invariant-store elimination); the sampled checksum ties
# the result so neither build can elide the work.
NPIX = 65536
REPS = 3000
src = F.PRELUDE + f"""
g_pix: Array[{NPIX}, uint32]
g_cov: Array[{NPIX}, uint8]

def glyph_row(base: uint64, cbase: uint64, n: int64,
              cr: uint32, cg: uint32, cb: uint32):
    o: uint64 = base
    cp: uint64 = cbase
    xc: int64 = 0
    while xc < n:
        cov: uint32 = cast[uint32](cast[Ptr[uint8]](cp)[0])
        ia: uint32 = 255 - cov
        dr: uint32 = cast[uint32](cast[Ptr[uint8]](o)[0])
        dg: uint32 = cast[uint32](cast[Ptr[uint8]](o + 1)[0])
        db: uint32 = cast[uint32](cast[Ptr[uint8]](o + 2)[0])
        cast[Ptr[uint8]](o)[0] = cast[uint8]((cr * cov + dr * ia) / 255)
        cast[Ptr[uint8]](o + 1)[0] = cast[uint8]((cg * cov + dg * ia) / 255)
        cast[Ptr[uint8]](o + 2)[0] = cast[uint8]((cb * cov + db * ia) / 255)
        cast[Ptr[uint8]](o + 3)[0] = 255
        o = o + 4
        cp = cp + 1
        xc = xc + 1

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    base: uint64 = cast[uint64](&g_pix[0])
    cbase: uint64 = cast[uint64](&g_cov[0])
    i: int64 = 0
    while i < {NPIX}:
        g_pix[i] = cast[uint32](0x20304050)
        g_cov[i] = cast[uint8]((i * 61 + 3) & 255)
        i = i + 1
    k: int64 = 0
    while k < {REPS}:
        cr: uint32 = cast[uint32](1 + (k & 253))
        glyph_row(base, cbase, {NPIX}, cr, cast[uint32](150), cast[uint32](100))
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

elf_vec, r_vec = build("vecglyph_on", no_vec=False)
elf_sca, r_sca = build("vecglyph_off", no_vec=True)
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
