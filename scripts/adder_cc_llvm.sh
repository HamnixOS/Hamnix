#!/usr/bin/env bash
# scripts/adder_cc_llvm.sh — build wrapper for the OPTIONAL Adder LLVM backend
# (adder/compiler/ssa_llvm.ad, wired into host_ac.elf as `--backend=llvm`).
#
# Mirrors scripts/_adder_cc.sh's `--emit-asm`->`as` build glue, but for the
# LLVM lane: the self-hosted host compiler EMITS textual LLVM IR (.ll) — it is a
# static no-libc ELF and does NOT invoke clang itself — then THIS wrapper hands
# the .ll to clang, which runs LLVM's optimizer + code generator and links a
# tiny C runtime (scripts/adder_llvm_runtime.c) supplying the prelude helpers
# (print_u64) that fall outside the SSA integer subset and emit as `declare`s.
#
# Usage:
#   scripts/adder_cc_llvm.sh <in.ad> <out-elf> [extra clang args...]
#
# Env:
#   ADDER_HOST_AC  path to the LLVM-capable host_ac.elf (default:
#                  build/cutover/host_ac_llvm.elf; falls back to
#                  build/cutover/host_ac.elf).
#   BENCH_CLANG    clang binary (default: clang-19, then clang).
#   ADDER_LLVM_RUNTIME  extra/replacement C runtime (default: the stub above).
#   ADDER_LLVM_CLANG_OPT clang optimisation level (default: -O2).
#
# Exit: 0 on a built+linked ELF; nonzero on emit/compile/link failure. Prints
# the emitted .ll's `; ADDER_STAT` (funcs/emitted/bailed) line to stderr.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

if [ $# -lt 2 ]; then
    echo "usage: adder_cc_llvm.sh <in.ad> <out-elf> [clang args...]" >&2
    exit 2
fi
IN_AD="$1"; OUT_ELF="$2"; shift 2

HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac_llvm.elf}"
if [ ! -x "$HOST_AC" ]; then
    HOST_AC="build/cutover/host_ac.elf"
fi
[ -x "$HOST_AC" ] || { echo "[adder_cc_llvm] ERROR: no host_ac.elf ($HOST_AC); build it first (scripts/_adder_cc.sh adder_cc_bootstrap)" >&2; exit 1; }

CLANG="${BENCH_CLANG:-}"
if [ -z "$CLANG" ]; then
    if command -v clang-19 >/dev/null 2>&1; then CLANG=clang-19; else CLANG=clang; fi
fi
command -v "$CLANG" >/dev/null 2>&1 || { echo "[adder_cc_llvm] ERROR: $CLANG not found" >&2; exit 1; }

RUNTIME="${ADDER_LLVM_RUNTIME:-$PROJ_ROOT/scripts/adder_llvm_runtime.c}"
[ -f "$RUNTIME" ] || { echo "[adder_cc_llvm] ERROR: runtime $RUNTIME missing" >&2; exit 1; }
OPTLVL="${ADDER_LLVM_CLANG_OPT:--O2}"

LL="${OUT_ELF%.elf}.ll"
[ "$LL" = "$OUT_ELF" ] && LL="$OUT_ELF.ll"

# 1) host_ac.elf emits the whole module as textual LLVM IR.
if ! "$HOST_AC" --backend=llvm "$IN_AD" "$LL"; then
    echo "[adder_cc_llvm] ERROR: host_ac --backend=llvm failed on $IN_AD" >&2
    exit 1
fi
grep -E "^; ADDER_STAT" "$LL" >&2 || true

if ! grep -q "^define i64 @main(" "$LL"; then
    echo "[adder_cc_llvm] ERROR: no @main emitted (its body bailed the SSA subset); .ll=$LL" >&2
    exit 1
fi

# 2) clang runs LLVM opt+codegen on the .ll and links the C runtime.
if ! "$CLANG" "$OPTLVL" "$LL" "$RUNTIME" "$@" -o "$OUT_ELF"; then
    echo "[adder_cc_llvm] ERROR: clang link failed for $LL" >&2
    exit 1
fi
echo "[adder_cc_llvm] built $OUT_ELF (via $HOST_AC + $CLANG $OPTLVL)" >&2
exit 0
