#!/usr/bin/env bash
# scripts/fuzz_adder_diff.sh — DIFFERENTIAL gate for the self-hosted Adder
# backend (adder/compiler/codegen.ad) vs the trusted Python backend
# (adder/compiler/codegen_x86.py) + the by-construction oracle.
#
# WHY: codegen.ad is the Adder-in-Adder x86_64 backend (lexer.ad -> parser.ad
# -> codegen.ad). It normally only runs ON-DEVICE under QEMU. This gate runs it
# ENTIRELY ON THE HOST (no QEMU): a host driver ELF (tests/fuzz/
# ad_codegen_dump_driver.ad, compiled to --target=x86_64-linux) executes the
# codegen.ad pipeline on each fuzzer-generated program and dumps the raw
# machine-code + global-data bytes; tests/fuzz/ad_codegen_host.py wraps those
# bytes into a real x86_64-linux ELF (Linux exit_group stub) and runs it. The
# fuzzer's by-construction oracle (already validated against the Python
# backend) is the reference. A program codegen.ad ACCEPTED but ran with the
# WRONG answer is a genuine codegen.ad miscompile; a program codegen.ad cannot
# compile (e.g. 2-D array globals — outside its subset) is UNSUPPORTED, not a
# failure.
#
# It reports:
#   * accept-rate     = codegen.ad accepted / programs run
#   * correctness-rate= (accepted AND correct) / accepted
# and EXITS NONZERO ONLY on a genuine miscompile (codegen.ad accepted, wrong
# answer) or a primary (Python) backend disagreement with the oracle.
#
# HOST-ONLY: needs python3 + as/ld/gcc (binutils + a C driver to preprocess
# user/linux-runtime.S), an x86_64 host. NO QEMU, NO image build.
#
# Usage:
#   bash scripts/fuzz_adder_diff.sh                  # 500 programs, seed 1
#   FUZZ_COUNT=2000 bash scripts/fuzz_adder_diff.sh  # bigger soak
#   FUZZ_SEED=42 bash scripts/fuzz_adder_diff.sh     # different deterministic seed
#
# Deterministic/seeded: each program comes from a per-program seed derived from
# (FUZZ_SEED, index), so a failing program reproduces in isolation via
#   ADDER_FUZZ_DIFF_TARGET=ad-codegen python3 tests/fuzz/adder_fuzzer.py --repro <seed>

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

FUZZ_COUNT="${FUZZ_COUNT:-500}"
FUZZ_SEED="${FUZZ_SEED:-1}"
WORK="$PROJ_ROOT/build/fuzz_ad_codegen"

fail() { echo "[fuzz_adder_diff] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v as  >/dev/null 2>&1 || fail "as not found (apt install binutils)"
command -v ld  >/dev/null 2>&1 || fail "ld not found (apt install binutils)"
command -v gcc >/dev/null 2>&1 || fail "gcc not found (preprocesses linux-runtime.S)"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

mkdir -p "$WORK"

# ---- Build the host dump driver (codegen.ad pipeline -> raw bytes) ------
# Routed through ad_codegen_host.build_driver() so the cached binary is
# auto-invalidated whenever ANY real input changes (the dump driver .ad, the
# self-hosted compiler .ad set incl. opt.ad/codegen.ad, or the host Adder
# compiler .py set). No manual `rm -rf build/fuzz_ad_codegen` is needed for
# correctness — editing the optimizer and re-running this gate rebuilds.
echo "[fuzz_adder_diff] building host dump driver (codegen.ad -> x86_64-linux)"
python3 - <<'PY' || fail "host dump driver failed to compile"
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
h.build_driver()
PY

# ---- Regression: the codegen.ad gate must reproduce the known-answer
#      regression fixture (tests/fuzz/regress_codegen.ad) through codegen.ad.
#      This pins the three sub-8-byte scalar miscompiles + the cast fix +
#      the signed-load fix that codegen.ad must get right. -----------------
echo "[fuzz_adder_diff] regression: regress_codegen.ad through codegen.ad"
REG_OUT="$(python3 - <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
wd = Path("build/fuzz_ad_codegen")
r = h.run_through_codegen_ad("regress", open("tests/fuzz/regress_codegen.ad").read(), wd)
print(f"{r.kind} {r.stdout} {r.exit}")
PY
)"
echo "[fuzz_adder_diff] regression result: $REG_OUT (expect 'ok 18446742841164082190 14')"
[ "$REG_OUT" = "ok 18446742841164082190 14" ] \
    || fail "codegen.ad miscompiled the regression fixture: $REG_OUT"

# ---- Seeded differential batch -----------------------------------------
echo "[fuzz_adder_diff] differential: count=$FUZZ_COUNT seed=$FUZZ_SEED"
python3 tests/fuzz/adder_fuzzer.py --ad-codegen \
    --count "$FUZZ_COUNT" --seed "$FUZZ_SEED" --max-fail 25
RC=$?
[ "$RC" -eq 0 ] || fail "codegen.ad differential found a genuine miscompile (see report above)"

echo "[fuzz_adder_diff] PASS"
