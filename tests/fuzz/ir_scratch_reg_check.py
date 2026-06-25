#!/usr/bin/env python3
# tests/fuzz/ir_scratch_reg_check.py
#
# Phase-7 IR SCRATCH-REGISTER POOL soundness + win check.
#
# The IR-consuming emitter (codegen.ad gen_expr_ir) used to lower EVERY IR_BINOP
# as a stack machine: evaluate RIGHT -> %rax, `push %rax`, evaluate LEFT -> %rax,
# `pop %rcx`, `op %rcx,%rax`. Phase 7 instead holds the right operand in a
# CALLEE-SAVED scratch register drawn from the regalloc pool indices regalloc did
# not use, so the combine is `op %<scratch>,%rax` with NO stack round-trip. This
# file is the focused gate for that change:
#
#   1. CORRECTNESS (the important part — register allocation is a classic
#      miscompile source): a battery of register-pressure expressions, each run
#      through codegen.ad with --opt and checked against a 64-bit modular oracle.
#      Includes:
#        * deep balanced arithmetic trees (many simultaneous live intermediates),
#        * CALL-CROSSING: a function call inside an index leaf while a scratch
#          register holds a live right operand (the callee-saved pool must make
#          the scratch survive the call — a caller-saved temp would be clobbered),
#        * SPILL pressure: trees deeper than the 5-register pool, forcing the
#          push/pop fallback for the innermost nodes (must stay correct),
#        * mixes with promoted locals (scratch must not alias a register-resident
#          local), shifts/div/mod (which stay on the %rcx path) feeding scratch
#          arithmetic.
#   2. THE IR PATH ACTUALLY FIRES: IRSCRATCH > 0 with --opt on.
#   3. BYTE-INERT OFF: --opt off emits IRSCRATCH == 0 AND the same push/pop the
#      seed emits (we assert IREMIT == 0 off, which implies no scratch path).
#   4. STACK-TRAFFIC WIN: on a register-pressure benchmark, count the
#      `pushq %rax`(0x50)/`popq %rcx`(0x59) PAIRS the IR region would have emitted
#      (= IRSCRATCH hits, each a pair eliminated) and report the reduction.
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


def main_wrap(decls, callexpr):
    return (PRELUDE + "\n" + decls +
            "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
            f"    g_accum = {callexpr}\n"
            "    print_u64(g_accum)\n"
            "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n")


