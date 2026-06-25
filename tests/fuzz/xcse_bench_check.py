#!/usr/bin/env python3
# tests/fuzz/xcse_bench_check.py
#
# Phase-7 CROSS-STATEMENT CSE differential + BENCHMARK gate.
#
# WHAT THIS PROVES
# ----------------
# opt.ad Phase 7 adds CROSS-STATEMENT common-subexpression elimination over an
# extended (straight-line) basic block: a pure subexpression computed in one
# statement and recomputed verbatim in a later statement — with NO intervening
# write to its leaves — is materialized once into a temp and the later
# recomputation reads the temp. (Phase-2 CSE only shared WITHIN a single
# statement's expression tree; the cross-statement repeat is the common case in
# real straight-line code and was missed.)
#
# This file is the focused soundness + measurement gate:
#   * CORRECTNESS: every program runs identically with --opt OFF and ON,
#     against the same wrapped ELF the differential fuzzer uses (the by-
#     construction oracle is already validated vs the Python seed).
#   * FIRING: the cross-statement cases demonstrably bump the CSE counter under
#     --opt (the redundant recomputations are actually eliminated).
#   * SAFETY: the negative cases (a write between the two occurrences; a call
#     barrier between them; an opaque/aliasing store) must NOT share — CSE must
#     stay 0 there, and the result must still match.
#   * BENCHMARK: a representative hot loop with a loop-invariant subexpression
#     (LICM) AND a cross-statement repeated subexpression (Phase-7 CSE) executes
#     measurably FEWER DYNAMIC INSTRUCTIONS with --opt ON, producing the
#     seed-identical result. The dynamic instruction count is measured exactly
#     via PTRACE_SINGLESTEP (no perf/valgrind dependency), so the win is a hard,
#     reproducible number, not an estimate.
#
# HOST-ONLY: python3 + as/ld/gcc on x86_64 (same env as fuzz_adder_diff.sh).
# Exits nonzero on any miscompile, any safety violation, or if the benchmark
# fails to reduce the dynamic instruction count.
import ctypes
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(HERE))

import ad_codegen_host as host  # noqa: E402
from adder_fuzzer import PRELUDE  # noqa: E402

WORK = REPO_ROOT / "build" / "fuzz_ad_codegen"


# --------------------------------------------------------------------------
# Dynamic user-instruction counter via PTRACE_SINGLESTEP. Deterministic and
# self-contained (no perf_event / valgrind). Counts retired user instructions
# of a statically-linked freestanding ELF from _start to exit.
# --------------------------------------------------------------------------
_libc = ctypes.CDLL("libc.so.6", use_errno=True)
_libc.ptrace.restype = ctypes.c_long
_libc.ptrace.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_long, ctypes.c_long]
_PTRACE_TRACEME = 0
_PTRACE_SINGLESTEP = 9


def dyn_icount(path: str) -> int:
    pid = os.fork()
    if pid == 0:
        _libc.ptrace(_PTRACE_TRACEME, 0, 0, 0)
        dn = os.open("/dev/null", os.O_WRONLY)
        os.dup2(dn, 1)
        os.execv(path, [path])
        os._exit(127)
    os.waitpid(pid, 0)  # initial stop at exec
    n = 0
    while True:
        _libc.ptrace(_PTRACE_SINGLESTEP, pid, 0, 0)
        _, st = os.waitpid(pid, 0)
        if os.WIFEXITED(st) or os.WIFSIGNALED(st):
            break
        n += 1
    return n


# --------------------------------------------------------------------------
# Compile a body through codegen.ad with a given --opt setting and return both
# the dump metadata (CSE/LICM/IREMIT counters, code_len) and the run result
# (stdout, exit) of the wrapped ELF.
# --------------------------------------------------------------------------
class Built:
    def __init__(self, dump, elf, out, exit_code, icount):
        self.dump = dump
        self.elf = elf
        self.out = out
        self.exit = exit_code
        self.icount = icount


