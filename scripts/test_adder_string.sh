#!/usr/bin/env bash
# scripts/test_adder_string.sh — Adder heap/byte-backed `String` VIEW type +
# core string helpers (language roadmap increment 7-tail). HOST-ONLY, NO QEMU.
#
# A `String` is a 16-byte {ptr@0, len@8} by-reference aggregate VIEW over
# caller-owned bytes — representationally a Slice[uint8], but with
# string-flavoured construction (`String("lit")` interns the literal) and
# accessors (`.ptr`/`.cstr` round-trip to the raw Ptr[uint8] C-string world,
# `.len` is the byte length). The bytes are caller-owned (a .rodata literal, a
# stack Array, an mmap'd/kmalloc'd buffer); String owns no allocator. The core
# methods (eq / find / contains / substring-view / concat-into-buffer) live in
# lib/strview.ad as ORDINARY Adder over raw (ptr,len) pairs — so they compile
# through the byte-tested path and are seed<->native lockstep for free.
#
# STATUS: SEED + NATIVE. `String` is native since increment 11/#309 (bound
# locals) and #312 (member access on an UNBOUND `String(...)` temporary, e.g.
# `String(" world").ptr` — no bind-to-a-local first). The native backend emits
# byte-identically to the seed (objdiff-clean), so String-using units are
# seed<->native lockstep, not seed-only. See docs/adder_language_roadmap.md.
#
# Verifies end to end:
#   (1) BEHAVIOUR: construct-from-literal, .len/.ptr/.cstr (NUL round-trip),
#       (ptr,len) construction, substring VIEW, and lib/strview.ad
#       eq/find/contains/concat_into — the checksum lands on 42 iff all correct.
#   (2) ON-DEVICE: the same source compiles for x86_64-adder-user.
#   (3) KERNEL ZERO-COST: String is pure pointer math — a String source for
#       x86_64-bare-metal emits NO allocator/heap runtime call (no `call
#       malloc/kmalloc/__str*`), and lib/strview.ad compiles for the kernel.
#   (4) LOCKSTEP: lib/strview.ad (the helper layer) compiles seed==native,
#       byte-identical (objdiff 0 divergences) — native accepts the String-free
#       helpers cleanly.
#   (5) NATIVE ACCEPTS STRING: the native `.ad` backend ACCEPTS a String-typed
#       source (bound local + an UNBOUND `String(...).ptr` temporary), emits an
#       ELF, and its bytes match the seed (objdiff-clean) — a real port, not a
#       miscompile. The roadmap fixture tests/string/string_smoke.ad (which uses
#       the unbound `String(" world").ptr` form) native-compiles too (#312).
#
# Usage:  bash scripts/test_adder_string.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
source scripts/_adder_cc.sh

