#!/usr/bin/env bash
# scripts/bench_opt.sh — repeatable performance benchmark comparing FOUR
# configurations on a suite of compute-bound microbenchmarks:
#
#   1. Adder, optimizer OFF  (native codegen.ad, no --opt)        — baseline
#   2. Adder, optimizer ON   (native codegen.ad WITH --opt)       — the 6-pass
#                            optimizer: const-fold, CSE, LICM, DCE,
#                            constant-condition branch-fold, copy-propagation
#   3. C, gcc -O0            (unoptimized C)
#   4. C, gcc -O2            (optimized C)
#
# All four are real x86_64-linux ELFs timed as host processes on ONE CPU (the
# Adder native compiler's host path wraps codegen.ad's machine code into an
# ELF64 EM_X86_64 executable — see tests/fuzz/ad_codegen_host.py), so the
# comparison is fair: same CPU, same ABI, no QEMU/VM timer skew. Pure host
# tooling — no Hamnix image, no QEMU boot.
#
# Each kernel (tests/bench/opt/<name>.{ad,c}) prints a checksum; the harness
# asserts the checksum AGREES across all four builds before timing (a wrong
# answer is not a benchmark). Kernels that MISCOMPILE under ADDER_OPT=1 are
# reported as a correctness FINDING and excluded from the speed comparison.
#
# Usage:
#   bash scripts/bench_opt.sh                 # full run (writes the results doc)
#   BENCH_REPS=9 bash scripts/bench_opt.sh    # more reps (best-of-N)
#   BENCH_NO_DOC=1 bash scripts/bench_opt.sh  # print only; don't rewrite the doc
#
# Exit status: 0 all-correct, 2 results produced but >=1 ADDER_OPT=1 miscompile,
# 1 hard failure (compile error / baseline mismatch / missing tool).
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

REPS="${BENCH_REPS:-7}"
DOC="docs/bench_opt_results.md"
LOG="build/bench_opt/run.log"
mkdir -p build/bench_opt

echo "[bench_opt] CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
echo "[bench_opt] gcc: $(gcc --version | head -1)"
echo "[bench_opt] reps(best-of)=$REPS"
echo

python3 scripts/_bench_opt_run.py --reps "$REPS" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

if [ "${BENCH_NO_DOC:-0}" != "1" ]; then
    python3 scripts/_bench_opt_gendoc.py "$LOG" "$DOC" \
        && echo "[bench_opt] wrote $DOC"
fi

if [ "$rc" = "2" ]; then
    echo "[bench_opt] NOTE: results produced, but >=1 kernel MISCOMPILES under ADDER_OPT=1 (see $DOC)."
fi
exit "$rc"
