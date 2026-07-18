#!/usr/bin/env bash
# tests/bench/gamelang/bench_gamelang.sh — the gamelang gap-analysis bench.
#
# Times the SAME bouncing-sprites workload three ways on THIS host CPU:
#   1. Adder + hamSDL   (bounce_hamsdl_host.ad, x86_64-linux, SW raster via vk2d)
#   2. C++ software-blit (bounce_cpp.cpp -O2 — NO SDL2 on this host; hand-rolled)
#   3. Python + pygame   (bounce_pygame.py — real SDL2 2.x, dummy driver, SW)
#
# All three run a bit-identical integer sim and MUST print the same CHECKSUM
# (asserted before any timing). Per-frame cost = (best-of-R at M frames minus
# best-of-R at M=0 startup baseline) / M, so process startup + sprite seeding are
# subtracted out and only the frame loop (update + draw + present) is measured.
#
#   USAGE:  bash bench_gamelang.sh [N] [M] [REPS]      (defaults 500 2000 3)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"

N="${1:-500}"; M="${2:-2000}"; REPS="${3:-3}"
OUT="build/host"; mkdir -p "$OUT"
GOLDEN="ca68e03653271261"

fail() { echo "[gamelang] FAIL $*"; exit 1; }
command -v g++ >/dev/null || fail "g++ not found"
command -v bc  >/dev/null || fail "bc not found"

echo "[gamelang] building the three arms (N=$N M=$M reps=$REPS) ..."
python3 -m compiler.adder compile --target=x86_64-linux \
    tests/bench/gamelang/bounce_hamsdl_host.ad -o "$OUT/bounce_hamsdl_host" \
    >/dev/null 2>"$OUT/gamelang_ad.log" || { cat "$OUT/gamelang_ad.log"; fail "adder host compile"; }
# Native device build too — proves the dual-target seam (compile-only).
python3 -m compiler.adder compile --target=x86_64-adder-user \
    tests/bench/gamelang/bounce_hamsdl_dev.ad -o "$OUT/bounce_hamsdl_dev.elf" \
    >/dev/null 2>"$OUT/gamelang_dev.log" || { cat "$OUT/gamelang_dev.log"; fail "adder native compile"; }
g++ -O2 tests/bench/gamelang/bounce_cpp.cpp -o "$OUT/bounce_cpp" || fail "g++ compile"

HAVE_PY=1
python3 -c "import pygame" >/dev/null 2>&1 || { HAVE_PY=0; echo "[gamelang] NOTE: pygame absent — skipping the pygame arm"; }

# --- correctness: every arm must agree with the golden checksum -------------
ad=$("$OUT/bounce_hamsdl_host" "$N" "$M" 2>/dev/null | awk '/^CHECKSUM/{print $2}')
cpp=$("$OUT/bounce_cpp" "$N" "$M" 2>/dev/null | awk '/^CHECKSUM/{print $2}')
[ "$ad"  = "$GOLDEN" ] || fail "adder checksum $ad != golden $GOLDEN"
[ "$cpp" = "$GOLDEN" ] || fail "c++ checksum $cpp != golden $GOLDEN"
if [ "$HAVE_PY" = 1 ]; then
    py=$(python3 tests/bench/gamelang/bounce_pygame.py "$N" "$M" 2>/dev/null | awk '/^CHECKSUM/{print $2}')
    [ "$py" = "$GOLDEN" ] || fail "pygame checksum $py != golden $GOLDEN"
fi
echo "[gamelang] all arms AGREE on checksum $GOLDEN"
echo

# best wall-clock seconds over $1 reps of the remaining args
besttime() {
    local reps="$1"; shift; local best="" i t0 t1 dt
    for i in $(seq 1 "$reps"); do
        t0=$(date +%s.%N); "$@" >/dev/null 2>&1; t1=$(date +%s.%N)
        dt=$(echo "$t1 - $t0" | bc -l)
        if [ -z "$best" ]; then best="$dt"; else best=$(echo "if ($dt<$best) $dt else $best" | bc -l); fi
    done
    echo "$best"
}
# per-frame milliseconds = (run(M) - run(0)) / M * 1000
perframe() { # $1 reps ; rest = command (without trailing N M)
    local reps="$1"; shift
    local trun tbase
    trun=$(besttime "$reps" "$@" "$N" "$M")
    tbase=$(besttime "$reps" "$@" "$N" 0)
    echo "scale=4; ($trun - $tbase) / $M * 1000" | bc -l
}

printf "%-22s %14s %8s\n" "arm" "ms/frame" "LOC"
printf "%-22s %14s %8s\n" "----------------------" "--------------" "--------"

loc() { grep -vcE '^\s*(#|//)?\s*$' "$1"; }  # non-blank, non-pure-comment lines
LOC_AD=$(( $(loc tests/bench/gamelang/bounce_game.ad) + $(loc tests/bench/gamelang/bounce_hamsdl_host.ad) ))
LOC_CPP=$(loc tests/bench/gamelang/bounce_cpp.cpp)
LOC_PY=$(loc tests/bench/gamelang/bounce_pygame.py)

ms_ad=$(perframe "$REPS" "$OUT/bounce_hamsdl_host")
printf "%-22s %13.4f %8s\n" "Adder+hamSDL (SW)" "$ms_ad" "$LOC_AD"
ms_cpp=$(perframe "$REPS" "$OUT/bounce_cpp")
printf "%-22s %13.4f %8s\n" "C++ SW-blit -O2" "$ms_cpp" "$LOC_CPP"
if [ "$HAVE_PY" = 1 ]; then
    ms_py=$(perframe "$REPS" python3 tests/bench/gamelang/bounce_pygame.py)
    printf "%-22s %13.4f %8s\n" "Python+pygame (SDL2)" "$ms_py" "$LOC_PY"
fi
echo
echo "[gamelang] done. See docs/gamelang_gap_analysis.md."
