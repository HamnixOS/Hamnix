#!/usr/bin/env bash
# scripts/test_adder_own_move.sh — Adder `Own[T]` move-only (affine) handles
# (memory-safety roadmap increment 5, Tier B). HOST-ONLY, NO QEMU.
#
# `Own[T]` marks a MOVE-ONLY binding: it may be used at most once. Passing it by
# value / assigning it / returning it MOVES it; using a moved-from binding is a
# COMPILE-TIME "use after move" error. An explicit `drop(x)` moves x, so a second
# `drop(x)` is caught as a double-free. This is a compile-time affine flow
# analysis (adder/compiler/affine_check.py) with ZERO runtime cost — `Own[T]` is
# REPRESENTATIONALLY IDENTICAL to a plain `T` (it strips to the inner type in the
# parser), so an `own` binding is byte-identical to a non-own one. See
# docs/adder_language_roadmap.md (increment 5) and docs/adder_memory_safety.md.
#
# Verifies end to end:
#   (1) OK: a correct single-move program compiles + runs (exit 42).
#   (2) BORROW: `foo(&x)` reads x WITHOUT moving it, then a single move is legal
#       (exit 9) — the escape hatch from "pass-by-value moves".
#   (3) USE-AFTER-MOVE: reading an `own` binding after it was moved is a COMPILE
#       ERROR (non-zero exit + "use after move" diagnostic).
#   (4) DOUBLE-DROP: `drop(x)` moves x; a second `drop(x)` is a COMPILE ERROR
#       (double-free caught).
#   (5) LOCKSTEP: seed and native emit semantically identical machine code for
#       the correct program on x86_64-adder-user (the differential objdiff).
#   (6) BYTE-INERT / ZERO-COST: `Own[T]` compiles to bytes IDENTICAL to plain
#       `T` — the affine check emits nothing at runtime.
#   (7) UNSAFE opt-out: an `@unsafe` function's body is NOT move-checked (a
#       use-after-move inside it compiles).
#   Auto-drop insertion (drop() at scope exit for an un-moved own binding) is
#   DEFERRED this increment — see the roadmap STATUS; the move / use-after-move
#   / double-free core is the high-value deliverable.
#
# Usage:  bash scripts/test_adder_own_move.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[own] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/own"
WORK="build/own_check"
mkdir -p "$WORK"

seedc() { # seedc <src> <out> ; compile with the Python seed to a host ELF
    python3 -m compiler.adder compile "$1" --target=x86_64-linux \
        -o "$2" >/dev/null 2>"$WORK/cerr"
}

echo "[own] (1) correct single-move program compiles + runs -> 42"
seedc "$FIX/own_ok.ad" "$WORK/ok" || { cat "$WORK/cerr"; fail "own_ok did not compile"; }
"$WORK/ok"; rc=$?
echo "[own]   own_ok exit = $rc (expect 42)"
[ "$rc" -eq 42 ] || fail "correct single-move program returned $rc, expected 42"

echo "[own] (2) borrow via &x does NOT move; a later single move is legal -> 9"
seedc "$FIX/own_borrow_ok.ad" "$WORK/borrow" || { cat "$WORK/cerr"; fail "own_borrow_ok did not compile"; }
"$WORK/borrow"; rc=$?
echo "[own]   own_borrow_ok exit = $rc (expect 9)"
[ "$rc" -eq 9 ] || fail "borrow-then-move returned $rc, expected 9"

echo "[own] (3) use-after-move must be a COMPILE ERROR"
if seedc "$FIX/own_use_after_move.ad" "$WORK/uam"; then
    fail "use-after-move compiled clean (should be rejected)"
fi
grep -q "use after move" "$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "use-after-move rejected without the expected diagnostic"; }
echo "[own]   rejected: $(grep -m1 'use after move' "$WORK/cerr")"

echo "[own] (4) double-drop (double-free) must be a COMPILE ERROR"
if seedc "$FIX/own_double_drop.ad" "$WORK/dd"; then
    fail "double-drop compiled clean (should be rejected)"
fi
grep -q "use after move" "$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "double-drop rejected without the expected diagnostic"; }
echo "[own]   rejected: $(grep -m1 'use after move' "$WORK/cerr")"

echo "[own] (5) seed<->native byte-lockstep on the correct program (objdiff)"
source scripts/_adder_cc.sh
ADDER_CC=adder adder_cc_bootstrap >/dev/null 2>&1 || fail "native bootstrap failed"
ADDER_CC=python adder_cc_compile compile --target=x86_64-adder-user \
    "$FIX/own_ok.ad" -o "$WORK/ok.seed.elf" >/dev/null 2>&1 || fail "seed adder-user compile failed"
ADDER_CC=adder adder_cc_compile compile --target=x86_64-adder-user \
    "$FIX/own_ok.ad" -o "$WORK/ok.nat.elf" >/dev/null 2>&1 || fail "native adder-user compile failed (Own[T] parse?)"
python3 scripts/objdiff_normalize.py "$WORK/ok.seed.elf" "$WORK/ok.nat.elf" own_ok \
    || fail "seed<->native DIVERGED on own_ok"
echo "[own]   objdiff CLEAN (seed and native emit identical code)"

echo "[own] (6) byte-inert / zero-cost: Own[T] emits bytes IDENTICAL to plain T"
sed 's/Own\[int32\]/int32/g' "$FIX/own_ok.ad" > "$FIX/_own_plain_tmp.ad"
seedc "$FIX/own_ok.ad" "$WORK/own_ok.bin" || fail "own_ok recompile failed"
seedc "$FIX/_own_plain_tmp.ad" "$WORK/plain.bin" || fail "plain recompile failed"
rm -f "$FIX/_own_plain_tmp.ad"
cmp -s "$WORK/own_ok.bin" "$WORK/plain.bin" \
    || fail "Own[T] is NOT byte-identical to plain T (must be zero-cost)"
echo "[own]   Own[int32] === int32 byte-for-byte (zero runtime cost)"

echo "[own] (7) @unsafe function body is NOT move-checked (escape hatch)"
seedc "$FIX/own_unsafe_optout.ad" "$WORK/optout" \
    || { cat "$WORK/cerr"; fail "@unsafe did not relax the affine check"; }
"$WORK/optout"; rc=$?
echo "[own]   own_unsafe_optout exit = $rc (expect 3; compiled despite a reuse)"
[ "$rc" -eq 3 ] || fail "@unsafe opt-out program returned $rc, expected 3"

echo "[own] ALL PASS"
