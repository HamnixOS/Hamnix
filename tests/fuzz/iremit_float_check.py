#!/usr/bin/env python3
# tests/fuzz/iremit_float_check.py
#
# FLOAT IR-EMIT soundness gate. Hand-written programs whose hot expressions are
# FLOAT arithmetic (+,-,*,/) and FLOAT compares at BOTH widths (float32 / float64),
# including mixed-precision (f32 op f64), int->float promotion, negative / zero
# operands, and a float subexpression nested inside a larger float expression.
# Each program must:
#   * run CORRECT vs a Python oracle that models the SAME IEEE-754 SSE semantics
#     the seed (codegen_x86.py) emits (f32 results snapped to float via struct;
#     final value truncated back to int exactly as cvttsd2si/cvttss2si would),
#   * demonstrably go THROUGH the float IR emitter (IREMITFLOAT > 0, not the AST
#     fallback),
#   * be byte-INERT with --opt OFF (IREMITFLOAT == 0 and IREMIT == 0 on the off
#     dump).
#
# This is the focused soundness gate for the float lowering. The broad fuzzer
# correctness lane (ADDER_OPT=1 fuzz_adder_diff.sh) already generates float
# traffic across a random corpus and executes it bit-exact vs the oracle; this
# file pins the specific f32/f64/mixed/compare/nested cases that are easy to
# miscompile, and asserts the float IR path actually fires.
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(HERE))

import ad_codegen_host as host  # noqa: E402
from adder_fuzzer import PRELUDE  # noqa: E402

M = (1 << 64) - 1
WORK = REPO_ROOT / "build" / "fuzz_ad_codegen"


def u64(x):
    return x & M


def f32(x):
    """Snap a double to its float32 representable value (SSE round-to-nearest)."""
    return struct.unpack("<f", struct.pack("<f", float(x)))[0]


def trunc_i64(x):
    """cvttsd2si / cvttss2si: truncate toward zero to a 64-bit signed int."""
    return int(x)  # Python int(float) truncates toward zero


def main_wrap(decls, callexpr):
    return (PRELUDE + "\n" + decls +
            "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
            f"    g_accum = {callexpr}\n"
            "    print_u64(g_accum)\n"
            "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n")


