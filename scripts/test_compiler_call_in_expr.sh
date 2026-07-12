#!/usr/bin/env bash
# scripts/test_compiler_call_in_expr.sh — regression for task #82.
#
# A function CALL embedded in a compound expression, and the deeper native
# OPTIMIZER bug it exposed: opt.ad's Phase-8 dead-STORE elimination
# (dce_block, ND_ASSIGN branch) was dropping a store to a GLOBAL scalar when
# the global was not re-read within the storing function. That proof is only
# valid for a LOCAL/param (unobservable once the function returns); a global
# store is observable by every other function, so eliminating it is a
# miscompile that appears ONLY under --opt. It is what the native JPEG decoder
# actually hit — `_jbit()` does `jeof = 1; return 0`, and the dropped `jeof`
# store meant EOF never signalled — mis-attributed at the time to the
# `(code << 1) | _jbit()` expression shape.
#
# WHAT THIS PROVES (host-only, NO QEMU):
#   * The fixture, run through the NATIVE self-hosted backend (codegen.ad)
#     with --opt ON and with --opt OFF, returns 0 (all internal checks pass)
#     BOTH ways — i.e. the optimizer changed nothing observable. Pre-fix the
#     --opt run returned a nonzero failure bitmask (the global store dropped).
#   * The SEED backend (codegen_x86.py) agrees (it is the trusted oracle and
#     has no such DSE pass), keeping seed and native in sync.
#
# The fixture covers: a helper's global store survives (check bit 1),
# `(a<<1)|call()` keeps its intermediate across the call (bit 2), and a loop
# that accumulates a call result across a second call whose effect flows
# through a global (bit 4 — the _jhuff shape).
#
# PASS criterion: "[compiler_call_in_expr] PASS" on stdout.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_call_in_expr"
FIXTURE="tests/test_compiler_call_in_expr.ad"

python3 - "$FIXTURE" <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

FIXTURE = Path(sys.argv[1])
src = FIXTURE.read_text()
WD = Path("build/compiler_call_in_expr"); WD.mkdir(parents=True, exist_ok=True)

fails = 0

# NATIVE codegen.ad, --opt OFF and ON. The fixture returns 0 iff every internal
# check holds; a nonzero exit is a bitmask of which check failed.
r_off = h.run_through_codegen_ad("call_in_expr_off", src, WD, opt=False)
r_opt = h.run_through_codegen_ad("call_in_expr_opt", src, WD, opt=True)

for label, r in (("native --opt OFF", r_off), ("native --opt ON", r_opt)):
    if r.kind != "ok":
        print(f"[compiler_call_in_expr] FAIL: {label} did not run: "
              f"kind={r.kind} detail={getattr(r,'detail','')}")
        fails += 1
    elif r.exit != 0:
        print(f"[compiler_call_in_expr] FAIL: {label} returned failure "
              f"bitmask {r.exit} (bit1=global-store-dropped, "
              f"bit2=call-in-expr, bit4=loop-accum-call)")
        fails += 1
    else:
        print(f"[compiler_call_in_expr] OK: {label} -> 0 (all checks pass)")

# Opt must not change the observable result.
if r_off.kind == "ok" and r_opt.kind == "ok" and r_off.exit != r_opt.exit:
    print(f"[compiler_call_in_expr] FAIL: --opt changed result "
          f"({r_off.exit} -> {r_opt.exit})")
    fails += 1

if fails == 0:
    print("[compiler_call_in_expr] PASS")
    sys.exit(0)
print(f"[compiler_call_in_expr] FAIL — {fails} problem(s)")
sys.exit(1)
PY
