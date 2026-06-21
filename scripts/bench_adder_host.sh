#!/usr/bin/env bash
# scripts/bench_adder_host.sh — host performance comparison of the
# `x86_64-linux` Adder target vs C (gcc -O0 / -O2) and CPython, across a
# spread of integer workloads. Pure host tooling: no QEMU, no Hamnix image.
#
# Each benchmark exists in three languages (tests/bench/<name>.{ad,c,py})
# computing an IDENTICAL result; the script asserts every implementation
# AGREES before timing, so the comparison is honest. This is the standing
# perf fixture: watch the Adder/-O2 ratio drop as the code optimizer
# (TODO Track 6) lands.
#
# Usage:
#   bash scripts/bench_adder_host.sh            # full run (incl. Python)
#   BENCH_SKIP_PYTHON=1 bash scripts/bench_adder_host.sh   # skip slow Python
#   BENCH_REPS=5 bash scripts/bench_adder_host.sh          # compiled best-of-N
#
# Exits non-zero on any compile failure or cross-language MISMATCH.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BENCHES="collatz fib sieve mmul lcg"
SRC="tests/bench"
WORK="build/bench_host"
REPS="${BENCH_REPS:-3}"
SKIP_PY="${BENCH_SKIP_PYTHON:-0}"

fail() { echo "[bench] FAIL $*"; exit 1; }
command -v as  >/dev/null 2>&1 || fail "as not found (apt install binutils)"
command -v ld  >/dev/null 2>&1 || fail "ld not found (apt install binutils)"
command -v gcc >/dev/null 2>&1 || fail "gcc not found"
command -v bc  >/dev/null 2>&1 || fail "bc not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the produced ELFs"

rm -rf "$WORK"; mkdir -p "$WORK"

# best wall-clock time (seconds) over $1 reps of $2..
besttime() {
    local reps="$1"; shift
    local best="" i t0 t1 dt
    for i in $(seq 1 "$reps"); do
        t0=$(date +%s.%N); "$@" >/dev/null 2>&1; t1=$(date +%s.%N)
        dt=$(echo "$t1 - $t0" | bc -l)
        if [ -z "$best" ]; then best="$dt"
        else best=$(echo "if ($dt < $best) $dt else $best" | bc -l); fi
    done
    echo "$best"
}

echo "[bench] compiling + correctness check"
for n in $BENCHES; do
    [ -f "$SRC/$n.ad" ] || fail "missing $SRC/$n.ad"
    python3 -m compiler.adder compile --target=x86_64-linux "$SRC/$n.ad" \
        -o "$WORK/${n}_adder" >/dev/null 2>"$WORK/$n.cerr" \
        || { cat "$WORK/$n.cerr"; fail "adder compile $n"; }
    gcc -O0 "$SRC/$n.c" -o "$WORK/${n}_c_O0" || fail "gcc -O0 $n"
    gcc -O2 "$SRC/$n.c" -o "$WORK/${n}_c_O2" || fail "gcc -O2 $n"
    a=$("$WORK/${n}_adder"); c0=$("$WORK/${n}_c_O0"); c2=$("$WORK/${n}_c_O2")
    { [ "$a" = "$c0" ] && [ "$a" = "$c2" ]; } \
        || fail "$n MISMATCH adder=$a c-O0=$c0 c-O2=$c2"
    if [ "$SKIP_PY" != "1" ]; then
        p=$(python3 "$SRC/$n.py"); [ "$a" = "$p" ] || fail "$n MISMATCH adder=$a py=$p"
    fi
done
echo "[bench] all benchmarks AGREE"
echo

printf "%-9s %10s %10s %10s %10s %11s\n" "bench" "Adder" "C-O0" "C-O2" "Python" "Adder/-O2"
printf "%-9s %10s %10s %10s %10s %11s\n" "-----" "-----" "----" "----" "------" "---------"
for n in $BENCHES; do
    a=$(besttime "$REPS" "$WORK/${n}_adder")
    c0=$(besttime "$REPS" "$WORK/${n}_c_O0")
    c2=$(besttime "$REPS" "$WORK/${n}_c_O2")
    ratio=$(echo "scale=2; $a / $c2" | bc -l)
    if [ "$SKIP_PY" != "1" ]; then
        p=$(besttime 1 python3 "$SRC/$n.py")
        printf "%-9s %9.3fs %9.3fs %9.3fs %9.3fs %10.2fx\n" "$n" "$a" "$c0" "$c2" "$p" "$ratio"
    else
        printf "%-9s %9.3fs %9.3fs %9.3fs %10s %10.2fx\n" "$n" "$a" "$c0" "$c2" "-" "$ratio"
    fi
done
echo
echo "[bench] done (compiled best-of-$REPS; Python best-of-1). See docs/bench_adder_host.md."
