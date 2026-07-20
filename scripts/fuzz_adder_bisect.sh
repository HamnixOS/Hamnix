#!/usr/bin/env bash
# scripts/fuzz_adder_bisect.sh — given a MISCOMPILING fuzzer seed, identify WHICH
# --opt pass causes the ADDER_OPT=1 divergence by toggling passes off one at a
# time and re-running that single seed through the codegen.ad differential lane.
#
# WHY: scripts/fuzz_adder_diff.sh (ADDER_OPT=1) catches an --opt miscompile on
# the host in seconds, but reports only THAT the optimized build diverged, not
# which pass. This wrapper does the last mile: it disables each optimizer pass in
# turn and finds the one whose absence makes the seed go GREEN — that pass is the
# culprit (e.g. the loop-condition-CSE bug fa494cdf bisects to `cse`; the DSE
# global-name-cap bug bisects to `dce`).
#
# DEPENDS ON: the per-pass toggle env var ADDER_OPT_DISABLE=<comma-list>, honored
# by the self-hosted --opt pipeline (opt.ad / the codegen.ad host driver). Pass
# names: rec2iter,constfold,constbranch,xcse,cse,licm,ivsr,copyprop,paritymod,dce
# (default unset = all passes on). Landed on origin/main (b9c80be5). If your base
# predates it, the "disable" runs behave like the all-on run and the bisect
# reports "inconclusive"; the wrapper needs no change once the toggle is present.
#
# BOUNDARY (important): those 10 toggles cover only opt_run's AST passes. `--opt`
# ALSO arms sibling CODEGEN levers that live OUTSIDE opt_run and are NOT gated by
# ADDER_OPT_DISABLE: ra (regalloc), isel (instruction selection), sr (div/mod
# strength reduce), cmpjcc (cmp+jcc fusion), vec (SSE2 vectorizer), ir_emit
# (Phase-5 IR emit). So "all 10 disabled" != -O0 — the levers still run. If a
# seed STILL miscompiles with all 10 passes off, the culprit is one of those
# codegen levers, not an opt_run pass; this wrapper detects that case and says so
# (extending the toggle to the levers is a separate follow-up).
#
# Usage:
#   bash scripts/fuzz_adder_bisect.sh <seed>
#   FUZZ_FEATURES=loopcond bash scripts/fuzz_adder_bisect.sh 42000126
#
# A miscompiling seed is whatever scripts/fuzz_adder_diff.sh (or the fuzzer's
# --ad-codegen lane) printed as "[MISCOMPILE seed=...]". Under ADDER_OPT=1 this
# also catches --opt-introduced NON-TERMINATION (a run timeout is escalated to a
# differential by the fuzzer).

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

SEED="${1:-}"
[ -n "$SEED" ] || { echo "usage: $0 <miscompiling-seed>"; exit 2; }

PASSES=(rec2iter constfold constbranch xcse cse licm ivsr copyprop paritymod dce)

# Run the single seed through the codegen.ad ADDER_OPT=1 lane with the given
# ADDER_OPT_DISABLE value. Returns 0 (green) or 1 (miscompile) via the fuzzer's
# exit status; the fuzzer runs exactly this seed as a 1-program batch.
run_seed() {
    local disable="$1"
    ADDER_OPT=1 ADDER_OPT_DISABLE="$disable" \
        python3 tests/fuzz/adder_fuzzer.py --ad-codegen \
            --count 1 --seed "$SEED" --max-fail 1 >/dev/null 2>&1
    return $?
}

echo "[bisect] seed=$SEED  (ADDER_OPT=1 codegen.ad lane)"
echo "[bisect] features=${FUZZ_FEATURES:-<all>}"

# 1) Confirm the seed miscompiles with ALL passes on.
if run_seed ""; then
    echo "[bisect] seed is GREEN with all passes on -- not a miscompile (or already fixed). Nothing to bisect."
    exit 0
fi
echo "[bisect] confirmed: MISCOMPILE with all passes on."

# 2) Disable each pass ONE AT A TIME (single token). The pass whose absence makes
#    the seed GREEN is the culprit. NOTE: this deliberately uses a SINGLE token
#    per run — the current ADDER_OPT_DISABLE comma-list parser (b9c80be5) only
#    honors ONE token; a multi-element list fails to set all bits (observed: a
#    single `cse` silences the loop-cond-CSE bug, but `cse,licm` does not). So a
#    disable-all-then-re-enable strategy is unreliable until the parser handles
#    multi-token lists; single-token bisection is robust and pinpoints the pass.
echo "[bisect] disabling one pass at a time to find the culprit..."
CULPRITS=()
for p in "${PASSES[@]}"; do
    if run_seed "$p"; then
        echo "[bisect]   disable '$p' -> GREEN   <== culprit"
        CULPRITS+=("$p")
    else
        echo "[bisect]   disable '$p' -> still miscompiles"
    fi
done

echo "==========================================="
if [ "${#CULPRITS[@]}" -eq 0 ]; then
    echo "[bisect] no SINGLE opt_run pass disable fixed it. Two possibilities:"
    echo "[bisect]  (a) the culprit is a CODEGEN LEVER outside ADDER_OPT_DISABLE's"
    echo "[bisect]      gate — ra (regalloc), isel, sr (div/mod strength-reduce),"
    echo "[bisect]      cmpjcc (cmp+jcc fusion), vec (SSE2), ir_emit (Phase-5);"
    echo "[bisect]      extending the toggle to those levers is the follow-up."
    echo "[bisect]  (b) it needs MULTIPLE passes disabled together, which the"
    echo "[bisect]      single-token parser cannot yet express (see note above)."
    echo "[bisect]  (or your tree predates the toggle land b9c80be5 = disables were no-ops)"
    exit 4
fi
echo "[bisect] CULPRIT PASS(ES): ${CULPRITS[*]}"
echo "[bisect] repro the miscompile with:"
echo "  ADDER_OPT=1 FUZZ_FEATURES=${FUZZ_FEATURES:-<all>} python3 tests/fuzz/adder_fuzzer.py --ad-codegen --count 1 --seed $SEED"
exit 0
