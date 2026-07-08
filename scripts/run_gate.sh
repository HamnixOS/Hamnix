#!/usr/bin/env bash
# scripts/run_gate.sh — run one CI gate and report a three-valued verdict.
#
#   Usage: bash scripts/run_gate.sh <gate-script> [args...]
#     e.g. bash scripts/run_gate.sh scripts/test_hamsh_heartbeat.sh
#
# WHY THIS WRAPPER EXISTS (two independent bugs it closes)
#
# 1. THE `| tee` HOLE.  Every gate in .github/workflows/ci.yml used to be
#    invoked as:
#
#        run: bash scripts/test_X.sh 2>&1 | tee /tmp/test_X.log
#
#    GitHub Actions runs a `run:` step with no explicit `shell:` as
#    `bash -e {0}` — WITHOUT pipefail. In a pipeline, the shell's exit
#    status is that of the LAST command, i.e. `tee`, which essentially
#    always succeeds. So the gate's own exit status was discarded and
#    every one of those steps was green unconditionally. (Corroborating
#    evidence: the paired `if: failure()` log-upload steps could never
#    have fired.) The battery was structurally incapable of going red.
#
#    This wrapper never pipes the gate. It redirects to the log file,
#    captures the real status, and then tees the file to stdout.
#
# 2. THE MISSING VERDICT.  A gate that hits a QEMU timeout, a starved
#    guest timer, a missing OVMF/socat, or an empty screendump has not
#    observed its assertion. It must not report PASS. See
#    scripts/_verdict.sh for the exit-status convention:
#
#        0 = PASS   1 = FAIL   125 = INCONCLUSIVE
#
# POLICY IMPLEMENTED HERE
#
#   PASS (0)          -> step succeeds, quietly.
#   FAIL (1, or any
#     other non-zero)  -> step FAILS. Hard red. This is a real defect.
#   INCONCLUSIVE (125) -> retry the gate EXACTLY ONCE. Host degradation
#                         (contended TCG, drained-QEMU backlog, iowait
#                         storms) is usually transient, and a single
#                         retry converts most honest inconclusives into
#                         a real PASS or a real FAIL.
#                         If the retry also comes back 125, the gate is
#                         recorded as INCONCLUSIVE: a loud ::warning::
#                         annotation, a row in the job summary, and a
#                         line in $GATE_VERDICT_FILE. The step exits 0
#                         so a degraded host does not block all work —
#                         but the run is NOT reported as verified. The
#                         summary step (see ci.yml) reprints every
#                         inconclusive gate at the end of the job, and
#                         the job's summary says, in words, that those
#                         assertions were never observed.
#
# The requirement this satisfies: a human reading the CI result can
# never mistake "we didn't observe it" for "we observed it and it was
# fine." An inconclusive gate is never silently green.
#
# GATE_VERDICT_FILE (default /tmp/hamnix-gate-verdicts.tsv) accumulates
#   <verdict>\t<gate>\t<rc>\t<log-path>
# one row per gate, for the end-of-job summary.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

. "$PROJ_ROOT/scripts/_verdict.sh"

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <gate-script> [args...]" >&2
    exit 2
fi

GATE="$1"; shift
GATE_NAME="$(basename "$GATE" .sh)"
GATE_VERDICT_FILE="${GATE_VERDICT_FILE:-/tmp/hamnix-gate-verdicts.tsv}"
LOG="/tmp/${GATE_NAME}.log"

# GitHub Actions workflow-command annotations; harmless no-ops locally.
annotate() { # level, message
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::$1 title=${GATE_NAME}::$2"
    fi
}

run_once() {
    # NO PIPELINE. The gate's status must survive.
    bash "$GATE" "$@" >"$LOG" 2>&1
    return $?
}

echo "[run_gate] ===== ${GATE_NAME} (attempt 1) ====="
run_once "$@"
rc=$?

if [ "$rc" -eq "$VERDICT_INCONCLUSIVE_RC" ]; then
    echo "[run_gate] ${GATE_NAME}: INCONCLUSIVE on attempt 1 — the gate" \
         "could not observe its assertion. Retrying exactly once, in case" \
         "the host was transiently degraded."
    cat "$LOG"
    echo "[run_gate] ===== ${GATE_NAME} (attempt 2 — final) ====="
    run_once "$@"
    rc=$?
fi

cat "$LOG"

verdict="$(verdict_name "$rc")"
printf '%s\t%s\t%s\t%s\n' "$verdict" "$GATE_NAME" "$rc" "$LOG" \
    >> "$GATE_VERDICT_FILE"

case "$rc" in
    0)
        echo "[run_gate] ${GATE_NAME}: PASS"
        exit 0
        ;;
    "$VERDICT_INCONCLUSIVE_RC")
        echo "[run_gate] ${GATE_NAME}: INCONCLUSIVE (twice)."
        echo "[run_gate] This gate did NOT observe its assertion. It is" \
             "NOT a pass. The code under test may be fine or may be" \
             "broken; this run cannot tell you which."
        annotate warning \
            "INCONCLUSIVE (twice) — assertion never observed. This is NOT a pass. See the job summary."
        # Exit 0: a degraded host must not block all work. The verdict
        # file + annotation + job summary carry the truth.
        exit 0
        ;;
    *)
        echo "[run_gate] ${GATE_NAME}: FAIL (rc=$rc)" >&2
        annotate error "FAIL (rc=$rc)"
        exit 1
        ;;
esac