# Each entry: (name, decls, callexpr_returning_uint64, expected_uint64).
def corpus():
    progs = []

    # ---- float64 arithmetic (+,-,*,/) truncated back to int ----
    a, b = 7, 3
    af, bf = float(a), float(b)
    progs.append(("f64_add",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    x: float64 = cast[float64](a) + cast[float64](b)\n"
        "    return cast[uint64](cast[int64](x))\n",
        f"f({a}, {b})", u64(trunc_i64(af + bf))))
    progs.append(("f64_sub",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    x: float64 = cast[float64](a) - cast[float64](b)\n"
        "    return cast[uint64](cast[int64](x))\n",
        f"f({a}, {b})", u64(trunc_i64(af - bf))))
    progs.append(("f64_mul",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    x: float64 = cast[float64](a) * cast[float64](b)\n"
        "    return cast[uint64](cast[int64](x))\n",
        f"f({a}, {b})", u64(trunc_i64(af * bf))))
    progs.append(("f64_div",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    x: float64 = cast[float64](a) / cast[float64](b)\n"
        "    return cast[uint64](cast[int64](x))\n",
        f"f({a}, {b})", u64(trunc_i64(af / bf))))  # 7/3 -> 2.333 -> 2

    # ---- NEGATIVE / ZERO operands (sign-bit, trunc-toward-zero traps) ----
    na, nb = -7, 3
    progs.append(("f64_div_neg",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    x: float64 = cast[float64](a) / cast[float64](b)\n"
        "    return cast[uint64](cast[int64](x))\n",
        f"f({na}, {nb})", u64(trunc_i64(float(na) / float(nb)))))  # -2.333 -> -2
    progs.append(("f64_mul_zero",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    x: float64 = cast[float64](a) * cast[float64](b)\n"
        "    return cast[uint64](cast[int64](x))\n",
        f"f(0, {b})", u64(0)))

    # ---- float32 arithmetic (ss variants — 4-byte width) ----
    progs.append(("f32_mul",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    x: float32 = cast[float32](a) * cast[float32](b)\n"
        "    return cast[uint64](cast[int64](x))\n",
        f"f({a}, {b})", u64(trunc_i64(f32(f32(a) * f32(b))))))
    progs.append(("f32_div",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    x: float32 = cast[float32](a) / cast[float32](b)\n"
        "    return cast[uint64](cast[int64](x))\n",
        f"f(22, 7)", u64(trunc_i64(f32(f32(22) / f32(7))))))  # ~3.14 -> 3

    # ---- MIXED precision: float32 op float64 -> widen to float64 ----
    # cast[float64](cast[float32](a)) keeps a as a 32-bit value widened; then
    # add a float64. The seed promotes the f32 operand to f64 (cvtss2sd).
    progs.append(("mixed_f32_plus_f64",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    x: float64 = cast[float32](a) + cast[float64](b)\n"
        "    return cast[uint64](cast[int64](x))\n",
        f"f({a}, {b})", u64(trunc_i64(f32(a) + float(b)))))

    # ---- NESTED float subexpression inside a larger float expression ----
    # (a*b) + (a-b) all in float64 -> the inner products are float IR_BINOPs.
    progs.append(("f64_nested",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    x: float64 = cast[float64](a) * cast[float64](b) + (cast[float64](a) - cast[float64](b))\n"
        "    return cast[uint64](cast[int64](x))\n",
        f"f({a}, {b})", u64(trunc_i64(af * bf + (af - bf)))))  # 21+4 = 25

    # ---- FLOAT COMPARES (both directions, both widths) ----
    progs.append(("f64_gt",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    return cast[uint64](cast[float64](a) > cast[float64](b))\n",
        f"f({a}, {b})", u64(int(af > bf))))          # 7>3 -> 1
    progs.append(("f64_lt",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    return cast[uint64](cast[float64](a) < cast[float64](b))\n",
        f"f({a}, {b})", u64(int(af < bf))))          # 7<3 -> 0
    progs.append(("f64_eq",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    return cast[uint64](cast[float64](a) == cast[float64](b))\n",
        f"f({a}, {a})", u64(1)))
    progs.append(("f32_lte",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    return cast[uint64](cast[float32](a) <= cast[float32](b))\n",
        f"f({b}, {a})", u64(int(f32(b) <= f32(a)))))  # 3<=7 -> 1
    progs.append(("f64_neq",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    return cast[uint64](cast[float64](a) != cast[float64](b))\n",
        f"f({a}, {b})", u64(1)))

    return progs