fail() { echo "[string] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/string"
WORK="build/string_check"
mkdir -p "$WORK"

echo "[string] (1) construct/len/ptr/cstr/eq/find/contains/substr/concat -> 42"
python3 -m compiler.adder compile "$FIX/string_smoke.ad" --target=x86_64-linux \
    -o "$WORK/smoke" >/dev/null 2>"$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "compile failed: string_smoke.ad"; }
"$WORK/smoke"; rc=$?
echo "[string]   string_smoke exit status = $rc (expect 42)"
[ "$rc" -eq 42 ] || fail "string smoke returned $rc, expected 42"

echo "[string] (2) same source compiles for x86_64-adder-user (on-device ELF)"
python3 -m compiler.adder compile "$FIX/string_smoke.ad" \
    --target=x86_64-adder-user -o "$WORK/smoke.user.elf" \
    >/dev/null 2>"$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "x86_64-adder-user compile failed"; }
echo "[string]   x86_64-adder-user ELF built ($(stat -c%s "$WORK/smoke.user.elf") bytes)"

echo "[string] (3) kernel zero-cost: bare-metal String emits no allocator call"
# Self-contained String source (no imports) — `asm` compiles a single unit.
python3 -m compiler.adder asm "$FIX/string_native_probe.ad" \
    --target=x86_64-bare-metal >"$WORK/km.s" 2>/dev/null \
    || fail "bare-metal String source failed to compile"
n=$(grep -Ec 'call[[:space:]]+(malloc|kmalloc|__str|__string|mmap)' "$WORK/km.s")
echo "[string]   allocator/heap runtime calls (bare-metal) = $n (expect 0)"
[ "$n" -eq 0 ] || fail "String dragged a heap runtime into the kernel path"
python3 -m compiler.adder asm lib/strview.ad --target=x86_64-bare-metal \
    >/dev/null 2>&1 || fail "lib/strview.ad failed to compile for the kernel"
echo "[string]   lib/strview.ad compiles for x86_64-bare-metal (kernel-safe)"

echo "[string] (4) seed<->native byte-lockstep on the String helper LAYER"
# The helper algorithms (eq/find/concat) over raw (ptr,len) pairs, in a
# self-contained program the native backend accepts, objdiffed seed vs native.
# First confirm the helper behaviour itself is correct (checksum 11).
python3 -m compiler.adder compile "$FIX/strview_lockstep.ad" \
    --target=x86_64-linux -o "$WORK/lockstep" >/dev/null 2>"$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "compile failed: strview_lockstep.ad"; }
"$WORK/lockstep"; rc=$?
echo "[string]   strview_lockstep exit status = $rc (expect 11)"
[ "$rc" -eq 11 ] || fail "helper self-test returned $rc, expected 11"
bash scripts/test_native_vs_seed_objdiff.sh "$FIX/strview_lockstep.ad" \
    >"$WORK/objdiff.log" 2>&1 \
    || { tail -20 "$WORK/objdiff.log"; fail "seed<->native helper objdiff diverged"; }
grep -q "zero semantic divergences" "$WORK/objdiff.log" \
    || { tail -20 "$WORK/objdiff.log"; fail "objdiff did not report zero divergences"; }
grep -q "native-accepted=1" "$WORK/objdiff.log" \
    || { tail -20 "$WORK/objdiff.log"; fail "native did not accept the helper unit"; }
echo "[string]   $(grep 'PASS' "$WORK/objdiff.log" | head -1)"

echo "[string] (5) native backend ACCEPTS String (bound + unbound temp), no miscompile"
adder_cc_bootstrap || fail "could not bootstrap the native host_ac.elf"
HOST_AC="build/cutover/host_ac.elf"
[ -x "$HOST_AC" ] || fail "native host_ac.elf not built"
# Invoke host_ac.elf DIRECTLY (not adder_cc_compile) so the Python-seed
# fallback can't mask a native rejection — the native backend must accept it.
rm -f "$WORK/probe.elf"
"$HOST_AC" --target=x86_64-adder-user "$FIX/string_native_probe.ad" \
        "$WORK/probe.elf" >"$WORK/native.log" 2>&1 \
    || { cat "$WORK/native.log"; fail "native backend REJECTED a bound String source"; }
[ -s "$WORK/probe.elf" ] \
    || fail "native accepted String but emitted no ELF"
echo "[string]   native accepted a bound String source ($(stat -c%s "$WORK/probe.elf") bytes)"

# #312: member access on an UNBOUND String(...) temporary — the roadmap's own
# string_smoke.ad uses `String(" world").ptr`, which the native backend rejected
# before the fix. It must native-compile now.
rm -f "$WORK/smoke.native.elf"
"$HOST_AC" --target=x86_64-adder-user "$FIX/string_smoke.ad" \
        "$WORK/smoke.native.elf" >"$WORK/native.smoke.log" 2>&1 \
    || { cat "$WORK/native.smoke.log"; fail "native REJECTED string_smoke.ad (unbound String(...).ptr — #312)"; }
[ -s "$WORK/smoke.native.elf" ] \
    || fail "native accepted string_smoke.ad but emitted no ELF"
echo "[string]   native compiled string_smoke.ad ($(stat -c%s "$WORK/smoke.native.elf") bytes; unbound String(...).ptr)"

# The temporary-member acceptance fixture is byte-identical seed<->native.
bash scripts/test_native_vs_seed_objdiff.sh "$FIX/string_temp_member.ad" \
    >"$WORK/objdiff_tm.log" 2>&1 \
    || { tail -20 "$WORK/objdiff_tm.log"; fail "String temporary-member objdiff diverged"; }
grep -q "zero semantic divergences" "$WORK/objdiff_tm.log" \
    || { tail -20 "$WORK/objdiff_tm.log"; fail "temp-member objdiff not zero-divergence"; }
echo "[string]   String temporary-member fixture seed==native (objdiff-clean)"

echo "[string] PASS — String construct/len/ptr/cstr/eq/find/contains/substr/"
echo "[string]        concat-into-buffer correct, on-device + kernel-safe,"
echo "[string]        helper layer seed==native, native accepts String"
echo "[string]        (bound + unbound String(...).ptr temp; string_smoke native)."
