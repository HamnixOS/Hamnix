#!/usr/bin/env bash
# scripts/gate_summary.sh — end-of-job report over the gate verdict file.
#
# Reads the TSV rows appended by scripts/run_gate.sh:
#     <verdict>\t<gate>\t<rc>\t<log-path>
# and renders a summary to stdout and, under GitHub Actions, to
# $GITHUB_STEP_SUMMARY (the big markdown panel on the run page).
#
# Exit status:
#   0  every gate PASSed, or some were INCONCLUSIVE (see below)
#   1  at least one gate FAILed
#
# INCONCLUSIVE gates do NOT fail the job — a degraded host must not
# block all work. But they are rendered as the loudest thing on the
# page, and the headline verdict of the whole job becomes
# "NOT VERIFIED", never "all green". The invariant we are defending:
#
#     a human reading the CI result can never mistake
#     "we didn't observe it" for "we observed it and it was fine."
#
# Set GATE_SUMMARY_STRICT=1 to make INCONCLUSIVE a hard failure (useful
# for a nightly run on a known-quiet machine, where an inconclusive
# result genuinely is a problem worth waking someone for).

set -uo pipefail

VERDICT_FILE="${GATE_VERDICT_FILE:-/tmp/hamnix-gate-verdicts.tsv}"
STRICT="${GATE_SUMMARY_STRICT:-0}"

if [ ! -s "$VERDICT_FILE" ]; then
    echo "[gate_summary] no verdicts recorded at $VERDICT_FILE — no gate ran."
    echo "[gate_summary] Treating an empty battery as a FAILURE: a CI run" \
         "that executed zero gates has verified nothing." >&2
    exit 1
fi

pass=0; fail=0; inconc=0
while IFS=$'\t' read -r verdict gate rc log; do
    [ -n "${verdict:-}" ] || continue
    case "$verdict" in
        PASS)         pass=$((pass + 1)) ;;
        FAIL)         fail=$((fail + 1)) ;;
        INCONCLUSIVE) inconc=$((inconc + 1)) ;;
    esac
done < "$VERDICT_FILE"

total=$((pass + fail + inconc))

# ---- headline -------------------------------------------------------
if [ "$fail" -gt 0 ]; then
    headline="FAILED — $fail gate(s) observed a violated assertion"
elif [ "$inconc" -gt 0 ]; then
    headline="NOT VERIFIED — $inconc of $total gate(s) never observed their assertion"
else
    headline="VERIFIED — all $total gate(s) observed their assertion and it held"
fi

emit() {
    echo "$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "$1" >> "$GITHUB_STEP_SUMMARY"
    fi
}

emit "## Hamnix gate battery: $headline"
emit ""
emit "| Verdict | Gate | rc |"
emit "|---|---|---|"

# FAIL first, then INCONCLUSIVE, then PASS — worst news at the top.
for want in FAIL INCONCLUSIVE PASS; do
    while IFS=$'\t' read -r verdict gate rc log; do
        [ "${verdict:-}" = "$want" ] || continue
        case "$verdict" in
            PASS)         icon=":white_check_mark: PASS" ;;
            FAIL)         icon=":x: **FAIL**" ;;
            INCONCLUSIVE) icon=":warning: **INCONCLUSIVE**" ;;
        esac
        emit "| $icon | \`$gate\` | $rc |"
    done < "$VERDICT_FILE"
done

emit ""
emit "**$pass passed, $fail failed, $inconc inconclusive** (of $total)."

if [ "$inconc" -gt 0 ]; then
    emit ""
    emit "### :warning: $inconc gate(s) are INCONCLUSIVE — this is NOT a pass"
    emit ""
    emit "An INCONCLUSIVE gate never got far enough to observe the thing it"
    emit "asserts (QEMU timed out, the guest timer was starved by host load,"
    emit "a required tool or image was missing, or a screendump came back"
    emit "empty). Each was already retried once. **The code under test may be"
    emit "perfectly fine or catastrophically broken — this run cannot tell"
    emit "you which.** Do not cite this run as evidence that these paths work."
    emit ""
    emit "Inconclusive gates:"
    while IFS=$'\t' read -r verdict gate rc log; do
        [ "${verdict:-}" = "INCONCLUSIVE" ] || continue
        emit "- \`$gate\` — re-run on a quiet host, or install the missing dependency."
    done < "$VERDICT_FILE"

    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning title=Battery NOT VERIFIED::$inconc of $total gates were INCONCLUSIVE — their assertions were never observed. This run is not evidence that those paths work."
    fi
fi

if [ "$fail" -gt 0 ]; then
    echo "[gate_summary] $headline" >&2
    exit 1
fi

if [ "$inconc" -gt 0 ] && [ "$STRICT" = "1" ]; then
    echo "[gate_summary] GATE_SUMMARY_STRICT=1 and $inconc gate(s) inconclusive" >&2
    exit 1
fi

echo "[gate_summary] $headline"
exit 0
