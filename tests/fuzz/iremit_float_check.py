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
        total_iremitfloat += ief
        exp_out = str(expected)
        exp_exit = expected & 255
        if r.stdout != exp_out or r.exit != exp_exit:
            ok = False
            print(f"  [{name}] MISCOMPILE got=({r.stdout},{r.exit}) "
                  f"oracle=({exp_out},{exp_exit}) iremitfloat={ief}")
            continue
        if ief == 0:
            ok = False
            print(f"  [{name}] correct but FLOAT IR EMITTER NEVER FIRED "
                  f"(AST fallback) iremit={getattr(r, 'iremit', 0)}")
            continue
        # byte-inert OFF: dump off must have IREMITFLOAT == 0 AND IREMIT == 0.
        src = WORK / f"flt_off_{name}.ad"
        src.write_text(host.codegen_compatible_source(body))
        d_off = host.run_dump(src, opt=False)
        src.unlink(missing_ok=True)
        if (d_off.status != "ok"
                or getattr(d_off, "iremitfloat", 0) != 0
                or getattr(d_off, "iremit", 0) != 0):
            ok = False
            print(f"  [{name}] OFF path NOT byte-inert: status={d_off.status} "
                  f"iremitfloat={getattr(d_off, 'iremitfloat', '?')} "
                  f"iremit={getattr(d_off, 'iremit', '?')}")
            continue
        n_pass += 1
        print(f"  [{name}] OK  out={r.stdout} iremitfloat={ief}")
    print(f"\n[iremit_float] {n_pass}/{n_total} correct+float-IR-fired, "
          f"total IREMITFLOAT={total_iremitfloat}")
    if total_iremitfloat == 0:
        print("  FAIL: no program exercised the FLOAT IR emitter")
        ok = False
    if n_pass != n_total:
        ok = False
    return ok


if __name__ == "__main__":
    sys.exit(0 if run() else 1)
