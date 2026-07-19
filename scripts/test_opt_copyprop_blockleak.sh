#!/usr/bin/env bash
# scripts/test_opt_copyprop_blockleak.sh — focused, host-only regression gate for
# the Phase-9 Copy-Propagation NESTED-BLOCK ACTIVE-SET LEAK miscompile.
#
# ROOT CAUSE (opt.ad cp_block): the active-copy set (cp_* arrays + cp_n) is a
# SINGLE module-global shared across every recursive cp_block frame. cp_block
# recurses into a nested control-flow body (while / if / for) to clean it, and the
# nested frame REPOPULATES the shared set with the nested block's copies, returning
# with it non-empty. A control-flow statement is itself a hard barrier, so no copy
# may survive it into the rest of the PARENT run — but the old code did NOT re-clear
# the shared set after the recursion, so a copy recorded at the TAIL of the nested
# block (e.g. `lhs = n` at the end of a `while` body) LEAKED into the parent run and
# wrongly forwarded a later read of the copy DEST (`return lhs` -> `return n`).
#
# THE LIVE BUG: hamsh's parse_or,
#     lhs = parse_and()
#     while <OP_OR>:
#         ...; n = nd_new(...); ...; lhs = n      # copy at while-body tail
#     return lhs
# When the loop ran zero times (any `or`-free expression — the common case) the
# leaked forward made `return lhs` read the UNINITIALISED `n`, yielding a wild AST
# node index whose downstream table lookup took a read #PF -> SIGSEGV in an early
# rc.boot child, wedging PID 1 before the desktop. Compiled --opt only; invisible
# to the differential fuzzer (it needs a copy at a nested-block tail followed by a
# parent-run read of the copy dest, a shape the fuzzer did not generate).
#
# WHAT IT PROVES (no QEMU): each program run through codegen.ad with --opt ON
# produces the SAME exit as --opt OFF (the objdiff==seed baseline) AND the known
# answer. The zero-iteration cases are the miscompile repro: the buggy leak returned
# the stale nested-block variable instead of the parent's live value.
#
# HOST-ONLY: python3 + the tests/fuzz ad_codegen_host harness. NO QEMU.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_copyprop_blockleak"); WD.mkdir(parents=True, exist_ok=True)

# (name, source, expected_exit)
CASES = []

# 1. THE REPRO — parse_or shape. A copy `lhs = n` at the TAIL of a while body,
#    then `return lhs` AFTER the loop. Called with the loop running ZERO times, so
#    the correct answer is the parent's `lhs` (100). The leaked forward rewrote the
#    return to read `n` (0) — the miscompile.
CASES.append(("while_tail_copy_zero_iters", """
def loopcopy(k: int) -> int:
    lhs: int = 100
    n: int = 0
    while k > 0:
        n = 7
        lhs = n
        k = k - 1
    return lhs

def main() -> int:
    return loopcopy(0)
""", 100))

# 2. CONTROL — same function, loop RUNS: lhs legitimately becomes n (7). Proves the
#    fix did not break the in-body copy semantics.
CASES.append(("while_tail_copy_runs", """
def loopcopy(k: int) -> int:
    lhs: int = 100
    n: int = 0
    while k > 0:
        n = 7
        lhs = n
        k = k - 1
    return lhs

def main() -> int:
    return loopcopy(3)
""", 7))

# 3. IF-block variant — copy at the tail of an `if` body, read after. k=0 skips the
#    body, so the answer is the parent's lhs (55); the leak would return n (0).
CASES.append(("if_tail_copy_skipped", """
def ifcopy(k: int) -> int:
    lhs: int = 55
    n: int = 0
    if k > 0:
        n = 9
        lhs = n
    return lhs

def main() -> int:
    return ifcopy(0)
""", 55))

# 4. Nested-block copy then a DIFFERENT parent read that must NOT be forwarded: the
#    parent reassigns lhs after the loop and returns it — the leaked copy must not
#    resurrect the nested source.
CASES.append(("while_tail_copy_then_parent_write", """
def f(k: int) -> int:
    lhs: int = 1
    n: int = 0
    while k > 0:
        n = 8
        lhs = n
        k = k - 1
    lhs = 42
    return lhs

def main() -> int:
    return f(0)
""", 42))

fails = 0
for name, src, expected in CASES:
    r_opt = h.run_through_codegen_ad(name, src, WD, opt=True)
    r_off = h.run_through_codegen_ad(name, src, WD, opt=False)
    ok_kind = (r_opt.kind == "ok") and (r_off.kind == "ok")
    same_exit = (r_opt.exit == expected) and (r_off.exit == expected)
    agree = (r_opt.exit == r_off.exit) and (r_opt.stdout == r_off.stdout)
    status = "OK"
    if not (ok_kind and same_exit and agree):
        status = "FAIL"
        fails += 1
    print(f"[{name}] {status}  opt_exit={getattr(r_opt,'exit',None)} "
          f"off_exit={getattr(r_off,'exit',None)} expected={expected} "
          f"opt_kind={r_opt.kind} off_kind={r_off.kind}")

print("=" * 50)
if fails == 0:
    print("[opt_copyprop_blockleak] PASS — no nested-block copy leaks into the parent run")
    sys.exit(0)
print(f"[opt_copyprop_blockleak] FAIL — {fails} case(s) miscompiled (copy leak regression)")
sys.exit(1)
PY