def build_and_run(name, body, opt, want_icount=False):
    WORK.mkdir(parents=True, exist_ok=True)
    cg = host.codegen_compatible_source(body)
    src = WORK / f"xcse_{name}_{int(opt)}.ad"
    elf = WORK / f"xcse_{name}_{int(opt)}.elf"
    src.write_text(cg)
    dump = host.run_dump(src, opt=opt)
    if dump.status != "ok":
        return None
    host.wrap_elf(dump, elf)
    rp = subprocess.run([str(elf)], capture_output=True, text=True, timeout=20)
    ic = dyn_icount(str(elf)) if want_icount else 0
    return Built(dump, elf, rp.stdout.strip(), rp.returncode & 0xFF, ic)


def main_wrap(decls, callexpr):
    return (PRELUDE + "\n" + decls +
            "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
            f"    g_accum = {callexpr}\n"
            "    print_u64(g_accum)\n"
            "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n")


# --------------------------------------------------------------------------
# POSITIVE cases — cross-statement CSE MUST fire (min_cse > 0) and stay correct.
# Each entry: (name, decls, callexpr, min_cse).
# --------------------------------------------------------------------------
def positive_corpus():
    return [
        # a*b+c recomputed across THREE statements, no clobber -> >=2 shared.
        ("three_stmt",
         "def f(a: uint64, b: uint64, c: uint64, d: uint64) -> uint64:\n"
         "    x: uint64 = a * b + c\n"
         "    y: uint64 = a * b + c + d\n"
         "    z: uint64 = (a * b + c) * d\n"
         "    return x + y + z\n",
         "f(cast[uint64](3),cast[uint64](4),cast[uint64](5),cast[uint64](6))",
         2),
        # Repeat across two assignments to DIFFERENT targets; operands untouched.
        ("two_assign",
         "def f(a: uint64, b: uint64) -> uint64:\n"
         "    p: uint64 = cast[uint64](0)\n"
         "    q: uint64 = cast[uint64](0)\n"
         "    p = (a + b) * (a + b)\n"
         "    q = (a + b) * (a + b) + a\n"
         "    return p + q\n",
         "f(cast[uint64](7),cast[uint64](9))",
         1),
        # An UNRELATED write between occurrences must not block the share.
        ("unrelated_write",
         "def f(a: uint64, b: uint64, c: uint64) -> uint64:\n"
         "    x: uint64 = a + c\n"
         "    y: uint64 = a + c\n"
         "    b = b + cast[uint64](1)\n"
         "    z: uint64 = a + c\n"
         "    return x + y + z + b\n",
         "f(cast[uint64](3),cast[uint64](4),cast[uint64](5))",
         2),
        # TWO distinct repeated expressions FIRST seen in the SAME statement:
        # both temps anchor before that statement, exercising the multi-decl-
        # before-the-same-anchor splice path (must not orphan a temp decl).
        ("two_anchor_same",
         "def f(a: uint64, b: uint64, c: uint64, d: uint64) -> uint64:\n"
         "    x: uint64 = (a + b) * (a + b) + (c + d) * (c + d)\n"
         "    y: uint64 = (a + b) * (a + b)\n"
         "    z: uint64 = (c + d) * (c + d)\n"
         "    return x + y + z\n",
         "f(cast[uint64](1),cast[uint64](2),cast[uint64](3),cast[uint64](4))",
         2),
        # A CALL barrier splits the body into TWO straight-line runs, each with
        # its own cross-statement redundancy. Exercises interior-run head
        # movement after a barrier (the second run's spliced temp must relink to
        # the barrier statement, not dangle).
        ("two_runs",
         "def gg(z: uint64) -> uint64:\n"
         "    return z\n"
         "def f(a: uint64, b: uint64) -> uint64:\n"
         "    x: uint64 = a * b + a\n"
         "    y: uint64 = a * b + a + b\n"
         "    w: uint64 = gg(a)\n"
         "    p: uint64 = a + b + w\n"
         "    q: uint64 = a + b + w + a\n"
         "    return x + y + p + q\n",
         "f(cast[uint64](5),cast[uint64](6))",
         2),
    ]


