#!/usr/bin/env bash
# scripts/jsbench_compare.sh — JS-engine PERFORMANCE comparison harness.
#
# Runs a suite of self-contained, pure-compute JavaScript benchmarks
# (SunSpider/Kraken-style: bit ops, math, crypto/md5/sha1, array sort,
# recursion, N-body, string assembly) through TWO engines side by side:
#
#   * hambrowse's native JS engine  (lib/web/js/, via build/host/js_host)
#   * a reference V8 JIT            (node, or chromium --headless)
#
# For each benchmark it records: does it RUN in hambrowse (correctness — the
# printed RESULT must match the reference bit-for-bit), the COMPUTE time in
# each engine, and the ratio (hambrowse / reference). hambrowse is a tree-
# walking INTERPRETER and V8 is a JIT, so a large ratio is expected; the value
# is (a) completeness — how many real benchmark kernels our JS runs — and (b)
# an honest interpreter-vs-JIT ratio that ranks where JS-engine perf work pays
# off. See docs/js_perf.md for the interpretation and the ranked gap list.
#
# TIMING NOTE (critical for honesty): node's process/V8 startup is ~90 ms and
# would dwarf these (necessarily small — see the value-arena cap in js_perf.md)
# kernels, making a naive wall-clock ratio flatter. So node COMPUTE is measured
# INTERNALLY with process.hrtime around a single cold eval of the benchmark
# source (startup excluded). hambrowse's Date.now() is frozen (no wall clock in
# the freestanding host driver), so hambrowse is timed by external wall clock —
# its own startup is ~0.9 ms (measured), i.e. <2% of every kernel, so hb
# wall-clock == hb compute for practical purposes. Both engines are timed COLD,
# single-shot (parse + run once): the fair "run this script once" comparison.
#
# Host-only, QEMU-free. Each benchmark is timed REPS times (best-of, to damp
# scheduler noise). Usage:
#   bash scripts/jsbench_compare.sh            # build if needed, run all, print table
#   REPS=5 bash scripts/jsbench_compare.sh     # more repetitions
#   JSBENCH_MD=docs/js_perf.md bash ...        # also regenerate the scorecard table

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
FIXDIR="tests/fixtures/jsbench"
REPS="${REPS:-3}"
TIMEOUT="${TIMEOUT:-60}"

# Reference JIT engine: node (V8). (chromium's V8 is the same engine; node gives
# clean internal-hrtime compute timing, so it is the reference here.)
if ! command -v node >/dev/null 2>&1; then
    echo "jsbench: node (V8 reference) not found" >&2
    exit 1
fi
REF_NAME="node $(node --version 2>/dev/null) (V8)"

# Build the host JS driver if absent or stale.
if [ ! -x "$BIN" ]; then
    echo "[jsbench] building host JS engine ..."
    mkdir -p "$OUT"
    if ! python3 -m compiler.adder compile --target=x86_64-linux \
            user/js_host.ad -o "$BIN" 2>"$OUT/jsbench_compile.log"; then
        echo "[jsbench] FAIL: js_host did not compile"; cat "$OUT/jsbench_compile.log"; exit 1
    fi
fi

# run_ref: run the benchmark through node and echo its printed RESULT (for the
# correctness check). Cold, ordinary run.
run_ref() {
    timeout "$TIMEOUT" node "$1" 2>&1 | tail -1
}

