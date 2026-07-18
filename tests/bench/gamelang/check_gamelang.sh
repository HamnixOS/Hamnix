#!/usr/bin/env bash
# tests/bench/gamelang/check_gamelang.sh — FAST, deterministic correctness gate
# for the gamelang gap-analysis bench (no timing, no QEMU). It compiles all three
# arms (+ the native device build) and asserts they print the byte-identical
# golden checksum for the shared bouncing-sprites sim — i.e. the comparison in
# docs/gamelang_gap_analysis.md is honestly apples-to-apples. Registerable as a
# one-line CI gate. Run scripts .../bench_gamelang.sh for the timing table.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT"
OUT="build/host"; mkdir -p "$OUT"
GOLDEN="ca68e03653271261"
N=500; M=200            # small M: correctness only, runs in well under a second
fail=0
say(){ echo "[gamelang-check] $*"; }

if python3 -m compiler.adder compile --target=x86_64-linux \
        tests/bench/gamelang/bounce_hamsdl_host.ad -o "$OUT/bounce_hamsdl_host" \
        >/dev/null 2>"$OUT/gamelang_ad.log"; then
    say "PASS adder host build compiled"
else
    say "FAIL adder host build"; cat "$OUT/gamelang_ad.log"; exit 1
fi

if python3 -m compiler.adder compile --target=x86_64-adder-user \
        tests/bench/gamelang/bounce_hamsdl_dev.ad -o "$OUT/bounce_hamsdl_dev.elf" \
        >/dev/null 2>"$OUT/gamelang_dev.log"; then
    say "PASS adder NATIVE device build compiled (dual-target seam intact)"
else
    say "FAIL adder native device build"; cat "$OUT/gamelang_dev.log"; exit 1
fi

if g++ -O2 tests/bench/gamelang/bounce_cpp.cpp -o "$OUT/bounce_cpp" 2>"$OUT/gamelang_cpp.log"; then
    say "PASS c++ arm compiled"
else
    say "FAIL c++ compile"; cat "$OUT/gamelang_cpp.log"; exit 1
fi

check(){ # name  golden  actual
    if [ "$3" = "$2" ]; then say "PASS $1 checksum $3"; else say "FAIL $1 checksum $3 != $2"; fail=1; fi
}
ad=$("$OUT/bounce_hamsdl_host" "$N" "$M" 2>/dev/null | awk '/^CHECKSUM/{print $2}')
cpp=$("$OUT/bounce_cpp" "$N" "$M" 2>/dev/null | awk '/^CHECKSUM/{print $2}')
# recompute the golden for THIS (N,M) so the gate is self-contained
gold=$(python3 - "$N" "$M" <<'PY'
import sys
W,H,SPR=640,480,8; N=int(sys.argv[1]); M=int(sys.argv[2])
s=12345
def nx():
    global s; s=(s*1103515245+12345)&0xffffffff; return (s>>16)&0x7fff
x=[0]*N;y=[0]*N;vx=[0]*N;vy=[0]*N
for i in range(N):
    x[i]=nx()%(W-SPR);y[i]=nx()%(H-SPR)
    vx[i]=(nx()%5)-2 or 1; vy[i]=(nx()%5)-2 or 1
for _ in range(M):
    for i in range(N):
        x[i]+=vx[i]
        if x[i]<0:x[i]=0;vx[i]=-vx[i]
        elif x[i]>W-SPR:x[i]=W-SPR;vx[i]=-vx[i]
        y[i]+=vy[i]
        if y[i]<0:y[i]=0;vy[i]=-vy[i]
        elif y[i]>H-SPR:y[i]=H-SPR;vy[i]=-vy[i]
c=0
for i in range(N): c=(c*31+x[i]*7+y[i]*13+(vx[i]+8)+(vy[i]+8)*4)&0xffffffffffffffff
print("%016x"%c)
PY
)
check "adder+hamSDL" "$gold" "$ad"
check "c++ SW-blit"  "$gold" "$cpp"
if python3 -c "import pygame" >/dev/null 2>&1; then
    py=$(python3 tests/bench/gamelang/bounce_pygame.py "$N" "$M" 2>/dev/null | awk '/^CHECKSUM/{print $2}')
    check "python+pygame" "$gold" "$py"
else
    say "SKIP python+pygame (pygame not importable on this host)"
fi

if [ "$fail" = 0 ]; then say "RESULT: PASS (all arms agree, dual-target compiles)"; exit 0
else say "RESULT: FAIL"; exit 1; fi