# ----------------------------------------------------------------------------
# FLOAT optimization corpus: programs whose hot FLOAT subexpressions are
# const-folded / CSE'd / LICM-hoisted by the native optimizer. Each asserts:
#   * bit-exact result vs a Python IEEE oracle (so the float opt is value-
#     preserving — a wrong bit = miscompile),
#   * the EXPECTED opt counter fired (ffold / cse / licm >= 1) so the pass
#     demonstrably reaches floats (NOT silently skipped),
#   * byte-INERT with --opt OFF (no opt counter fires off).
# This is the float analogue of the integer CSE/LICM corpora; the broad fuzzer
# never repeats a float subexpression, so without this the float CSE/LICM paths
# would be unexercised.
#
# Each entry: (name, body, expected_uint64, counter_name, min_count).
def opt_corpus():
    progs = []
    P = PRELUDE + "\n"

    def wrap(decls):
        return (P + decls +
                "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
                "    g_accum = f(7, 3)\n"
                "    print_u64(g_accum)\n"
                "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n")

    # ---- FLOAT CONST-FOLD: exact-integer f64 ADD/SUB/MUL -> one literal ----
    progs.append(("ffold_mul",
        wrap("def f(a: int64, b: int64) -> uint64:\n"
             "    x: float64 = cast[float64](6) * cast[float64](7)\n"
             "    return cast[uint64](cast[int64](x))\n"),
        u64(42), "ffold", 1))
    progs.append(("ffold_nested",
        wrap("def f(a: int64, b: int64) -> uint64:\n"
             "    x: float64 = (cast[float64](2) + cast[float64](3)) * cast[float64](4)\n"
             "    return cast[uint64](cast[int64](x))\n"),
        u64(20), "ffold", 1))

    # ---- FLOAT CSE: a repeated float subexpression shares one xmm result ----
    # (fa+fb) appears twice -> CSE'd into a typed float64 temp. (7+3)^2 = 100.
    progs.append(("fcse_f64",
        wrap("def f(a: int64, b: int64) -> uint64:\n"
             "    fa: float64 = cast[float64](a)\n"
             "    fb: float64 = cast[float64](b)\n"
             "    x: float64 = (fa + fb) * (fa + fb)\n"
             "    return cast[uint64](cast[int64](x))\n"),
        u64(100), "cse", 1))
    # float32 CSE (4-byte typed temp). (7+3)*(7+3) = 100.
    progs.append(("fcse_f32",
        wrap("def f(a: int64, b: int64) -> uint64:\n"
             "    fa: float32 = cast[float32](a)\n"
             "    fb: float32 = cast[float32](b)\n"
             "    x: float32 = (fa + fb) * (fa + fb)\n"
             "    return cast[uint64](cast[int64](x))\n"),
        u64(100), "cse", 1))
    # mixed-width repeated subexpression (f32 + f64 -> f64 temp). (7+3)+(7+3)=20.
    progs.append(("fxcse_mixed",
        wrap("def f(a: int64, b: int64) -> uint64:\n"
             "    x: float64 = (cast[float32](a) + cast[float64](b)) + (cast[float32](a) + cast[float64](b))\n"
             "    return cast[uint64](cast[int64](x))\n"),
        u64(20), "cse", 1))

    # ---- FLOAT LICM: loop-invariant float subexpression hoisted ----
    # fa*fb invariant -> hoisted to a float64 pre-header temp; loop adds it 3x.
    # f(7,3): 7*3=21, *3 iterations = 63.
    progs.append(("flicm_f64",
        wrap("def f(a: int64, b: int64) -> uint64:\n"
             "    fa: float64 = cast[float64](a)\n"
             "    fb: float64 = cast[float64](b)\n"
             "    acc: float64 = cast[float64](0)\n"
             "    i: int64 = 0\n"
             "    while i < 3:\n"
             "        acc = acc + (fa * fb)\n"
             "        i = i + 1\n"
             "    return cast[uint64](cast[int64](acc))\n"),
        u64(63), "licm", 1))
    return progs


def run_opt_corpus():
    ok = True
    totals = {"ffold": 0, "cse": 0, "licm": 0}
    n_pass = 0
    n_total = 0
    for (name, body, expected, counter, mincount) in opt_corpus():
        n_total += 1
        r = host.run_through_codegen_ad(f"fopt_{name}", body, WORK, opt=True)
        if r.kind != "ok":
            ok = False
            print(f"  [{name}] codegen.ad {r.kind}: {str(r.detail)[:160]}")
            continue
        got_count = int(getattr(r, counter, 0) or 0)
        totals[counter] = totals.get(counter, 0) + got_count
        if r.stdout != str(expected):
            ok = False
            print(f"  [{name}] MISCOMPILE got={r.stdout} oracle={expected} "
                  f"{counter}={got_count}")
            continue
        if got_count < mincount:
            ok = False
            print(f"  [{name}] correct but {counter} pass NEVER FIRED "
                  f"({counter}={got_count}, want >= {mincount})")
            continue
        # byte-inert OFF: no opt counter may fire with --opt off.
        src = WORK / f"fopt_off_{name}.ad"
        src.write_text(host.codegen_compatible_source(body))
        d_off = host.run_dump(src, opt=False)
        src.unlink(missing_ok=True)
        off_bad = (d_off.status != "ok"
                   or int(getattr(d_off, "FFOLD", getattr(d_off, "ffold", 0)) or 0) != 0
                   or int(getattr(d_off, "CSE", getattr(d_off, "cse", 0)) or 0) != 0
                   or int(getattr(d_off, "LICM", getattr(d_off, "licm", 0)) or 0) != 0)
        if off_bad:
            ok = False
            print(f"  [{name}] OFF path NOT byte-inert: status={d_off.status}")
            continue
        n_pass += 1
        print(f"  [{name}] OK  out={r.stdout} {counter}={got_count}")
    print(f"\n[float_opt] {n_pass}/{n_total} correct+pass-fired  "
          f"ffold={totals['ffold']} cse={totals['cse']} licm={totals['licm']}")
    if totals["ffold"] == 0 or totals["cse"] == 0 or totals["licm"] == 0:
        print("  FAIL: a float opt pass (fold/cse/licm) never fired on the corpus")
        ok = False
    if n_pass != n_total:
        ok = False
    return ok


