#!/usr/bin/env bash
# scripts/test_adder_bounds_check.sh — Adder runtime array-bounds checking
# (memory-safety increment 1). HOST-ONLY, NO QEMU.
#
# Verifies the opt-in `--check-bounds` feature end to end (see
# docs/adder_memory_safety.md):
#
#   (1) TRAP:      an out-of-range `Array[N,T]` index in checked USERSPACE code
#                  faults cleanly (SIGILL via `ud2`, wait-status 132).
#   (2) IN-RANGE:  a valid index in the SAME checked code runs unaffected.
#   (3) OPT-OUT:   the identical OOB index inside an `unsafe:` block does NOT
#                  trap — the check is suppressed.
#   (4) KERNEL:    the SAME source compiled for x86_64-bare-metal WITH
#                  --check-bounds emits NO check (`ud2`) — kernel code is never
#                  instrumented, so raw pointer/MMIO work stays fast.
#   (5) BYTE-INERT: userspace code compiled WITHOUT --check-bounds emits NO
#                  check — the feature is byte-inert when off (default).
#
# Usage:  bash scripts/test_adder_bounds_check.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[bounds-check] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/membounds"
WORK="build/bounds_check"
mkdir -p "$WORK"

cc() {  # cc <target> <extra-flags...> <src> -> asm on stdout
    python3 -m compiler.adder asm "$@"
}
build() { # build <src> <out> <extra-flags...>
    local src="$1"; local out="$2"; shift 2
    python3 -m compiler.adder compile "$src" --target=x86_64-linux "$@" \
        -o "$out" >/dev/null 2>"$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "compile failed: $src $*"; }
}

echo "[bounds-check] (1) OOB index in checked code must trap (SIGILL)"
build "$FIX/oob.ad" "$WORK/oob" --check-bounds
"$WORK/oob"; rc=$?
echo "[bounds-check]   oob exit status = $rc (expect 132 = 128+SIGILL)"
[ "$rc" -eq 132 ] || fail "OOB index did not trap with SIGILL (got $rc)"

echo "[bounds-check] (2) in-range index in checked code runs unaffected"
build "$FIX/inrange.ad" "$WORK/inrange" --check-bounds
"$WORK/inrange"; rc=$?
echo "[bounds-check]   inrange exit status = $rc (expect 10)"
[ "$rc" -eq 10 ] || fail "in-range checked index returned $rc, expected 10"

echo "[bounds-check] (3) unsafe: block suppresses the check (no trap)"
build "$FIX/unsafe_optout.ad" "$WORK/unsafe" --check-bounds
"$WORK/unsafe"; rc=$?
echo "[bounds-check]   unsafe exit status = $rc (expect 0, NOT 132)"
[ "$rc" -eq 0 ] || fail "unsafe: opt-out did not suppress the check (got $rc)"

echo "[bounds-check] (4) kernel target is never instrumented (no ud2)"
if cc "$FIX/oob.ad" --target=x86_64-bare-metal --check-bounds 2>/dev/null \
        | grep -q 'ud2'; then
    fail "kernel (bare-metal) target emitted a bounds-check ud2"
fi
echo "[bounds-check]   bare-metal + --check-bounds: no ud2 emitted (correct)"

echo "[bounds-check] (5) byte-inert when off: no ud2 without --check-bounds"
if cc "$FIX/oob.ad" --target=x86_64-linux 2>/dev/null | grep -q 'ud2'; then
    fail "userspace default (no flag) emitted a bounds-check ud2"
fi
echo "[bounds-check]   x86_64-linux default: no ud2 emitted (correct)"

# Sanity: the checked userspace build MUST contain the check we rely on.
cc "$FIX/oob.ad" --target=x86_64-linux --check-bounds 2>/dev/null \
    | grep -q 'ud2' || fail "checked userspace build unexpectedly had no ud2"

echo "[bounds-check] PASS: bounds check traps OOB, respects unsafe: opt-out,"
echo "[bounds-check]       never instruments the kernel, byte-inert when off."
