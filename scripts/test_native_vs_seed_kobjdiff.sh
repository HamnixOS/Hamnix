#!/usr/bin/env bash
# scripts/test_native_vs_seed_kobjdiff.sh — SYSTEMATIC native-vs-seed
# machine-code differential over the bare-metal KERNEL (init/main.ad,
# --target=x86_64-bare-metal). The kernel counterpart of
# scripts/test_native_vs_seed_objdiff.sh (which only covers user/*.ad).
#
# WHY: the userland objdiff proved all user codegen byte-identical, but the
# self-hosting cutover's remaining boot divergences are KERNEL-ONLY — the
# kernel target was NOT in any differential corpus, so kernel codegen bugs
# slipped through silently. This closes that gap.
#
# THE METHOD (host-only, NO QEMU):
#   1. Bootstrap build/cutover/host_ac.elf via the Python seed.
#   2. SEED kernel object: `compile --target=x86_64-bare-metal --emit-asm`
#      writes init/main.s (the seed's GNU-as assembly); `as --64` it to a
#      relocatable ELF64 .o that carries a full symtab WITH function SIZES.
#   3. NATIVE kernel object: host_ac.elf --target=x86_64-bare-metal emits a
#      relocatable ELF64 .o directly (also symtab-bearing; FUNC st_size==0,
#      derived from next-symbol).
#   4. kobjdiff_normalize.py aligns PER SYMBOL NAME (reconciling the seed's
#      module-path-mangled private names against the native bare names) and
#      diffs each function with the SAME semantic histogram the userland
#      harness uses (width/opcode-class/missing-op survive; register
#      scheduling / spills / addresses / relocs are normalized away).
#
# Output: the list of kernel functions whose normalized instruction streams
# diverge SEMANTICALLY. Zero = the native kernel codegen matches the seed.
#
# Env:
#   KOBJDIFF_ONLY="fn1,fn2"   restrict the diff to named functions
#   KOBJDIFF_STRICT_BRANCH=1  promote branch-signedness deltas to failures
#   OBJDIFF_VERBOSE=1         per-function notes + reconciliation stats
#
# Usage:  bash scripts/test_native_vs_seed_kobjdiff.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "[kobjdiff] FATAL $*" >&2; exit 1; }
command -v as >/dev/null      || fail "as missing"
command -v objdump >/dev/null || fail "objdump missing"
command -v readelf >/dev/null || fail "readelf missing"

OUT="${HAMNIX_BUILD_DIR:-build}/kobjdiff"
mkdir -p "$OUT"

# 1) host_ac.elf (native compiler), built by the seed.
# shellcheck source=_adder_cc.sh
source scripts/_adder_cc.sh
ADDER_CC=adder PROJ_ROOT="$ROOT" adder_cc_bootstrap >/dev/null 2>&1 \
    || fail "host_ac.elf bootstrap failed"
[ -x "$ROOT/build/cutover/host_ac.elf" ] || fail "no host_ac.elf produced"

# 2) SEED kernel .o (via --emit-asm + as). The seed driver also tries to LINK
#    (and fails on the build-provided initramfs_cpio_* externs) — that link
#    failure is EXPECTED and irrelevant; the .s is written before the link, so
#    we ignore the driver's exit code and assemble the .s ourselves.
python3 -m compiler.adder compile --target=x86_64-bare-metal --emit-asm \
    init/main.ad -o "$OUT/main.seed.elf" >/dev/null 2>&1 || true
[ -s init/main.s ] || fail "seed --emit-asm did not write init/main.s"
as --64 -o "$OUT/main.seed.o" init/main.s 2>"$OUT/seed.as.err" \
    || { cat "$OUT/seed.as.err" >&2; fail "as init/main.s failed"; }
rm -f init/main.s

# 3) NATIVE kernel .o (host_ac emits the relocatable object directly).
"$ROOT/build/cutover/host_ac.elf" --target=x86_64-bare-metal \
    init/main.ad "$OUT/main.native.o" >"$OUT/native.emit.log" 2>&1 \
    || { cat "$OUT/native.emit.log" >&2; fail "host_ac kernel .o emit failed"; }
[ -s "$OUT/main.native.o" ] || fail "no native kernel .o produced"

# 4) Diff per symbol name.
python3 scripts/kobjdiff_normalize.py "$OUT/main.seed.o" "$OUT/main.native.o"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "[kobjdiff] FAIL — kernel codegen diverges (see list above)" >&2
    exit 1
fi
echo "[kobjdiff] PASS — native kernel codegen matches the seed (semantic)."
exit 0
