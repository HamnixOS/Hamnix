#!/usr/bin/env bash
# scripts/test_subword_access.sh — comprehensive sub-8-byte sized-access
# regression for the native `.ad` backend (compiler/codegen.ad), host-only
# (NO QEMU).
#
# Pins the WHOLE class of sub-8-byte sized load/store bugs against the frozen
# Python seed (codegen_x86.py): a sub-8-byte scalar must be STORED sized
# (movb/movw/movl — truncate, no high-garbage) and LOADED with the correct
# extension (sign-extend a SIGNED narrow value into the 64-bit register,
# zero-extend an UNSIGNED one). The two store paths (named-local store,
# parameter spill) were fixed earlier; this gate additionally pins the LOAD
# paths — in particular the INDEX load of a signed element from a NAMED ARRAY
# (local or global), which previously ZERO-extended a signed sub-8-byte
# element where the seed sign-extends (`index_elem_signed` only handled the
# cast/member base, returning 0 for a named-array base). That is the same
# load-extension miscompile class as the store fixes: the wide value's high
# bits diverge (e.g. -9 read as 0x00000000FFFFFFF7 instead of
# 0xFFFFFFFFFFFFFFF7), which downstream drives a bogus size / pointer / branch.
#
# The fixture (tests/fuzz/regress_subword_access.ad) drives a signed NEGATIVE
# value through every sub-8-byte read path (scalar-global, array-global,
# array-local, struct-member, cast[Ptr[int32]]) and XOR-mixes each 64-bit
# register value's HIGH bytes into the exit code, so a sign- vs zero-extension
# divergence in ANY path changes the result. The harness asserts the `.ad`
# backend's exit equals the seed's (the seed is the oracle — NOT a hardcoded
# constant), so it stays valid if the oracle value ever legitimately shifts.
#
# Usage:  bash scripts/test_subword_access.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[subword-access] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/fuzz/regress_subword_access.ad"
[ -f "$FIX" ] || fail "missing fixture $FIX"
WORK="build/subword_access"
mkdir -p "$WORK"

echo "[subword-access] (1/2) seed oracle: compile + run the fixture"
SEED_SRC="$WORK/fixture.ad"
cp "$FIX" "$SEED_SRC"
python3 -m compiler.adder compile --target=x86_64-linux "$SEED_SRC" \
    -o "$WORK/fixture_seed" >/dev/null 2>"$WORK/seed.cerr" \
    || { cat "$WORK/seed.cerr"; fail "seed failed to compile the fixture"; }
"$WORK/fixture_seed"; SEED_EXIT=$?
echo "[subword-access]   seed exit = $SEED_EXIT (the oracle)"
# Sanity: a degenerate all-zero exit would mean nothing is being exercised.
[ "$SEED_EXIT" -ne 0 ] || fail "seed oracle exit 0 — fixture not exercising any path?"

echo "[subword-access] (2/2) codegen.ad must match the seed exit"
AD_OUT="$(python3 - "$FIX" <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
# Force a driver rebuild so the CURRENT codegen.ad is what runs.
h.build_driver(force=True)
body = open(sys.argv[1]).read()
r = h.run_through_codegen_ad("subword_regress", body, Path("build/subword_access"))
print(f"{r.kind} {r.exit}")
PY
)" || fail "codegen.ad harness errored: $AD_OUT"
echo "[subword-access]   codegen.ad result = $AD_OUT (expect 'ok $SEED_EXIT')"
[ "$AD_OUT" = "ok $SEED_EXIT" ] \
    || fail "codegen.ad sub-8-byte access diverged from seed: $AD_OUT != 'ok $SEED_EXIT' (a sized load/store extension mismatch)"

echo "[subword-access] PASS"
