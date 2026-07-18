#!/usr/bin/env bash
# scripts/test_opt_leamuladd.sh — focused, host-only correctness test for the
# P1 Phase-5 MULTIPLY-ADD DAG TILE (codegen.ad try_lea_muladd_tile): a
# `x * {2,3,5,9} (+/- imm32)` expression is emitted as a single
# `lea disp(%rax,%rax,scale),%rax` under --opt, instead of the `imul $m ; add $d`
# instruction pair the per-node emitter produces (e.g. collatz's `3*n+1` ->
# `lea 0x1(%rax,%rax,2),%rax`, gcc's exact strength-reduced form).
#
# WHAT IT PROVES (no QEMU):
#   * CORRECTNESS across SIGNEDNESS incl. NEGATIVE x and INT_MIN/large edges: the
#     lea computes x*m+d in full 64-bit two's-complement, sign-agnostic. This
#     compiles each shape with --opt ON (tile active) and OFF (imul+add) and
#     asserts BOTH equal a 64-bit two's-complement Python reference.
#   * The tile is exercised through the gen_expr_ir fallback via the DST-ALIASES-
#     OPERAND form `a = a*m+d` (which the dest-driven sel path defers to
#     gen_expr_ir), AND through the value/return form `x*m+d`.
#   * NON-tile multipliers (6,7) still compute correctly (fallback path intact).
#
# HOST-ONLY: python3 + as/ld/gcc (the fuzz host harness), x86_64. NO QEMU.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_leamuladd"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE

U64 = (1 << 64) - 1
def u64(x): return x & U64
def s64(x):
    x &= U64
    return x - (1 << 64) if x >> 63 else x

# lea-expressible multipliers {2,3,5,9} plus non-tile controls {6,7}.
MULS = [2, 3, 5, 9, 6, 7]
# displacements: 0 and small +/- imm (the SUB form uses -d). Large ones exercise
# the disp32 lea encoding; negatives exercise the SUB path.
DISPS = [0, 1, 7, 255, 1000000, 2147483647]
# x spans negative / positive / edges (INT_MIN, near-limits, powers of two).
XS = [0, 1, 2, 3, 7, 100, -1, -2, -7, -100, 123456789, -123456789,
      (1 << 31), -(1 << 31), (1 << 40), -(1 << 40),
      (1 << 62), -(1 << 62), (1 << 63) - 1, -(1 << 63)]

def litsrc(v):
    return f"(-{-v})" if v < 0 else str(v)

fails = 0
checked = 0

def run_case(src, ref, tag):
    global fails, checked
    r_on = h.run_through_codegen_ad(f"lma_{checked}", src, WD, opt=True)
    r_off = h.run_through_codegen_ad(f"lma_{checked}o", src, WD, opt=False)
    checked += 1
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"FAIL(compile) {tag} on={r_on.kind} off={r_off.kind} "
              f"detail={(r_on.detail or r_off.detail)!r:.200}")
        fails += 1
        return
    got_on = u64(int(r_on.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    if not (got_on == u64(ref) and got_off == u64(ref)):
        print(f"FAIL {tag} ref={u64(ref)} on={got_on} off={got_off}")
        fails += 1

for m in MULS:
    for d in DISPS:
        for x in XS:
            xl = s64(x)
            # (a) ADD value form: `x*m + d`  (routes through the tile at the
            #     ADD root when reached via gen_expr_ir).
            add_ref = u64(xl * m + d)
            srcA = PRELUDE + f"""
def f(x: int64) -> int64:
    a: int64 = x
    a = a * {m} + {d}
    return a

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    print_u64(cast[uint64](f({litsrc(xl)})))
    return cast[int32](0)
"""
            run_case(srcA, add_ref, f"add m={m} d={d} x={xl}")
            # (b) SUB value form: `x*m - d`  (tile displacement = -d).
            sub_ref = u64(xl * m - d)
            srcS = PRELUDE + f"""
def f(x: int64) -> int64:
    a: int64 = x
    a = a * {m} - {d}
    return a

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    print_u64(cast[uint64](f({litsrc(xl)})))
    return cast[int32](0)
"""
            run_case(srcS, sub_ref, f"sub m={m} d={d} x={xl}")

# (c) bare MUL (d implicitly 0), const on the LEFT (commuted) — `m * x`.
for m in MULS:
    for x in XS:
        xl = s64(x)
        srcM = PRELUDE + f"""
def f(x: int64) -> int64:
    a: int64 = x
    a = {m} * a
    return a

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    print_u64(cast[uint64](f({litsrc(xl)})))
    return cast[int32](0)
"""
        run_case(srcM, u64(xl * m), f"mulL m={m} x={xl}")

print(f"[leamuladd] checked={checked} fails={fails}")
sys.exit(1 if fails else 0)
PY
rc=$?
if [ "$rc" = "0" ]; then
    echo "[leamuladd] PASS"
else
    echo "[leamuladd] FAIL"
fi
exit "$rc"
