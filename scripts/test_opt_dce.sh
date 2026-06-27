#!/usr/bin/env bash
# scripts/test_opt_dce.sh — focused, host-only correctness + firing test for the
# native optimizer's Phase-8 Dead Code Elimination pass (opt.ad opt_dce_function).
#
# WHAT IT PROVES (no QEMU):
#   1. The DCE pass FIRES: with --opt ON, the dump driver's DCE counter is > 0
#      over a corpus of programs that each contain a provably-dead local.
#   2. The pass is CORRECT: each program, run through codegen.ad with --opt ON,
#      produces the SAME observable result (exit status / stdout) as the seed
#      oracle (codegen_x86.py) — i.e. removing the dead locals changed nothing.
#   3. The barrier holds: a program whose dead-looking local is kept alive by an
#      address-of / call removes NOTHING (DCE=0 for that unit).
#
# This is a targeted complement to the broad ADDER_OPT=1 fuzzer lane
# (scripts/fuzz_adder_diff.sh), which asserts behavioral identity across a
# random corpus; here we hand-craft the dead-local shapes so the counter is
# guaranteed to move and the per-shape semantics are pinned to a known answer.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_dce"); WD.mkdir(parents=True, exist_ok=True)

# Each case: (name, source, expected_exit, expect_dce_fires)
# The program's exit status is the observable. A dead local must NOT change it.
CASES = []

# 1. Plain dead local: computed, never read.
CASES.append(("dead_simple", """
def main() -> int:
    x: int = 5 + 3
    y: int = 41
    return y
""", 41, True))

# 2. Dead local whose init is itself pure arithmetic over other locals.
CASES.append(("dead_arith", """
def main() -> int:
    a: int = 7
    b: int = 6
    dead: int = a * b + 2
    return a + b
""", 13, True))

# 3. Fixpoint: dead2's only use is in dead1's init; removing dead1 frees dead2.
#    (dead1 is read nowhere; dead2 is read only by dead1.) Both must vanish.
CASES.append(("dead_chain", """
def main() -> int:
    keep: int = 9
    dead2: int = keep + 1
    dead1: int = dead2 * 2
    return keep
""", 9, True))

# 4. NOT dead: y is read in the return, so it must be kept (DCE may still fire on
#    nothing here -> we only assert correctness, not firing).
CASES.append(("live_local", """
def main() -> int:
    y: int = 20 + 2
    return y
""", 22, False))

# 5. Barrier: address-of a local disables DCE for the whole function. The
#    "dead" local must be KEPT (DCE=0) and the result still correct.
CASES.append(("barrier_addr", """
def main() -> int:
    z: int = 4
    p: Ptr[int] = &z
    dead: int = 99
    return z
""", 4, False))

total_dce = 0
fired_units = 0
fails = 0
for name, src, expected, expect_fire in CASES:
    # codegen.ad WITH --opt ON (DCE active); carries the per-run DCE count.
    r_opt = h.run_through_codegen_ad(name, src, WD, opt=True)
    # codegen.ad with --opt OFF (baseline behavior; objdiff-proven == seed).
    r_off = h.run_through_codegen_ad(name, src, WD, opt=False)

    ok_kind = (r_opt.kind == "ok") and (r_off.kind == "ok")
    same_exit = (r_opt.exit == expected) and (r_off.exit == expected)
    # The opt and off runs must agree (opt changed nothing observable).
    agree = (r_opt.exit == r_off.exit) and (r_opt.stdout == r_off.stdout)

    dce = getattr(r_opt, "dce", 0) if r_opt.kind == "ok" else -1

    if dce > 0:
        fired_units += 1
        total_dce += dce

    status = "OK"
    if not (ok_kind and same_exit and agree):
        status = "FAIL"
        fails += 1
    if expect_fire and dce <= 0:
        status = "FAIL(no-fire)"
        fails += 1
    if (not expect_fire) and name.startswith("barrier") and dce != 0:
        status = "FAIL(barrier-leaked)"
        fails += 1

    print(f"[{name}] {status}  opt_exit={r_opt.exit} off_exit={r_off.exit} "
          f"expected={expected} DCE={dce}")

print("=" * 50)
print(f"[opt_dce] units that fired DCE: {fired_units}   total DCE removals: {total_dce}")
if fails == 0:
    print("[opt_dce] PASS — DCE fires and is behavior-preserving")
    sys.exit(0)
else:
    print(f"[opt_dce] FAIL — {fails} problem(s)")
    sys.exit(1)
PY
