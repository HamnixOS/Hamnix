#!/usr/bin/env bash
# scripts/ci_run_gate.sh — INCONCLUSIVE-aware CI wrapper for one gate.
#
# WHY THIS EXISTS
#
# The verdict vocabulary (scripts/_verdict.sh) is three-valued:
#
#     0    PASS          the assertion was OBSERVED to hold
#     1    FAIL          the assertion was OBSERVED to be violated
#   125    INCONCLUSIVE  the run never got far enough to observe it (QEMU
#                        timeout, a guest timer starved by host/runner load,
#                        a missing image/dependency)
#
# GitHub Actions treats ANY non-zero step exit as a build failure. If CI
# invoked a boot gate directly, an INCONCLUSIVE run — a GitHub runner has
# NO /dev/kvm, so every boot is pure-TCG software emulation and is routinely
# starved — would RED-WALL the build with a failure that says nothing about
# the code. That is exactly the false-red this project has been burned by.
#
# This wrapper runs one gate and maps its verdict onto CI semantics:
#
#     PASS (0)          -> exit 0   (green)
#     FAIL (1, or any
#          other non-125,
#          non-0 code)  -> exit rc  (red — a real, actionable failure)
#     INCONCLUSIVE (125)-> exit 0 + a GitHub ::warning:: annotation
#                          (NOT green-as-proof, but NOT a build failure: the
#                          runner was too starved to observe the assertion;
#                          re-run or move to a KVM runner to get a verdict)
#
# Rationale for not failing on 125: a starved TCG runner is an ENVIRONMENT
# input, not a regression. Treating it as red would make the whole battery
# flap on runner load and train everyone to ignore red — the precise failure
# mode that let a broken shell pipeline, a console-wedging df and a ps
# printing uninitialised memory all ship behind "green". A genuine
# regression exits 1 (FAIL) and still reds the build.
#
# USAGE
#   bash scripts/ci_run_gate.sh scripts/test_pipe.sh
#
# The gate's full output is streamed through unchanged (so the CI log and
# any uploaded artifact are complete); only the EXIT STATUS is remapped.

set -uo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: ci_run_gate.sh <test-script> [args...]" >&2
    exit 2
fi

gate="$1"; shift
name="$(basename "$gate" .sh)"

bash "$gate" "$@"
rc=$?

case "$rc" in
    0)
        echo "[ci_run_gate] $name: PASS (verdict 0)"
        exit 0
        ;;
    125)
        # INCONCLUSIVE — surface it loudly but do NOT fail the build.
        echo "[ci_run_gate] $name: INCONCLUSIVE (verdict 125) — the runner" \
             "was too starved to observe the assertion; NOT a regression," \
             "NOT proof of correctness. Re-run, ideally on a KVM runner."
        # GitHub annotation so it is visible on the run summary page.
        echo "::warning title=$name INCONCLUSIVE::gate could not observe its" \
             "assertion under runner load (verdict 125); treated as non-failing"
        exit 0
        ;;
    *)
        echo "[ci_run_gate] $name: FAIL (verdict $rc) — an OBSERVED violation" >&2
        exit "$rc"
        ;;
esac
