#!/usr/bin/env bash
# scripts/test_opt_liverange.sh — host-only correctness + STRUCTURAL guard for the
# native optimizer's LIVE-RANGE-HOLE (idle-gap) analysis (cfg.ad, the keystone for
# live-range splitting toward gcc-parity codegen).
#
# WHAT THE ANALYSIS IS
#   The single-interval liveness model ([lr_start,lr_end)) says a value occupies
#   its register CONTINUOUSLY from first to last access — over-stating occupancy.
#   A value can be LIVE across a stretch (its value is carried, needed later) yet
#   never ACCESSED there: its register sits idle. matmul's checksum accumulator
#   `acc` (written at the reps-loop top, read in the later p-loop) is idle across
#   the entire 39M-iteration k-loop, pinning %r15 uselessly. lr_build_holes()
#   computes, per promotable name, the maximal ACCESS-FREE runs INTERIOR to its
#   interval (idle-gaps / "live-range holes"), annotated with loop-nesting hotness;
#   a gap hotter than the value's own accesses is a live-range SPLIT CANDIDATE.
#   PURE ANALYSIS — it changes NO allocation today (codegen stays byte-identical);
#   it is the foundation a future codegen splitter + base-hoist pass consumes.
#
# WHAT THIS GUARD PROVES (no QEMU; python3 + as/ld + objdump, x86_64):
#   A. FIRES + CORRECT SHAPE — a matmul-shape value that is dead-in-the-inner-loop
#      but live-after IS reported a split candidate, with a gap at the INNER loop's
#      depth (hotter than its own accesses). The real matmul kernel's `acc`/`reps`
#      are both candidates with a depth-4 gap (the k-loop).
#   B. SAFETY — a value ACCESSED inside the inner loop is NOT a split candidate
#      (splitting a still-accessed value would be a miscompile; the analysis must
#      never flag it). This is the "a LIVE-in-loop value must NOT split" invariant.
#   C. STRUCTURAL SOUNDNESS — over nested-loop + call-crossing shapes the hole
#      validator (lr_validate_holes: gaps interior, disjoint, ascending, and
#      ACCESS-FREE) passes (cfgok).
#   D. DELIBERATE BREAK — arming --holes-break (corrupt a gap to swallow its
#      right-bracket access) is CAUGHT by the validator (cfgfail code=17).
#   E. VALUE CORRECTNESS — every shape compiles+runs through codegen.ad with the
#      optimizer ON and OFF and matches the Python oracle (the analysis, being
#      pure, must not perturb output).
#
# HOST-ONLY. NO QEMU.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_liverange"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = Path("tests/bench/opt/_prelude.ad").read_text()
U64 = (1 << 64) - 1
fails = 0

def fail(msg):
    global fails
    fails += 1
    print(f"  FAIL: {msg}")

def build(name, kernel):
    src = WD / f"{name}.ad"
    src.write_text(PRELUDE + "\n" + kernel)
    return src

def check_correct(name, src, expected):
    """opt ON and OFF both == expected (analysis is pure, must not perturb)."""
    ok = True
    for opt in (False, True):
        r = h.run_through_codegen_ad(name + ("_on" if opt else "_off"),
                                     (WD / f"{name}.ad").read_text(), WD, opt=opt)
        if r.kind != "ok":
            fail(f"{name}: codegen.ad kind={r.kind} opt={opt} ({r.detail[:120]})")
            ok = False; continue
        got = r.stdout.strip()
        if got != str(expected):
            fail(f"{name}: opt={opt} stdout={got!r} expected={expected}")
            ok = False
    if ok:
        print(f"  OK  correctness {name} == {expected} (opt ON+OFF)")
    return ok

# ---------------------------------------------------------------------------
# Shape 1: matmul-shape dead-in-inner-loop-but-live-after.
#   `acc` and `r` are written/read only OUTSIDE the k-loop -> idle across it ->
#   SPLIT CANDIDATES. `s` is accessed INSIDE the k-loop -> NOT a candidate.
# ---------------------------------------------------------------------------
GINIT = """G: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 64:
        G[cast[int64](i)] = i * 3
        i = i + 1
"""
SHAPE1 = GINIT + """    acc: int64 = 0
    r: int64 = 0
    while r < 20:
        s: int64 = 0
        k: int64 = 0
        while k < 64:
            s = s + G[cast[int64](k)]
            k = k + 1
        acc = acc + s
        r = r + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & 255)
"""
# oracle
G = [i * 3 for i in range(64)]
acc = 0
for _ in range(20):
    s = sum(G)
    acc += s
EXP1 = acc & U64
build("lrh_shape1", SHAPE1)
check_correct("lrh_shape1", None, EXP1)
c1 = h.run_holes_over_body("lrh_shape1", (WD / "lrh_shape1.ad").read_text(), WD)
if "acc" not in c1:
    fail(f"shape1: `acc` not a split candidate (cands={list(c1)})")
