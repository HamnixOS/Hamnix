#!/usr/bin/env bash
# scripts/test_opt_scor_storeelim.sh — focused, host-only regression gate for the
# SHORT-CIRCUIT-`or` × STORE-ELIMINATION register-clobber miscompile (fuzzer seed
# 1000413, --opt / ADDER_OPT=1 native lane).
#
# ROOT CAUSE (codegen.ad). The --opt store-elimination peephole in store_to_named
# retargets a trailing `mov $imm,%rax` DIRECTLY into a register-promoted local's
# home register (dropping the redundant `mov %rax,%reg`) whenever cg_imm_rax_valid
# is armed. That peephole is only sound when the trailing imm-load is the SOLE
# producer of the stored value. The short-circuit `or` value lowering
# (gen_binary, BINOP_OR) emits its 0/1 result via a CONTROL-FLOW MERGE of two
# producers:
#     <branch-if-true L -> true>; <branch-if-true R -> true>
#     xor %eax,%eax ; jmp end          # FALSE path -> %rax = 0
#   true: mov $1,%rax                   # TRUE  path -> %rax = 1  (arms the peephole)
#   end:
# The trailing emit is the true-path `mov $1,%rax`, so cg_imm_rax_valid stayed
# armed. store_to_named then retargeted ONLY that true-path imm-load into the
# promoted register (e.g. `mov $1,%r13`) and dropped the copy — leaving the FALSE
# path still writing %rax. On the both-false path the promoted destination was
# NEVER written, so it kept its STALE prior value:
#     r = 23                            # prior value, promoted to %r13
#     r = (a >= 0) or (b > 1)           # both false -> should be 0, but %r13 == 23
# `and` was unaffected: its trailing emit is `jmp`+`xor`, and the `jmp` byte-emit
# already cleared cg_imm_rax_valid, so the peephole never fired for `and`.
#
# THE FIX: the BINOP_OR (and, defensively, BINOP_AND) short-circuit lowering
# clears cg_imm_rax_valid before returning — the merged result is not a
# sole-producer imm-load, so store_to_named falls back to a correct `mov %rax,%reg`
# that captures BOTH merge paths. --opt-only (the peephole is gated on the
# store-elim path); default (flag-OFF) codegen is byte-identical.
#
# WHAT IT PROVES (no QEMU): each program run through codegen.ad with --opt ON
# yields the SAME exit as --opt OFF AND the known answer. The both-false `or`
# cases are the miscompile repro (stale register instead of 0).
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

WD = Path("build/opt_scor_storeelim"); WD.mkdir(parents=True, exist_ok=True)

# (name, source, expected_exit). Each `f` first assigns a NON-ZERO value to the
# result local (so it is promoted to a register that then holds a stale value),
# then re-assigns it from a short-circuit boolean whose value is 0/1.
CASES = []

# 1. THE REPRO — `or` with BOTH operands false. Stale 23; correct 0.
CASES.append(("or_both_false", """
def f(a: int64, b: int64) -> uint64:
    r: uint64 = cast[uint64](23)
    r = cast[uint64]((a >= cast[int64](0)) or (b > cast[int64](1)))
    return r
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    return cast[int32](f(cast[int64](0) - cast[int64](1), cast[int64](0) - cast[int64](1)))
""", 0))

# 2. `or` FIRST operand true -> 1 (true path must still land 1 in the reg).
CASES.append(("or_first_true", """
def f(a: int64, b: int64) -> uint64:
    r: uint64 = cast[uint64](23)
    r = cast[uint64]((a >= cast[int64](0)) or (b > cast[int64](1)))
    return r
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    return cast[int32](f(cast[int64](5), cast[int64](0)))
""", 1))

# 3. `or` SECOND operand true -> 1.
CASES.append(("or_second_true", """
def f(a: int64, b: int64) -> uint64:
    r: uint64 = cast[uint64](23)
    r = cast[uint64]((a >= cast[int64](0)) or (b > cast[int64](1)))
    return r
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    return cast[int32](f(cast[int64](0) - cast[int64](1), cast[int64](5)))
""", 1))

# 4. `and` both true -> 1 (control: the sibling lowering must stay correct).
CASES.append(("and_both_true", """
def f(a: int64, b: int64) -> uint64:
    r: uint64 = cast[uint64](23)
    r = cast[uint64]((a >= cast[int64](0)) and (b > cast[int64](1)))
    return r
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    return cast[int32](f(cast[int64](0), cast[int64](5)))
""", 1))

# 5. `and` false (first operand false) -> 0 stale-check.
CASES.append(("and_first_false", """
def f(a: int64, b: int64) -> uint64:
    r: uint64 = cast[uint64](23)
    r = cast[uint64]((a >= cast[int64](0)) and (b > cast[int64](1)))
    return r
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    return cast[int32](f(cast[int64](0) - cast[int64](1), cast[int64](5)))
""", 0))

fails = 0
for name, src, exp in CASES:
    ron = h.run_through_codegen_ad(name, src, WD, opt=True)
    roff = h.run_through_codegen_ad(name + "_o", src, WD, opt=False)
    if ron.kind != "ok" or roff.kind != "ok":
        print(f"[scor_storeelim] {name}: DID NOT RUN opt={ron.kind} noopt={roff.kind}")
        fails += 1
        continue
    ok = (ron.exit == exp) and (roff.exit == exp) and (ron.exit == roff.exit)
    tag = "PASS" if ok else "FAIL"
    print(f"[scor_storeelim] {tag} {name}: opt_exit={ron.exit} noopt_exit={roff.exit} expect={exp}")
    if not ok:
        fails += 1

if fails:
    print(f"[scor_storeelim] FAIL: {fails} case(s) — short-circuit-or store-elim clobber is back")
    sys.exit(1)
print("[scor_storeelim] PASS: all short-circuit-or/and store-elim cases correct")
PY
