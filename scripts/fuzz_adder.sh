#!/usr/bin/env bash
# scripts/fuzz_adder.sh — driver for the x86_64 Adder backend fuzzer.
#
# De-risks the hand-rolled single-pass x86_64 encoder (adder/compiler/
# codegen_x86.py) by generating random VALID Adder programs whose expected
# output is known BY CONSTRUCTION (no second compiler), compiling each to the
# `x86_64-linux` target, RUNNING THE ELF ON THE HOST (no QEMU), and comparing
# actual vs predicted. See tests/fuzz/adder_fuzzer.py for the oracle design.
#
# Two phases:
#   1. REGRESSION: compile+run tests/fuzz/regress_codegen.ad and assert its
#      single printed value. This pins the three miscompiles the fuzzer found
#      and fixed (sized scalar-global store/load, narrowing-cast truncation,
#      signed sub-8-byte global sign-extension). Fast, deterministic — safe
#      for CI on every commit.
#   2. FUZZ: a fixed, seeded batch of generated programs (deterministic, so CI
#      is not flaky). Default count is modest for CI; pass a larger --count for
#      a soak run.
#
# Usage:
#   bash scripts/fuzz_adder.sh                 # CI mode: regression + 500 fuzz
#   FUZZ_COUNT=20000 bash scripts/fuzz_adder.sh   # soak run
#   FUZZ_SEED=42 bash scripts/fuzz_adder.sh       # different deterministic seed
#
# HOST-ONLY: needs only python3 + as/ld/gcc (binutils + a C driver to
# preprocess user/linux-runtime.S) on an x86_64 host. No QEMU, no image build.
#
# Prints "[fuzz_adder] PASS" on success; "[fuzz_adder] FAIL ..." + non-zero
# exit on any miscompile / compiler crash / regression mismatch.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

FUZZ_COUNT="${FUZZ_COUNT:-500}"
FUZZ_SEED="${FUZZ_SEED:-1}"
# FUZZ_OPT=1 compiles every program (regression + fuzz batch) through the -O1
# peephole optimizer (Track 6) instead of the trusted single-pass backend.
# The predicted-output oracle is identical, so any disagreement is an
# OPTIMIZER-INTRODUCED miscompile. Default 0 keeps CI on the trusted path.
FUZZ_OPT="${FUZZ_OPT:-0}"
OPT_ARGS=""
[ "$FUZZ_OPT" != "0" ] && OPT_ARGS="-O $FUZZ_OPT"
WORK="$PROJ_ROOT/build/fuzz_adder"

fail() { echo "[fuzz_adder] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v as  >/dev/null 2>&1 || fail "as not found (apt install binutils)"
command -v ld  >/dev/null 2>&1 || fail "ld not found (apt install binutils)"
command -v gcc >/dev/null 2>&1 || fail "gcc not found (preprocesses linux-runtime.S)"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

mkdir -p "$WORK"

# ---- Phase 1: regression fixture ---------------------------------------
echo "[fuzz_adder] regression: tests/fuzz/regress_codegen.ad (opt=$FUZZ_OPT)"
REG_ELF="$WORK/regress.elf"
python3 -m compiler.adder compile --target=x86_64-linux $OPT_ARGS \
    tests/fuzz/regress_codegen.ad -o "$REG_ELF" >/dev/null 2>"$WORK/reg.cerr" \
    || { cat "$WORK/reg.cerr"; fail "regression fixture failed to compile"; }
REG_OUT="$("$REG_ELF")"
REG_RC=$?
REG_EXPECT="18446742841164082190"
[ "$REG_OUT" = "$REG_EXPECT" ] \
    || fail "regression value $REG_OUT != $REG_EXPECT (a fixed miscompile is BACK)"
# exit code is low byte of the value: 18446742841164082190 & 0xFF = 14
[ "$REG_RC" -eq 14 ] || fail "regression exit $REG_RC != 14"
echo "[fuzz_adder] regression OK (value=$REG_OUT exit=$REG_RC)"

# ---- Phase 2: seeded fuzz batch ----------------------------------------
echo "[fuzz_adder] fuzz: count=$FUZZ_COUNT seed=$FUZZ_SEED opt=$FUZZ_OPT"
python3 tests/fuzz/adder_fuzzer.py --count "$FUZZ_COUNT" --seed "$FUZZ_SEED" \
    --opt "$FUZZ_OPT" --max-fail 25
RC=$?
[ "$RC" -eq 0 ] || fail "fuzzer reported $RC failures (see report above; repro with --emit <seed>)"

echo "[fuzz_adder] PASS"