# node_compute_ms: cold, compute-only ms (process.hrtime around a single eval of
# the benchmark source; V8 startup excluded). Best-of-REPS across cold processes.
node_compute_ms() {
    local f="$1" best="" i v
    for ((i=0;i<REPS;i++)); do
        # Wrapper locals are __jb-prefixed so a benchmark's own top-level `var s`
        # etc. (indirect eval runs in global scope) can't collide with them.
        v="$(timeout "$TIMEOUT" node -e '
            const __jbfs=require("fs");
            const __jbsrc=__jbfs.readFileSync(process.argv[1],"utf8");
            const __jblog=console.log; console.log=function(){};
            const __jbt0=process.hrtime.bigint();
            (0,eval)(__jbsrc);
            const __jbt1=process.hrtime.bigint();
            console.log=__jblog;
            process.stdout.write((Number(__jbt1-__jbt0)/1e6).toFixed(3));
        ' "$f" 2>/dev/null)"
        [ -z "$v" ] && { echo "ERR"; return; }
        if [ -z "$best" ] || (( $(echo "$v < $best" | bc -l) )); then best="$v"; fi
    done
    printf "%.2f" "$best"
}

# hb_compute_ms: external wall-clock ms (hb's own startup is ~0.9 ms, negligible
# vs every kernel). Best-of-REPS.
hb_compute_ms() {
    local f="$1" best="" i t0 t1 dt rc
    for ((i=0;i<REPS;i++)); do
        t0=$(date +%s.%N)
        timeout "$TIMEOUT" "$BIN" "$f" >/dev/null 2>&1; rc=$?
        t1=$(date +%s.%N)
        if [ "$rc" -ne 0 ]; then echo "ERR"; return; fi
        dt=$(echo "($t1-$t0)*1000" | bc -l)
        if [ -z "$best" ] || (( $(echo "$dt < $best" | bc -l) )); then best="$dt"; fi
    done
    printf "%.2f" "$best"
}

printf "JS performance: hambrowse interpreter vs %s\n" "$REF_NAME"
printf "reps=%s  timeout=%ss\n\n" "$REPS" "$TIMEOUT"
printf "%-24s %-6s %10s %10s %8s\n" "benchmark" "runs?" "hb(ms)" "ref(ms)" "ratio"
printf "%-24s %-6s %10s %10s %8s\n" "------------------------" "-----" "--------" "--------" "-----"

MDROWS=""
sum_log=0.0; n_ratio=0
for f in "$FIXDIR"/*.js; do
    name="$(basename "$f" .js)"
    hb_out="$(timeout "$TIMEOUT" "$BIN" "$f" 2>&1)"; hb_rc=$?
    ref_out="$(run_ref "$f")"
    runs="Y"; ratio="-"
    if [ "$hb_rc" -ne 0 ] || [ "$hb_out" != "$ref_out" ]; then
        runs="N"
        hb_ms="ERR"; ref_ms="$(node_compute_ms "$f")"
    else
        hb_ms="$(hb_compute_ms "$f")"; ref_ms="$(node_compute_ms "$f")"
        if [ "$hb_ms" != "ERR" ] && [ "$ref_ms" != "ERR" ] && (( $(echo "$ref_ms > 0" | bc -l) )); then
            ratio="$(printf "%.1f" "$(echo "$hb_ms/$ref_ms" | bc -l)")"
            lg=$(echo "l($hb_ms/$ref_ms)" | bc -l 2>/dev/null)
            sum_log=$(echo "$sum_log + $lg" | bc -l); n_ratio=$((n_ratio+1))
        fi
    fi
    printf "%-24s %-6s %10s %10s %8s\n" "$name" "$runs" "$hb_ms" "$ref_ms" "$ratio"
    MDROWS="${MDROWS}| \`${name}\` | ${runs} | ${hb_ms} | ${ref_ms} | ${ratio} |"$'\n'
done

geo="-"
if [ "$n_ratio" -gt 0 ]; then
    geo="$(printf "%.1f" "$(echo "e($sum_log/$n_ratio)" | bc -l)")"
fi
printf "\ngeomean ratio (hb/ref) over %d running benchmarks: %sx\n" "$n_ratio" "$geo"

if [ -n "${JSBENCH_MD:-}" ]; then
    echo "[jsbench] (scorecard rows below; paste into $JSBENCH_MD)"
    echo "$MDROWS"
    echo "geomean ratio over $n_ratio benchmarks: ${geo}x"
fi
