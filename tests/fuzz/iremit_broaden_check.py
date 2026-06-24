#!/usr/bin/env python3
# tests/fuzz/iremit_broaden_check.py
#
# Phase-6 IR-EMIT BROADENING differential check. Hand-written programs whose hot
# expressions are COMPARES (signed/unsigned) and DIV/MOD/SHR (incl. NEGATIVE
# dividends — the classic idiv-vs-div / sar-vs-shr miscompile traps). Each must:
#   * run correct vs a Python oracle that models the SAME signed/unsigned 64-bit
#     semantics the seed (codegen_x86.py) implements,
#   * demonstrably go THROUGH the IR emitter (IREMIT > 0, not the AST fallback),
#   * be byte-INERT with --opt OFF (IREMIT == 0 on the off dump).
#
# This is the focused soundness gate for the broadened lowered set. The broad
# fuzzer correctness lane (ADDER_OPT=1 fuzz_adder_diff.sh) covers the random
# corpus; this file pins the specific signed-vs-unsigned + negative-dividend
# cases that are easy to miscompile.
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


def s64(x):
    x &= M
    return x - (1 << 64) if x >= (1 << 63) else x


def main_wrap(decls, callexpr):
    return (PRELUDE + "\n" + decls +
            "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
            f"    g_accum = {callexpr}\n"
            "    print_u64(g_accum)\n"
            "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n")


