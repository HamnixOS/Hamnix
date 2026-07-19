#!/usr/bin/env bash
# scripts/test_opt_cmpstore.sh — focused, host-only regression guard for the
# ADDER_OPT=1 COMPARE-INTO-REGISTER-HOME miscompile (the bug that blocked the
# --opt bare-metal KERNEL from compiling: `[host_ac] FAIL: codegen error
# reason=1` — an emit_alu_* cg_fail fallthrough).
#
# THE BUG. The destination-driven selector (codegen.ad try_sel_assign_name ->
# sel_expr_into_reg -> sel_combine_into_home) computes a `name = <pure binop>`
# RHS directly into name's promoted callee-saved register with 2-operand
# `op <right>, %r` forms (emit_alu_reg_reg / emit_alu_imm_reg / emit_alu_mem_reg).
# Those helpers implement ONLY the plain arith/bitwise ops (ADD/SUB/MUL/AND/OR/
# XOR). The routing gate `sel_binop_routable` reused `ir_op_scratch_ok` to decide
# what to route — but ir_op_scratch_ok ALSO admits the 6 comparison ops (EQ/NEQ/
# LT/LTE/GT/GTE), which are fine for gen_expr_ir's %rax scratch schedule (it
# materialises the boolean with cmp+setcc) but have NO emit_alu_* form. So a
# comparison stored into a full-width register-promoted integer local — as a
# ROOT (`flag = a < b`) or NESTED under an arith op (`x = (a<b) + c`) — reached
# emit_alu_*'s cg_fail and ABORTED codegen. The kernel contains exactly this
# shape (init/main.ad merged line 1543), so `--opt` could not build the kernel.
# The differential fuzzer never generated `int64_local = <compare>`, so it
# passed 500/500 while the kernel would not compile.
#
# THE FIX. sel_binop_routable now uses a dedicated arith-ONLY predicate
# (ir_op_arith_ok = ADD/SUB/MUL/AND/OR/XOR), so a comparison node (root or
# nested) is treated as a LEAF and emitted by gen_expr_ir (cmp+setcc into %rax,
# then moved to the home) — the exact byte-for-byte-with-the-seed path. Div/mod/
# shift were already excluded and stay so.
#
# WHAT THIS PROVES (no QEMU): each compare-into-local shape (1) COMPILES under
# --opt (no cg_fail), and (2) produces the SAME observable result as WITHOUT
# --opt and as the hand-computed reference.
#
# HOST-ONLY: python3 + as/ld + gcc, x86_64. The cached dump driver under
# build/fuzz_ad_codegen AUTO-INVALIDATES on any compiler-source change.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_cmpstore"); WD.mkdir(parents=True, exist_ok=True)

CASES = []

# 1. THE minimal kernel-shaped repro: a comparison stored to a full-width
#    register-promoted int64 local (padded with a live temp so the local is
#    register-promoted), read after. reason=101 aborted codegen before the fix.
CASES.append(("cmp_root_lt", """
def f(a: int64, b: int64) -> int64:
    t: int64 = a * b + 1
    r: int64 = 0
    r = a < b
    return r + t - t

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    return cast[int32]((f(3, 7) + f(9, 2) * 2) & 255)
""", 1))  # f(3,7)=1, f(9,2)=0 -> 1 + 0*2 = 1

# 2. every comparison operator stored into a reused promoted local, summed.
CASES.append(("cmp_all_ops", """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    x: int64 = 5
    y: int64 = 9
    s: int64 = 0
    t: int64 = 0
    t = x < y
    s = s + t
    t = x > y
    s = s + t
    t = x == y
    s = s + t
    t = x != y
    s = s + t
    t = x <= y
    s = s + t
    t = x >= y
    s = s + t
    return cast[int32](s & 255)
""", 3))  # <:1 >:0 ==:0 !=:1 <=:1 >=:0 -> 3

# 3. a comparison NESTED under an arith op, routed into a register home.
CASES.append(("cmp_nested_in_add", """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: int64 = 1
    b: int64 = 2
    c: int64 = 5
    d: int64 = 3
    r: int64 = 0
    r = (a < b) + (c > d)
    return cast[int32](r & 255)
""", 2))  # (1<2)=1 + (5>3)=1 = 2

# 4. compare stored to a loop-carried (definitely register-promoted) local.
CASES.append(("cmp_in_loop", """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: int64 = 0
    i: int64 = 0
    while i < 10:
        b: int64 = 0
        b = i < 5
        s = s + b
        i = i + 1
    return cast[int32](s & 255)
""", 5))  # i in 0..4 give 1 -> 5

# 5. unsigned comparison stored into a register home (signedness-correct jcc/setcc).
CASES.append(("cmp_unsigned", """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: uint64 = cast[uint64](3)
    b: uint64 = cast[uint64](7)
    r: int64 = 0
    r = cast[int64](a < b)
    q: int64 = 0
    q = cast[int64](a > b)
    return cast[int32](((r * 10) + q) & 255)
""", 10))  # a<b:1 a>b:0 -> 10

fails = 0
for name, src, expected in CASES:
    r_on = h.run_through_codegen_ad(name, src, WD, opt=True)
    r_off = h.run_through_codegen_ad(name, src, WD, opt=False)
    ok = (r_on.kind == "ok" and r_off.kind == "ok"
          and r_on.exit == expected and r_off.exit == expected)
    status = "OK" if ok else "FAIL"
    if not ok:
        fails += 1
    print(f"[{name}] {status}  on_exit={getattr(r_on,'exit',None)} "
          f"off_exit={getattr(r_off,'exit',None)} expected={expected} "
          f"kind_on={r_on.kind} kind_off={r_off.kind}")

print("=" * 56)
if fails == 0:
    print("[opt_cmpstore] PASS — comparison-into-register-home compiles and "
          "runs correctly under --opt (sel_binop_routable arith-only fix holds)")
    sys.exit(0)
else:
    print(f"[opt_cmpstore] FAIL — {fails} compare-store case(s) diverged/aborted "
          "under --opt")
    sys.exit(1)
PY
