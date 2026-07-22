#!/usr/bin/env bash
# scripts/bench_llvm.sh — 4-way benchmark for the OPTIONAL LLVM backend spike
# (adder/compiler/ssa_llvm.ad): Adder-native-SSA vs Adder-LLVM-backend vs
# gcc-O0 vs gcc-O2, on the tests/bench/opt/*.ad kernels.
#
# All four are real x86_64-linux host ELFs timed on one CPU, checksum-verified
# across configs before timing (same discipline as scripts/bench_opt.sh). The
# LLVM path lowers the existing SSA IR to textual LLVM IR (ssa_llvm.ad) and lets
# clang-19 -O2 optimize + codegen it; it links a tiny C runtime for print_u64.
#
# Usage:
#   bash scripts/bench_llvm.sh                 # full run
#   BENCH_REPS=9 bash scripts/bench_llvm.sh    # more reps (best-of-N)
#   BENCH_CLANG=clang bash scripts/bench_llvm.sh
#
# Exit: 0 all-correct, 2 results produced w/ >=1 LLVM correctness finding,
# 1 hard failure.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

REPS="${BENCH_REPS:-7}"
LOG="build/bench_llvm/run.log"
mkdir -p build/bench_llvm

echo "[bench_llvm] CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
echo "[bench_llvm] gcc: $(gcc --version | head -1)"
echo "[bench_llvm] clang: $(${BENCH_CLANG:-clang-19} --version | head -1)"
echo "[bench_llvm] reps(best-of)=$REPS"
echo

python3 scripts/_bench_llvm_run.py --reps "$REPS" 2>&1 | tee "$LOG"
exit "${PIPESTATUS[0]}"