# Each entry: (name, decls, callexpr_returning_uint64, expected_uint64).
def corpus():
    progs = []

    # ---- UNSIGNED compares (operands declared uintN -> setb/seta family) ----
    a, b = 5, 9
    progs.append(("ucmp_lt",
        "def f(a: uint64, b: uint64) -> uint64:\n"
        "    return cast[uint64](a < b)\n",
        f"f(cast[uint64]({a}), cast[uint64]({b}))",
        u64(int(u64(a) < u64(b)))))

    # Unsigned compare where the SIGNED interpretation would FLIP the result:
    # a = (uint64)-1 (huge), b = 1. Unsigned: a > b (True). Signed: a < b.
    a, b = M, 1
    progs.append(("ucmp_wrap_gt",
        "def f(a: uint64, b: uint64) -> uint64:\n"
        "    return cast[uint64](a > b)\n",
        f"f(cast[uint64]({a}), cast[uint64]({b}))",
        u64(int(u64(a) > u64(b)))))
    progs.append(("ucmp_wrap_lt",
        "def f(a: uint64, b: uint64) -> uint64:\n"
        "    return cast[uint64](a < b)\n",
        f"f(cast[uint64]({a}), cast[uint64]({b}))",
        u64(int(u64(a) < u64(b)))))   # expected 0 (huge < 1 is false unsigned)

    # ---- SIGNED compares (operands declared intN -> setl/setg family) ----
    # a = -1 (as int64), b = 1. Signed: a < b True. Unsigned would be False.
    progs.append(("scmp_neg_lt",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    return cast[uint64](a < b)\n",
        "f(cast[int64](0) - cast[int64](1), cast[int64](1))",
        u64(int(s64(M) < s64(1)))))   # -1 < 1 -> True -> 1
    progs.append(("scmp_neg_ge",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    return cast[uint64](a >= b)\n",
        "f(cast[int64](0) - cast[int64](5), cast[int64](2))",
        u64(int(s64(u64(-5)) >= s64(2)))))  # -5 >= 2 -> False -> 0

    # eq / neq (sign-invariant but still exercises the cmp/setcc IR path).
    progs.append(("eq_true",
        "def f(a: uint64, b: uint64) -> uint64:\n"
        "    return cast[uint64](a == b)\n",
        "f(cast[uint64](7), cast[uint64](7))", 1))
    progs.append(("neq_true",
        "def f(a: uint64, b: uint64) -> uint64:\n"
        "    return cast[uint64](a != b)\n",
        "f(cast[uint64](7), cast[uint64](8))", 1))

    # ---- UNSIGNED div/mod (uint operands -> div, xor %rdx) ----
    a, b = 100, 7
    progs.append(("udiv",
        "def f(a: uint64, b: uint64) -> uint64:\n"
        "    return a / b\n",
        f"f(cast[uint64]({a}), cast[uint64]({b}))", u64(u64(a) // u64(b))))
    progs.append(("umod",
        "def f(a: uint64, b: uint64) -> uint64:\n"
        "    return a % b\n",
        f"f(cast[uint64]({a}), cast[uint64]({b}))", u64(u64(a) % u64(b))))

    # ---- SIGNED div/mod with NEGATIVE dividend (int operands -> cqo;idiv) ----
    # -7 / 2  : C/x86 truncates toward zero -> -3 (NOT Python floor -4).
    progs.append(("sdiv_neg",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    return cast[uint64](a / b)\n",
        "f(cast[int64](0) - cast[int64](7), cast[int64](2))",
        u64(_ctrunc_div(-7, 2))))
    # -7 % 2 : x86 idiv remainder has sign of dividend -> -1.
    progs.append(("smod_neg",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    return cast[uint64](a % b)\n",
        "f(cast[int64](0) - cast[int64](7), cast[int64](2))",
        u64(_ctrunc_mod(-7, 2))))
    # -100 / 7 -> -14 (trunc), -100 % 7 -> -2.
    progs.append(("sdiv_neg2",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    return cast[uint64](a / b)\n",
        "f(cast[int64](0) - cast[int64](100), cast[int64](7))",
        u64(_ctrunc_div(-100, 7))))
    progs.append(("smod_neg2",
        "def f(a: int64, b: int64) -> uint64:\n"
        "    return cast[uint64](a % b)\n",
        "f(cast[int64](0) - cast[int64](100), cast[int64](7))",
        u64(_ctrunc_mod(-100, 7))))

    # ---- SHR: logical (unsigned) vs arithmetic (signed) ----
    # Unsigned huge value >> 4 : logical shift, zero-fill.
    progs.append(("shr_logical",
        "def f(a: uint64, n: uint64) -> uint64:\n"
        "    return a >> n\n",
        f"f(cast[uint64]({M}), cast[uint64](4))", u64(M >> 4)))
    # Signed -16 >> 2 : arithmetic shift -> -4 (sign-extends).
    progs.append(("sar_signed",
        "def f(a: int64, n: int64) -> uint64:\n"
        "    return cast[uint64](a >> n)\n",
        "f(cast[int64](0) - cast[int64](16), cast[int64](2))",
        u64(s64(u64(-16)) >> 2)))   # Python >> on negative = arithmetic

    # ---- Mixed tree: arithmetic feeding a compare; div feeding arithmetic. ----
    a, b, c = 20, 6, 3
    # ((a*b) + c) < (a/b * 10)  ... over uint64
    expr = u64(int(u64(u64(u64(a) * u64(b)) + u64(c)) <
                   u64(u64(u64(a) // u64(b)) * 10)))
    progs.append(("mixed_div_cmp",
        "def f(a: uint64, b: uint64, c: uint64) -> uint64:\n"
        "    return cast[uint64](((a * b) + c) < ((a / b) * cast[uint64](10)))\n",
        f"f(cast[uint64]({a}), cast[uint64]({b}), cast[uint64]({c}))", expr))

    return progs


def _ctrunc_div(a, b):
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    return q


def _ctrunc_mod(a, b):
    return a - _ctrunc_div(a, b) * b


def run():
    ok = True
    total_iremit = 0
    n_pass = 0
    n_total = 0
    for (name, decls, callexpr, expected) in corpus():
        n_total += 1
        body = main_wrap(decls, callexpr)
        r = host.run_through_codegen_ad(f"brd_{name}", body, WORK, opt=True)
        if r.kind != "ok":
            ok = False
            print(f"  [{name}] codegen.ad {r.kind}: {str(r.detail)[:120]}")
            continue
        ie = int(getattr(r, "iremit", 0) or 0)
        total_iremit += ie
        exp_out = str(expected)
        exp_exit = expected & 255
        if r.stdout != exp_out or r.exit != exp_exit:
            ok = False
            print(f"  [{name}] MISCOMPILE got=({r.stdout},{r.exit}) "
                  f"oracle=({exp_out},{exp_exit}) iremit={ie}")
            continue
        if ie == 0:
            ok = False
            print(f"  [{name}] correct but IR EMITTER NEVER FIRED (AST fallback)")
            continue
        # byte-inert OFF: dump off must have IREMIT == 0.
        src = WORK / f"brd_off_{name}.ad"
        src.write_text(host.codegen_compatible_source(body))
        d_off = host.run_dump(src, opt=False)
        if d_off.status != "ok" or getattr(d_off, "iremit", 0) != 0:
            ok = False
            print(f"  [{name}] OFF path NOT byte-inert: status={d_off.status} "
                  f"iremit={getattr(d_off, 'iremit', '?')}")
            continue
        n_pass += 1
        print(f"  [{name}] OK  out={r.stdout} iremit={ie}")
    print(f"\n[iremit_broaden] {n_pass}/{n_total} correct+IR-fired, "
          f"total IREMIT={total_iremit}")
    if total_iremit == 0:
        print("  FAIL: no program exercised the IR emitter")
        ok = False
    return ok


if __name__ == "__main__":
    sys.exit(0 if run() else 1)
