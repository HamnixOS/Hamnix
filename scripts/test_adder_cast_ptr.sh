#!/usr/bin/env bash
# scripts/test_adder_cast_ptr.sh — #296 regression gate: casting an AGGREGATE
# local (Array / in-place struct / Slice[T]) to Ptr[T] must DECAY the aggregate
# to its base ADDRESS (&x[0]), exactly like C array->pointer decay — NOT
# value-load the first element.
#
# The seed oracle (codegen_x86.gen_identifier) leaq-decays an aggregate-typed
# identifier; the native backend (codegen.ad) was value-loading element 0, so
# cast[Ptr[T]](array_local) miscompiled. This gate compiles the cast fixtures
# with BOTH backends and asserts seed<->native BYTE-LOCKSTEP (objdiff clean),
# keeping the case covered going forward. Host-only (no QEMU); seconds.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

FIX="tests/castptr"
WORK="build/cast_ptr_check"
mkdir -p "$WORK"

fail() { echo "[castptr] FAIL: $*"; exit 1; }

# Clean the fuzz codegen scratch so the native host compiler rebuilds fresh
# (per the compiler-verify discipline).
rm -rf build/fuzz_ad_codegen

echo "[castptr] seed<->native byte-lockstep on the aggregate->Ptr cast fixtures (objdiff)"
bash scripts/test_native_vs_seed_objdiff.sh \
    "$FIX/arr_to_ptr.ad" "$FIX/struct_to_ptr.ad" "$FIX/arr_cast_chain.ad" \
    >"$WORK/objdiff.log" 2>&1 \
    || { tail -20 "$WORK/objdiff.log"; fail "seed<->native cast->Ptr objdiff diverged"; }
grep -q "zero semantic divergences" "$WORK/objdiff.log" \
    || { tail -20 "$WORK/objdiff.log"; fail "objdiff did not report zero divergences"; }
# All three fixtures must be native-ACCEPTED (an acceptance regression would
# silently drop a case from the differential).
grep -q "native-accepted=3" "$WORK/objdiff.log" \
    || { tail -20 "$WORK/objdiff.log"; fail "expected 3 native-accepted cast fixtures"; }
echo "[castptr]   $(grep 'semantically CLEAN' "$WORK/objdiff.log")"

echo "[castptr] PASS — cast[Ptr[T]](aggregate_local) decays to the base address,"
echo "[castptr]        seed==native byte-lockstep across Array/struct/chain fixtures (#296)."
