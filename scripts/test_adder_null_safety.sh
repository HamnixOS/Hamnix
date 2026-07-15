#!/usr/bin/env bash
# scripts/test_adder_null_safety.sh — Adder opt-in Optional None-deref checks
# (language roadmap item 2, null-safety). HOST-ONLY, NO QEMU.
#
# Verifies the postfix `!` force-unwrap operator on Option/Result end to end
# (see docs/adder_language_roadmap.md item 2 + docs/adder_memory_safety.md):
#
#   (1) UNWRAP-OK:   `opt!` on a Some/Ok value yields the payload and runs
#                    correctly, with AND without --check-bounds (the trap is
#                    never taken on the success path).
#   (2) NONE-TRAP:   `opt!` on a None/Err value traps CLEANLY under
#                    --check-bounds (ud2 -> SIGILL, wait-status 132).
#   (3) BYTE-INERT:  WITHOUT the flag, the None-unwrap emits NO `ud2` (it is a
#                    zero-cost extraction) — the check is opt-in, byte-inert off.
#   (4) UNSAFE-OUT:  an `unsafe:` block suppresses the trap even with the flag on.
#   (5) KERNEL:      the SAME source compiled for x86_64-bare-metal emits NO
#                    `ud2` even with --check-bounds — the kernel is structurally
#                    exempt (zero-cost force-unwrap).
#   (6) LOCKSTEP:    the NATIVE .ad backend compiles `!` to byte-identical code
#                    vs the seed oracle (objdiff clean), on BOTH flag states.
#
# Usage:  bash scripts/test_adder_null_safety.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[nullsafe] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/nullsafe"
WORK="build/nullsafe"
mkdir -p "$WORK"

asm() {  # asm <src> <target> <extra...> -> asm on stdout
    local src="$1"; local target="$2"; shift 2
    python3 -m compiler.adder asm "$src" --target="$target" "$@"
}
build() {  # build <src> <out> <extra...> -> host ELF for x86_64-linux
    local src="$1"; local out="$2"; shift 2
    python3 -m compiler.adder compile "$src" --target=x86_64-linux "$@" \
        -o "$out" >/dev/null 2>"$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "compile failed: $src"; }
}

echo "[nullsafe] (1) unwrap of Some/Ok yields the payload (with + without flag)"
build "$FIX/unwrap_ok.ad" "$WORK/uw_ok"
"$WORK/uw_ok"; rc=$?
echo "[nullsafe]   unwrap_ok (no flag) exit = $rc (expect 12)"
[ "$rc" -eq 12 ] || fail "unwrap_ok returned $rc, expected 12"
build "$FIX/unwrap_ok.ad" "$WORK/uw_ok_on" --check-bounds
"$WORK/uw_ok_on"; rc=$?
echo "[nullsafe]   unwrap_ok (--check-bounds) exit = $rc (expect 12)"
[ "$rc" -eq 12 ] || fail "unwrap_ok (checked) returned $rc, expected 12"

echo "[nullsafe] (2) unwrap of None traps CLEANLY under --check-bounds (SIGILL=132)"
build "$FIX/unwrap_none.ad" "$WORK/uw_none_on" --check-bounds
"$WORK/uw_none_on"; rc=$?
echo "[nullsafe]   unwrap_none (--check-bounds) exit = $rc (expect 132 = SIGILL)"
[ "$rc" -eq 132 ] || fail "None-unwrap did NOT trap under --check-bounds (got $rc)"

echo "[nullsafe] (3) WITHOUT the flag, the None-unwrap emits NO ud2 (byte-inert off)"
n=$(asm "$FIX/unwrap_none.ad" x86_64-linux 2>/dev/null | grep -c ud2)
echo "[nullsafe]   ud2 count (no flag) = $n (expect 0)"
[ "$n" -eq 0 ] || fail "unchecked None-unwrap emitted a ud2 (not byte-inert)"

echo "[nullsafe] (4) an unsafe: block suppresses the trap even with the flag on"
n=$(asm "$FIX/unwrap_unsafe.ad" x86_64-adder-user --check-bounds 2>/dev/null | grep -c ud2)
echo "[nullsafe]   ud2 count (unsafe: + flag) = $n (expect 0)"
[ "$n" -eq 0 ] || fail "unsafe: block did NOT suppress the None-unwrap trap"

echo "[nullsafe] (5) KERNEL (bare-metal) emits NO ud2 even with --check-bounds"
n=$(asm "$FIX/unwrap_none.ad" x86_64-bare-metal --check-bounds 2>/dev/null | grep -c ud2)
echo "[nullsafe]   ud2 count (bare-metal + flag) = $n (expect 0)"
[ "$n" -eq 0 ] || fail "kernel target emitted a null-check ud2 (opt-out not structural)"

echo "[nullsafe] (6) NATIVE .ad backend == seed oracle (objdiff clean, both flags)"
source "$PROJ_ROOT/scripts/_adder_cc.sh"
ADDER_CC=adder adder_cc_bootstrap >/dev/null 2>&1 || fail "host_ac bootstrap failed"
HOSTAC="$PROJ_ROOT/build/cutover/host_ac.elf"
objdiff_case() {  # objdiff_case <src> <name> <extra...>
    local src="$1"; local name="$2"; shift 2
    "$HOSTAC" "$@" --target=x86_64-adder-user "$src" "$WORK/$name.native.elf" \
        >/dev/null 2>"$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "NATIVE .ad backend rejected $name"; }
    python3 -m compiler.adder compile "$src" --target=x86_64-adder-user "$@" \
        -o "$WORK/$name.seed.elf" >/dev/null 2>&1 \
        || fail "seed adder-user compile failed: $name"
    python3 "$PROJ_ROOT/scripts/objdiff_normalize.py" \
        "$WORK/$name.seed.elf" "$WORK/$name.native.elf" "$name" \
        || fail "native $name codegen DIVERGES from the seed (objdiff)"
}
objdiff_case "$FIX/unwrap_ok.ad"   uw_ok_off
objdiff_case "$FIX/unwrap_ok.ad"   uw_ok_onf  --check-bounds
objdiff_case "$FIX/unwrap_none.ad" uw_none_onf --check-bounds
echo "[nullsafe]   native == seed machine code (objdiff clean) — seed+native lockstep"

echo "[nullsafe] PASS — opt-in Optional None-deref checks, byte-inert off, kernel-exempt"
