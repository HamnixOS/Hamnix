#!/usr/bin/env bash
# scripts/test_de_term_cmd_not_found.sh — REGRESSION gate for hamsh's
# "command not found" diagnostic (#4) AND its no-hang invariant.
#
# A bad command at the prompt must (a) print a concise
# `hamsh: command not found: <cmd>` message, and (b) NOT hang the shell (a
# prior fix returns a negative sentinel on the do_wait==0 path instead of a
# bogus 127 PID that would make launch_foreground_pid spin forever).
#
# Driving a not-found command into the SCENE terminal requires keystroke
# injection, which is unreliable from the serial-shared /dev/cons in the VM
# harness (see test_de_scene_termfm.sh notes). So this gate is a fast,
# deterministic STATIC check over the shell source: it asserts both the
# message string and the no-hang sentinel are present and wired, so neither
# can silently regress.

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

SH=user/hamsh.ad
fail=0

echo "[cnf_gate] --- assertions ---"

# (C1) The message string exists.
if grep -aq 'hamsh: command not found' "$SH"; then
    echo "[cnf_gate] PASS 'hamsh: command not found' message present in $SH"
else
    echo "[cnf_gate] FAIL 'hamsh: command not found' message missing from $SH (#4 regressed)" >&2
    fail=1
fi

# (C2) The message is emitted at the external-command spawn path right after
# a failed spawn_resolved (the interactive prompt path).
if grep -aPzoq '(?s)spawn_resolved\(cmd.*?if pid < 0:.*?command not found' "$SH"; then
    echo "[cnf_gate] PASS not-found message wired to a failed spawn_resolved"
else
    echo "[cnf_gate] FAIL not-found message not wired to the failed-spawn path" >&2
    fail=1
fi

# (C3) NO-HANG invariant: on the do_wait==0 path a not-found returns a
# NEGATIVE sentinel (not 127), so the caller's `< 0` guard fires instead of
# waiting on a non-existent PID. Assert the guarded `return -1` is present.
if grep -aPzoq '(?s)command not found.*?if do_wait == 0:\s*\n\s*return -1' "$SH"; then
    echo "[cnf_gate] PASS no-hang sentinel preserved (do_wait==0 -> return -1)"
else
    echo "[cnf_gate] FAIL no-hang sentinel missing — not-found could hang the shell" >&2
    fail=1
fi

# (C4) EXISTENCE GATE: spawn_resolved must probe each candidate path with
# _path_execable before spawning, so a MISSING binary resolves to -1 and the
# not-found message actually fires. Without this the kernel spawn() returns a
# pid for a missing path (exec fails only in the child), the not-found path is
# skipped, and a bogus command runs silently — the exact "unknown commands are
# silent" bug in the DE terminal.
if grep -aq 'def _path_execable' "$SH" && grep -aq '_path_execable(' "$SH"; then
    echo "[cnf_gate] PASS spawn existence-gate (_path_execable) present — missing binary -> not-found"
else
    echo "[cnf_gate] FAIL _path_execable existence-gate missing — bogus commands run silently" >&2
    fail=1
fi

if [ "$fail" = "0" ]; then
    echo "[cnf_gate] RESULT: PASS"
    exit 0
else
    echo "[cnf_gate] RESULT: FAIL"
    exit 1
fi