# --------------------------------------------------------------------------
# NEGATIVE cases — cross-statement CSE MUST NOT fire (CSE stays 0) because a
# write / barrier sits between the two occurrences. Result must still match.
# Each entry: (name, body-with-main).
# --------------------------------------------------------------------------
def negative_corpus():
    return [
        # Operand `a` reassigned between the two `a*b+c` -> different values.
        ("write_between",
         PRELUDE +
         "def f(a: uint64, b: uint64, c: uint64) -> uint64:\n"
         "    x: uint64 = a * b + c\n"
         "    a = a + cast[uint64](100)\n"
         "    y: uint64 = a * b + c\n"
         "    return x + y\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    g_accum = f(cast[uint64](3),cast[uint64](4),cast[uint64](5))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n"),
        # A CALL between the occurrences is a hard barrier (flush availability).
        ("call_barrier",
         PRELUDE +
         "def g(z: uint64) -> uint64:\n"
         "    return z + cast[uint64](1)\n"
         "def f(a: uint64, b: uint64, c: uint64) -> uint64:\n"
         "    x: uint64 = a * b + c\n"
         "    w: uint64 = g(a)\n"
         "    y: uint64 = a * b + c\n"
         "    return x + y + w\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    g_accum = f(cast[uint64](3),cast[uint64](4),cast[uint64](5))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n"),
        # An augmented assign to an operand (`a += ...`) writes `a` between uses.
        ("aug_write",
         PRELUDE +
         "def f(a: uint64, b: uint64, c: uint64) -> uint64:\n"
         "    x: uint64 = a * b + c\n"
         "    a = a + b\n"
         "    y: uint64 = a * b + c\n"
         "    return x + y\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    g_accum = f(cast[uint64](3),cast[uint64](4),cast[uint64](5))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n"),
        # ALIASING STORE between two reads of `buf[i]` -> an indexed (opaque)
        # store is a HARD BARRIER, so the second `buf[i]` must NOT be shared
        # from the first even though the names `buf`/`i` are not (by-name)
        # written. The store `buf[i] = ...` changes the loaded value; sharing
        # would be a miscompile. (Both reads are IR_LEAF; the barrier flush is
        # what keeps this sound, NOT the by-name kill.)
        ("alias_store_between",
         PRELUDE +
         "abuf: Array[8, uint64]\n"
         "def f(i: uint64, k: uint64) -> uint64:\n"
         "    abuf[cast[int64](i)] = k\n"
         "    x: uint64 = abuf[cast[int64](i)] * k\n"
         "    abuf[cast[int64](i)] = k + cast[uint64](7)\n"
         "    y: uint64 = abuf[cast[int64](i)] * k\n"
         "    return x + y\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    g_accum = f(cast[uint64](2),cast[uint64](5))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n"),
    ]