def run():
    ok = True
    total_iremitfloat = 0
    n_pass = 0
    n_total = 0
    for (name, decls, callexpr, expected) in corpus():
        n_total += 1
        body = main_wrap(decls, callexpr)
        r = host.run_through_codegen_ad(f"flt_{name}", body, WORK, opt=True)
        if r.kind != "ok":
            ok = False
            print(f"  [{name}] codegen.ad {r.kind}: {str(r.detail)[:160]}")
            continue
        ief = int(getattr(r, "iremitfloat", 0) or 0)
        fps = int(getattr(r, "fpsel", 0) or 0)
        total_iremitfloat += ief
        exp_out = str(expected)
        exp_exit = expected & 255
        if r.stdout != exp_out or r.exit != exp_exit:
            ok = False
            print(f"  [{name}] MISCOMPILE got=({r.stdout},{r.exit}) "
                  f"oracle=({exp_out},{exp_exit}) iremitfloat={ief} fpsel={fps}")
            continue
        # A float ASSIGNMENT root (`x: floatN = <arith>`) now lowers through the
        # FLOAT-SSE DEST-DRIVEN SELECTOR (fpsel) — a strict improvement over the
        # older float IR emitter (iremitfloat) it supersedes for that shape; a
        # float COMPARE value and a float32 tree still take the IR-emit path. So a
        # "float lowering fired" demonstration is satisfied by EITHER counter.
        if ief == 0 and fps == 0:
            ok = False
            print(f"  [{name}] correct but NO FLOAT LOWERING FIRED (AST fallback) "
                  f"iremit={getattr(r, 'iremit', 0)}")
            continue
        # byte-inert OFF: dump off must have IREMITFLOAT == 0, IREMIT == 0, and
        # the float selector (FPSEL) == 0.
        src = WORK / f"flt_off_{name}.ad"
        src.write_text(host.codegen_compatible_source(body))
        d_off = host.run_dump(src, opt=False)
        src.unlink(missing_ok=True)
        if (d_off.status != "ok"
                or getattr(d_off, "iremitfloat", 0) != 0
                or getattr(d_off, "iremit", 0) != 0
                or getattr(d_off, "fpsel", 0) != 0):
            ok = False
            print(f"  [{name}] OFF path NOT byte-inert: status={d_off.status} "
                  f"iremitfloat={getattr(d_off, 'iremitfloat', '?')} "
                  f"iremit={getattr(d_off, 'iremit', '?')} "
                  f"fpsel={getattr(d_off, 'fpsel', '?')}")
            continue
        n_pass += 1
        print(f"  [{name}] OK  out={r.stdout} iremitfloat={ief} fpsel={fps}")
    print(f"\n[iremit_float] {n_pass}/{n_total} correct+float-IR-fired, "
          f"total IREMITFLOAT={total_iremitfloat}")
    if total_iremitfloat == 0:
        print("  FAIL: no program exercised the FLOAT IR emitter")
        ok = False
    if n_pass != n_total:
        ok = False
    return ok


if __name__ == "__main__":
    emit_ok = run()
    print("\n--- FLOAT optimization corpus (const-fold / CSE / LICM) ---")
    opt_ok = run_opt_corpus()
    sys.exit(0 if (emit_ok and opt_ok) else 1)