elif not any(g[2] >= 2 and g[2] > g[3] for g in c1["acc"]):
    fail(f"shape1: `acc` gaps not hotter than accesses: {c1['acc']}")
else:
    print(f"  OK  shape1 `acc` split candidate, gaps={c1['acc']}")
if "r" not in c1:
    fail(f"shape1: reps-counter `r` not a split candidate (cands={list(c1)})")
else:
    print(f"  OK  shape1 `r` split candidate, gaps={c1['r']}")
if "s" in c1:
    fail(f"shape1: `s` (accessed in k-loop) WRONGLY flagged candidate: {c1['s']}")
else:
    print("  OK  shape1 `s` (k-loop-accessed) correctly NOT a candidate")

# ---------------------------------------------------------------------------
# Shape 2 (SAFETY): the accumulator is ACCESSED inside the inner loop, so it has
# NO idle-gap over that loop and MUST NOT be a split candidate.
# ---------------------------------------------------------------------------
SHAPE2 = GINIT + """    tot: int64 = 0
    r: int64 = 0
    while r < 20:
        k: int64 = 0
        while k < 64:
            tot = tot + G[cast[int64](k)]
            k = k + 1
        r = r + 1
    print_u64(cast[uint64](tot))
    return cast[int32](tot & 255)
"""
tot = 0
for _ in range(20):
    for k in range(64):
        tot += G[k]
EXP2 = tot & U64
build("lrh_shape2", SHAPE2)
check_correct("lrh_shape2", None, EXP2)
c2 = h.run_holes_over_body("lrh_shape2", (WD / "lrh_shape2.ad").read_text(), WD)
if "tot" in c2:
    fail(f"shape2: `tot` accessed IN the inner loop WRONGLY a candidate: {c2['tot']}")
else:
    print("  OK  shape2 `tot` (live-in-loop) correctly NOT a split candidate")

# ---------------------------------------------------------------------------
# Shape 3 (call-crossing + nested): a helper call after the inner loop; acc spans
# a call. Just assert structural soundness + correctness.
# ---------------------------------------------------------------------------
SHAPE3 = """G: Array[64, int64]
def bump(x: int64) -> int64:
    return x + 1
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < 64:
        G[cast[int64](i)] = i * 2
        i = i + 1
    acc: int64 = 0
    r: int64 = 0
    while r < 15:
        s: int64 = 0
        k: int64 = 0
        while k < 64:
            s = s + G[cast[int64](k)]
            k = k + 1
        acc = acc + bump(s)
        r = r + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & 255)
"""
G2 = [i * 2 for i in range(64)]
acc = 0
for _ in range(15):
    acc += sum(G2) + 1
EXP3 = acc & U64
build("lrh_shape3", SHAPE3)
check_correct("lrh_shape3", None, EXP3)
# structural: the CFG lane (which builds+validates holes) must report cfgok.
r3 = h.run_cfg_over_body("lrh_shape3", (WD / "lrh_shape3.ad").read_text(), WD)
if r3.status != "cfgok":
    fail(f"shape3: CFG/holes validation status={r3.status} ({r3.detail})")
else:
    print(f"  OK  shape3 CFG+holes validate (holes={r3.holes}, "
          f"cands={r3.split_cands}, maxdepth={r3.hole_maxdepth})")

# ---------------------------------------------------------------------------
# D. DELIBERATE BREAK: arm --holes-break so a gap swallows its right-bracket
# access; the hole validator (access-free invariant) MUST catch it -> cfgfail 17.
# ---------------------------------------------------------------------------
rb = h.run_cfg_over_body("lrh_shape1", (WD / "lrh_shape1.ad").read_text(), WD,
                         holes_break=True)
if rb.status == "cfgfail" and "code=17" in rb.detail:
    print(f"  OK  deliberate break CAUGHT: {rb.detail}")
else:
    fail(f"deliberate break NOT caught: status={rb.status} detail={rb.detail!r}")

# ---------------------------------------------------------------------------
# A(real): the ACTUAL matmul bench kernel — `acc` and `reps` are split candidates
# with a depth-4 gap (the k-loop), exactly the register-pressure relief a splitter
# would exploit to hoist the &A/&B bases.
# ---------------------------------------------------------------------------
MM = Path("tests/bench/opt/matmul.ad").read_text()
mm_src = WD / "lrh_matmul.ad"
mm_src.write_text(PRELUDE + "\n" + MM)
cmm = h.run_holes(mm_src)
have = set(cmm)
need = {"acc", "reps"}
if not need.issubset(have):
    fail(f"matmul: missing split candidates {need - have} (have {have})")
else:
    maxd = max(g[2] for n in need for g in cmm[n])
    if maxd < 4:
        fail(f"matmul: candidate gap max depth {maxd} < 4 (k-loop nesting)")
    else:
        print(f"  OK  matmul acc={cmm['acc']} reps={cmm['reps']} (k-loop depth 4)")

print()
if fails:
    print(f"test_opt_liverange: FAIL ({fails} failure(s))")
    sys.exit(1)
print("test_opt_liverange: PASS")
PY
