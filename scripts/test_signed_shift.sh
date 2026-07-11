#!/usr/bin/env bash
# scripts/test_signed_shift.sh — revert-sensitive static check for the SIGNED
# right-shift (`>>`) codegen bug, host-only (NO QEMU). Pins BOTH backends:
# the frozen Python seed (compiler/codegen_x86.py) and the self-hosted native
# backend (compiler/codegen.ad).
#
# THE BUG: `>>` picked arithmetic (sarq) vs logical (shrq) from BOTH operands'
# signedness. But a shift's signedness is a property of the shifted VALUE (the
# LEFT operand) ALONE — the COUNT's type is irrelevant in C. So a signed value
# shifted by an UNSIGNED count, or reached through an array element / integer
# sub-expression the type resolver reported "unknown", wrongly emitted the
# LOGICAL shrq (zero-fill instead of sign-fill), corrupting every negative
# intermediate (this broke the ed25519 field/scalar reductions).
#
# THE FIXTURE (tests/fuzz/regress_signed_shift.ad) right-shifts the SAME
# negative int64 through every previously-miscompiled operand form (array
# element, integer sub-expression, function parameter, uint64 count) and
# compares each against a REFERENCE arithmetic shift; it returns 0 iff every
# form sign-extended, 1 if any zero-filled. So this asserts the actual
# SIGN-EXTENDING RUNTIME behaviour (NOT merely seed==native — both shared the
# bug): revert either backend's fix and its exit flips to 1 and this gate fails.
#
# Usage:  bash scripts/test_signed_shift.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[signed-shift] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/fuzz/regress_signed_shift.ad"
[ -f "$FIX" ] || fail "missing fixture $FIX"
WORK="build/signed_shift"
mkdir -p "$WORK"

echo "[signed-shift] (1/2) seed: signed-operand >> must sign-extend for every form"
python3 -m compiler.adder compile --target=x86_64-linux "$FIX" \
    -o "$WORK/fixture_seed" >/dev/null 2>"$WORK/seed.cerr" \
    || { cat "$WORK/seed.cerr"; fail "seed failed to compile the fixture"; }
"$WORK/fixture_seed"; SEED_EXIT=$?
echo "[signed-shift]   seed exit = $SEED_EXIT (expect 0)"
[ "$SEED_EXIT" -eq 0 ] \
    || fail "seed emitted a LOGICAL shr for a signed operand (array/subexpr/param/uint64-count) — negative values zero-filled instead of sign-extending"

echo "[signed-shift] (2/2) codegen.ad must sign-extend too (default AND --opt paths)"
AD_OUT="$(python3 - "$FIX" <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
h.build_driver(force=True)
body = open(sys.argv[1]).read()
bad = 0
for opt in (False, True):
    r = h.run_through_codegen_ad("signed_shift", body, Path("build/signed_shift"), opt=opt)
    tag = "opt" if opt else "default"
    print(f"{tag} {r.kind} {r.exit}")
    if not (r.kind == "ok" and r.exit == 0):
        bad = 1
sys.exit(bad)
PY
)"; AD_RC=$?
echo "$AD_OUT" | sed 's/^/[signed-shift]   codegen.ad /'
[ "$AD_RC" -eq 0 ] \
    || fail "codegen.ad emitted a LOGICAL shr for a signed operand (see line above) — a sar-vs-shr divergence from the fixed seed"

echo "[signed-shift] PASS"
