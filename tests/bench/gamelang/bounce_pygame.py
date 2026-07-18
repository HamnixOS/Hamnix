#!/usr/bin/env python3
# tests/bench/gamelang/bounce_pygame.py — Python + pygame arm of the
# bouncing-sprites bench.
#
# TOOL NOTE: pygame IS installed on this host (pygame 2.6.1 / SDL 2.28.4), so
# this is a REAL pygame program driving a REAL SDL2 renderer — the only genuine
# SDL2 measurement available here (there is no libsdl2-dev to compile the C++
# arm against). It runs under the SDL "dummy" video driver so it works headless;
# screen.fill + pygame.draw.rect still perform the full software surface blit
# (SDL2's CPU path), which is what we time. flip() on the dummy driver is a cheap
# no-op copy. This measures pygame/SDL2 software 2D, NOT SDL2's GPU-accelerated
# render-to-texture path (see docs/gamelang_gap_analysis.md).
#
# Byte-identical integer simulation to bounce_game.ad / bounce_cpp.cpp; prints
# the same "CHECKSUM %016x" invariant.
#
#   USAGE:  bounce_pygame.py [N] [M]      (defaults N=500 M=2000)

import os
import sys

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

import pygame  # noqa: E402

W, H, SPR, NMAX = 640, 480, 8, 512
MASK32 = 0xFFFFFFFF
MASK64 = 0xFFFFFFFFFFFFFFFF

N = int(sys.argv[1]) if len(sys.argv) >= 2 else 500
M = int(sys.argv[2]) if len(sys.argv) >= 3 else 2000
if N > NMAX:
    N = NMAX

_lcg = 12345


def bnext():
    global _lcg
    _lcg = (_lcg * 1103515245 + 12345) & MASK32
    return (_lcg >> 16) & 0x7FFF


bx = [0] * N
by = [0] * N
bvx = [0] * N
bvy = [0] * N
col = [(0, 0, 0)] * N
for i in range(N):
    bx[i] = bnext() % (W - SPR)
    by[i] = bnext() % (H - SPR)
    vx = (bnext() % 5) - 2
    if vx == 0:
        vx = 1
    bvx[i] = vx
    vy = (bnext() % 5) - 2
    if vy == 0:
        vy = 1
    bvy[i] = vy
    col[i] = ((i * 7) & 255, (i * 13) & 255, (i * 5 + 64) & 255)

pygame.init()
screen = pygame.display.set_mode((W, H))
BG = (10, 12, 20)

for _f in range(M):
    for i in range(N):
        bx[i] += bvx[i]
        if bx[i] < 0:
            bx[i] = 0
            bvx[i] = -bvx[i]
        elif bx[i] > W - SPR:
            bx[i] = W - SPR
            bvx[i] = -bvx[i]
        by[i] += bvy[i]
        if by[i] < 0:
            by[i] = 0
            bvy[i] = -bvy[i]
        elif by[i] > H - SPR:
            by[i] = H - SPR
            bvy[i] = -bvy[i]
    screen.fill(BG)
    for i in range(N):
        pygame.draw.rect(screen, col[i], (bx[i], by[i], SPR, SPR))
    pygame.display.flip()

chk = 0
for i in range(N):
    chk = (chk * 31 + bx[i] * 7 + by[i] * 13 + (bvx[i] + 8) + (bvy[i] + 8) * 4) & MASK64
print("CHECKSUM %016x" % chk)