# --------------------------------------------------------------------------
# LICM-SAFETY cases — the loop body contains a computation that LOOKS
# loop-invariant but is UNSAFE to hoist above the loop guard. LICM must NOT
# hoist it (licm counter MUST stay 0 for that expression class) AND the program
# must run identically with --opt OFF and ON. These are the task's hard
# zero-trip / aliasing safety requirements:
#   (b) a CONDITIONAL store inside the loop that may change an operand of an
#       otherwise-invariant expression -> the body is not provably invariant,
#       and an opaque store makes LICM give up entirely.
#   (c) a DIVIDE whose divisor is loop-invariant but could be 0: hoisting it
#       above a zero-trip guard would trap where the original never executes.
#   (c') a LOAD (buf[k]) that is loop-invariant by name but could FAULT /
#        alias: hoisting it above the guard could fault on a zero-trip loop.
# Each entry: (name, body-with-main, expect_licm) — expect_licm is the MAX
# allowed LICM count (0 = nothing from the unsafe class may hoist).
# --------------------------------------------------------------------------
def licm_safety_corpus():
    return [
        # (b) CONDITIONAL STORE through an index inside the loop. The store is an
        # opaque (non-ident-target) write -> licm_collect_clobbers sets giveup,
        # so NOTHING in this body hoists. Critically `sbuf[0]` feeds the sum and
        # is mutated under a condition, so a naive "k*m is invariant, hoist it"
        # is fine ONLY because the result is verified identical; the assertion is
        # that the conditional aliasing store does not corrupt anything and LICM
        # does not hoist across it.
        ("licm_cond_store",
         PRELUDE +
         "sbuf: Array[4, uint64]\n"
         "def hot(n: uint64, k: uint64, m: uint64) -> uint64:\n"
         "    sbuf[0] = cast[uint64](0)\n"
         "    i: uint64 = cast[uint64](0)\n"
         "    while i < n:\n"
         "        t: uint64 = k * m\n"
         "        if i > cast[uint64](2):\n"
         "            sbuf[0] = sbuf[0] + t\n"
         "        i = i + cast[uint64](1)\n"
         "    return sbuf[0]\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    g_accum = hot(cast[uint64](6),cast[uint64](3),cast[uint64](4))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         0),
        # (c) DIVIDE with a loop-invariant-but-possibly-zero divisor, in a loop
        # that may run ZERO times. `d` is invariant, but `n / d` must NOT hoist
        # above the guard: on a zero-trip loop the original never divides, so a
        # hoisted div by 0 would trap where the program would not. We drive it
        # with a NONZERO divisor (so both off/on produce a value), but the
        # SAFETY assertion is that LICM does not hoist the div tree at all
        # (ir_tree_has_div guard). expect_licm 0 = no div hoist.
        ("licm_div_guard",
         PRELUDE +
         "def hot(n: uint64, d: uint64) -> uint64:\n"
         "    s: uint64 = cast[uint64](0)\n"
         "    i: uint64 = cast[uint64](0)\n"
         "    while i < n:\n"
         "        q: uint64 = n / d\n"
         "        s = s + q + i\n"
         "        i = i + cast[uint64](1)\n"
         "    return s\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    g_accum = hot(cast[uint64](5),cast[uint64](2))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         0),
        # (c') A LOAD (buf[k]) that is loop-invariant by name but could FAULT or
        # alias. LICM must NOT hoist an opaque read leaf above the guard
        # (ir_tree_has_leaf guard). expect_licm 0 = no leaf hoist.
        ("licm_load_guard",
         PRELUDE +
         "lbuf: Array[8, uint64]\n"
         "def hot(n: uint64, k: uint64) -> uint64:\n"
         "    lbuf[cast[int64](k)] = cast[uint64](11)\n"
         "    s: uint64 = cast[uint64](0)\n"
         "    i: uint64 = cast[uint64](0)\n"
         "    while i < n:\n"
         "        v: uint64 = lbuf[cast[int64](k)] + i\n"
         "        s = s + v\n"
         "        i = i + cast[uint64](1)\n"
         "    return s\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    g_accum = hot(cast[uint64](4),cast[uint64](3))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         0),
    ]


# --------------------------------------------------------------------------
# BENCHMARK — a hot loop combining a loop-invariant subexpression (LICM hoists
# `k*m+c` to the pre-header) with a cross-statement repeated subexpression
# (`(a+b)*(a+b)` shared across the two body statements by Phase-7 CSE). With
# --opt ON the per-iteration work drops, so the DYNAMIC instruction count falls
# while the result stays seed-identical.
# --------------------------------------------------------------------------
BENCH_N = 50


def bench_body():
    return (PRELUDE +
            "def hot(n: uint64, a: uint64, b: uint64, k: uint64, m: uint64, "
            "c: uint64) -> uint64:\n"
            "    s: uint64 = cast[uint64](0)\n"
            "    i: uint64 = cast[uint64](0)\n"
            "    while i < n:\n"
            "        p: uint64 = (a + b) * (a + b) + k * m + c\n"
            "        q: uint64 = (a + b) * (a + b) + i\n"
            "        s = s + p + q\n"
            "        i = i + cast[uint64](1)\n"
            "    return s\n"
            "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
            f"    g_accum = hot(cast[uint64]({BENCH_N}), cast[uint64](3), "
            "cast[uint64](4), cast[uint64](5), cast[uint64](6), cast[uint64](2))\n"
            "    print_u64(g_accum)\n"
            "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n")


def run():
    ok = True

    # ---- POSITIVE: must fire + match ----
    print("[xcse] positive (cross-statement CSE must fire):")
    for name, decls, callexpr, min_cse in positive_corpus():
        body = main_wrap(decls, callexpr)
        off = build_and_run(name, body, opt=False)
        on = build_and_run(name, body, opt=True)
        if off is None or on is None:
            print(f"  [{name}] codegen.ad rejected (off={off} on={on})")
            ok = False
            continue
        # OFF must be byte-inert: no CSE accounted with the flag off.
        if off.dump.cse != 0:
            print(f"  [{name}] OFF NOT inert: CSE={off.dump.cse}")
            ok = False
        if off.out != on.out or off.exit != on.exit:
            print(f"  [{name}] MISCOMPILE off=({off.out},{off.exit}) "
                  f"on=({on.out},{on.exit})")
            ok = False
            continue
        if on.dump.cse < min_cse:
            print(f"  [{name}] CSE under-fired: got {on.dump.cse} want >= "
                  f"{min_cse}")
            ok = False
            continue
        print(f"  [{name}] OK out={on.out} CSE={on.dump.cse} "
              f"code_len {off.dump.code_len}->{on.dump.code_len}")

    # ---- NEGATIVE: must NOT fire + still match ----
    print("[xcse] negative (write/barrier between uses -> must NOT share):")
    for name, body in negative_corpus():
        off = build_and_run(name, body, opt=False)
        on = build_and_run(name, body, opt=True)
        if off is None or on is None:
            print(f"  [{name}] codegen.ad rejected")
            ok = False
            continue
        if off.out != on.out or off.exit != on.exit:
            print(f"  [{name}] MISCOMPILE off=({off.out},{off.exit}) "
                  f"on=({on.out},{on.exit})")
            ok = False
            continue
        if on.dump.cse != 0:
            print(f"  [{name}] UNSAFE SHARE: CSE={on.dump.cse} across a "
                  f"write/barrier (must be 0)")
            ok = False
            continue
        print(f"  [{name}] OK out={on.out} CSE=0 (correctly not shared)")

    # ---- LICM SAFETY: trapping/aliasing ops must NOT hoist above the guard ----
    print("[xcse] licm-safety (cond-store / div / load must NOT hoist):")
    for name, body, max_licm in licm_safety_corpus():
        off = build_and_run(name, body, opt=False)
        on = build_and_run(name, body, opt=True)
        if off is None or on is None:
            print(f"  [{name}] codegen.ad rejected")
            ok = False
            continue
        if off.out != on.out or off.exit != on.exit:
            print(f"  [{name}] MISCOMPILE off=({off.out},{off.exit}) "
                  f"on=({on.out},{on.exit})")
            ok = False
            continue
        if on.dump.licm > max_licm:
            print(f"  [{name}] UNSAFE HOIST: LICM={on.dump.licm} > "
                  f"{max_licm} (trapping/aliasing op hoisted above guard)")
            ok = False
            continue
        print(f"  [{name}] OK out={on.out} LICM={on.dump.licm} "
              f"(no unsafe hoist)")

    # ---- BENCHMARK: measurable dynamic-instruction win ----
    print("[xcse] benchmark (hot loop, LICM + cross-statement CSE):")
    body = bench_body()
    off = build_and_run("bench", body, opt=False, want_icount=True)
    on = build_and_run("bench", body, opt=True, want_icount=True)
    if off is None or on is None:
        print("  bench: codegen.ad rejected")
        ok = False
    else:
        if off.out != on.out or off.exit != on.exit:
            print(f"  bench MISCOMPILE off=({off.out},{off.exit}) "
                  f"on=({on.out},{on.exit})")
            ok = False
        print(f"  result (seed-identical): off={off.out} on={on.out}")
        print(f"  counters --opt ON: CSE={on.dump.cse} LICM={on.dump.licm} "
              f"IREMIT={on.dump.iremit}")
        print(f"  DYNAMIC instructions: OFF={off.icount}  ON={on.icount}")
        if off.icount > 0:
            pct = 100.0 * (off.icount - on.icount) / off.icount
            print(f"  --> {off.icount} -> {on.icount}  ({pct:.1f}% fewer "
                  f"dynamic instructions)")
        # Require the optimizer ACTUALLY fired both transforms and reduced work.
        if on.dump.cse < 1 or on.dump.licm < 1:
            print("  bench FAIL: expected both cross-stmt CSE and LICM to fire")
            ok = False
        if on.icount >= off.icount:
            print("  bench FAIL: --opt did not reduce dynamic instruction count")
            ok = False

    print()
    print("[xcse] " + ("PASS" if ok else "FAIL"))
    return ok


if __name__ == "__main__":
    sys.exit(0 if run() else 1)