def corpus():
    progs = []

    # ---- Deep balanced arithmetic: many simultaneous live intermediates. ----
    # ((a*b) + (c*d)) - ((e*f) + (g*h))   over uint64. Each interior op holds its
    # right operand in a scratch reg across the left subtree -> peak ~3 live.
    a, b, c, d, e, f, g, h = 3, 5, 7, 11, 13, 17, 19, 23
    val = u64(u64(u64(a*b) + u64(c*d)) - u64(u64(e*f) + u64(g*h)))
    progs.append(("deep_balanced",
        "def f(a: uint64, b: uint64, c: uint64, d: uint64,\n"
        "      e: uint64, ff: uint64, g: uint64, h: uint64) -> uint64:\n"
        "    return ((a * b) + (c * d)) - ((e * ff) + (g * h))\n",
        f"f(cast[uint64]({a}),cast[uint64]({b}),cast[uint64]({c}),"
        f"cast[uint64]({d}),cast[uint64]({e}),cast[uint64]({f}),"
        f"cast[uint64]({g}),cast[uint64]({h}))",
        val))

    # ---- Left-leaning chain: (((((a+b)+c)+d)+e)+f). The reassoc path may fold
    #      none (all non-const); each + holds the right leaf in a scratch reg. ----
    vals = [101, 202, 303, 404, 505, 606]
    chain_val = u64(sum(vals))
    progs.append(("left_chain",
        "def f(a: uint64, b: uint64, c: uint64, d: uint64,\n"
        "      e: uint64, ff: uint64) -> uint64:\n"
        "    return (((((a + b) + c) + d) + e) + ff)\n",
        "f(" + ",".join(f"cast[uint64]({v})" for v in vals) + ")",
        chain_val))

    # ---- Right-leaning chain: a-(b-(c-(d-(e-f)))). Tests scratch hold across a
    #      DEEP right subtree (the right operand is itself a deep tree). ----
    rl = u64(a - u64(b - u64(c - u64(d - u64(e - f)))))
    progs.append(("right_chain",
        "def f(a: uint64, b: uint64, c: uint64, d: uint64,\n"
        "      e: uint64, ff: uint64) -> uint64:\n"
        "    return a - (b - (c - (d - (e - ff))))\n",
        f"f(cast[uint64]({a}),cast[uint64]({b}),cast[uint64]({c}),"
        f"cast[uint64]({d}),cast[uint64]({e}),cast[uint64]({f}))",
        rl))

    # ---- SPILL pressure: a balanced tree deep enough that >5 intermediates are
    #      simultaneously live, forcing the innermost nodes onto the push/pop
    #      fallback. Must stay correct.  16-leaf product-of-sums. ----
    leaves = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]
    # (((l0+l1)*(l2+l3)) + ((l4+l5)*(l6+l7))) - (((l8+l9)*(l10+l11)) + ((l12+l13)*(l14+l15)))
    def s(i):
        return u64(leaves[i] + leaves[i+1])
    def p(i):
        return u64(s(i) * s(i+2))
    spill_val = u64(u64(p(0) + p(4)) - u64(p(8) + p(12)))
    params = ", ".join(f"x{i}: uint64" for i in range(16))
    def sx(i):
        return f"(x{i} + x{i+1})"
    def px(i):
        return f"({sx(i)} * {sx(i+2)})"
    body_expr = f"(({px(0)} + {px(4)}) - ({px(8)} + {px(12)}))"
    progs.append(("spill_pressure",
        f"def f({params}) -> uint64:\n"
        f"    return {body_expr}\n",
        "f(" + ",".join(f"cast[uint64]({v})" for v in leaves) + ")",
        spill_val))

    # ---- CALL-CROSSING: a call inside an INDEX leaf while a scratch register
    #      holds a live right operand. `(buf[idx()] + K) * M2`: the `* M2` node
    #      parks `(buf[idx()]+K)` ... actually park order is right-first, so the
    #      MUL parks M2 in a scratch reg, then evaluates the left which calls
    #      idx(). The scratch (callee-saved) must survive the call. Also the inner
    #      ADD parks K and evaluates buf[idx()] (the call). ----
    # buf = {10,20,30,40}; idx() returns 2 -> buf[2]=30. (30 + 7) * 4 = 148.
    progs.append(("call_crossing",
        "buf: Array[4, uint64]\n"
        "def idx() -> uint64:\n"
        "    return cast[uint64](2)\n"
        "def f(k: uint64, m2: uint64) -> uint64:\n"
        "    buf[0] = cast[uint64](10)\n"
        "    buf[1] = cast[uint64](20)\n"
        "    buf[2] = cast[uint64](30)\n"
        "    buf[3] = cast[uint64](40)\n"
        "    return (buf[idx()] + k) * m2\n",
        "f(cast[uint64](7), cast[uint64](4))",
        u64((30 + 7) * 4)))

    # ---- Promoted-local mix: a local computed then reused several times in a
    #      pressured tree. The scratch pool must not alias the local's reg. ----
    # t = a*b ; return (t + c) * (t - d) ; a*b=15, (15+7)*(15-11)=22*4=88
    progs.append(("promoted_mix",
        "def f(a: uint64, b: uint64, c: uint64, d: uint64) -> uint64:\n"
        "    t: uint64 = a * b\n"
        "    return (t + c) * (t - d)\n",
        f"f(cast[uint64](3),cast[uint64](5),cast[uint64](7),cast[uint64](11))",
        u64((15 + 7) * (15 - 11))))

    # ---- Shift/div feeding scratch arithmetic: the shift stays on the %rcx
    #      path, its result feeds an ADD that uses a scratch reg. ----
    # ((a << b) + (c * d)) over uint64 : (3<<2)+(5*7)=12+35=47
    progs.append(("shift_feeds_add",
        "def f(a: uint64, b: uint64, c: uint64, d: uint64) -> uint64:\n"
        "    return (a << b) + (c * d)\n",
        f"f(cast[uint64](3),cast[uint64](2),cast[uint64](5),cast[uint64](7))",
        u64((3 << 2) + (5 * 7))))

    # ---- Compare with scratch source: (a*b) < (c*d) -> cmp %scratch,%rax. ----
    progs.append(("cmp_scratch",
        "def f(a: uint64, b: uint64, c: uint64, d: uint64) -> uint64:\n"
        "    return cast[uint64]((a * b) < (c * d))\n",
        f"f(cast[uint64](3),cast[uint64](5),cast[uint64](7),cast[uint64](11))",
        u64(int((3*5) < (7*11)))))

    return progs


def run():
    ok = True
    total_scratch = 0
    total_miss = 0
    n_pass = 0
    n_total = 0
    for (name, decls, callexpr, expected) in corpus():
        n_total += 1
        body = main_wrap(decls, callexpr)
        r = host.run_through_codegen_ad(f"scr_{name}", body, WORK, opt=True)
        if r.kind != "ok":
            ok = False
            print(f"  [{name}] codegen.ad {r.kind}: {str(r.detail)[:160]}")
            continue
        exp_out = str(expected)
        exp_exit = expected & 255
        if r.stdout != exp_out or r.exit != exp_exit:
            ok = False
            print(f"  [{name}] MISCOMPILE got=({r.stdout},{r.exit}) "
                  f"oracle=({exp_out},{exp_exit})")
            continue
        # Re-run the dump directly to read the scratch stats (run_through_codegen_ad
        # does not surface them).
        src = WORK / f"scr_dump_{name}.ad"
        src.write_text(host.codegen_compatible_source(body))
        d_on = host.run_dump(src, opt=True)
        scratch = int(getattr(d_on, "irscratch", 0) or 0)
        miss = int(getattr(d_on, "irscratchmiss", 0) or 0)
        total_scratch += scratch
        total_miss += miss
        # byte-inert OFF: the IR emitter (and thus scratch path) must not fire.
        d_off = host.run_dump(src, opt=False)
        if d_off.status != "ok" or getattr(d_off, "iremit", 0) != 0 \
                or getattr(d_off, "irscratch", 0) != 0:
            ok = False
            print(f"  [{name}] OFF NOT byte-inert: iremit="
                  f"{getattr(d_off, 'iremit', '?')} "
                  f"irscratch={getattr(d_off, 'irscratch', '?')}")
            continue
        n_pass += 1
        print(f"  [{name}] OK out={r.stdout} scratch_hits={scratch} "
              f"pushpop_fallback={miss}")
    print(f"\n[ir_scratch] {n_pass}/{n_total} correct, "
          f"total scratch hits={total_scratch} (= push/pop PAIRS eliminated), "
          f"push/pop fallbacks={total_miss}")
    if total_scratch == 0:
        print("  FAIL: the scratch-register path never fired")
        ok = False
    return ok


if __name__ == "__main__":
    sys.exit(0 if run() else 1)
