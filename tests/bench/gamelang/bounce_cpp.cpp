// tests/bench/gamelang/bounce_cpp.cpp — C++ arm of the bouncing-sprites bench.
//
// TOOL CAVEAT: this host has g++ but NO libsdl2-dev (pkg-config sdl2 absent), so
// a straight SDL2 program cannot be built here. This is therefore a pure-C++
// SOFTWARE-BLIT implementation: it writes sprites into its own RGB framebuffer
// with hand-written loops (no SDL). That makes it the honest "what a hand-rolled
// C++ software rasterizer costs" baseline — the closest available analogue to
// hamSDL's software raster — NOT a measurement of SDL2's GPU-accelerated
// renderer. See docs/gamelang_gap_analysis.md for how to read this number.
//
// Byte-identical integer simulation to bounce_game.ad and bounce_pygame.py; it
// prints the same "CHECKSUM %016x" invariant.
//
//   USAGE:  bounce_cpp [N] [M]        (defaults N=500 M=2000)

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static const int W = 640, H = 480, SPR = 8, NMAX = 512;
static int bx[NMAX], by[NMAX], bvx[NMAX], bvy[NMAX];
static int bn = 0;
static uint32_t lcg = 12345;
static uint8_t *fb = nullptr;

static inline int bnext() {
    lcg = lcg * 1103515245u + 12345u;      // wraps mod 2^32, like the .ad / .py
    return (int)((lcg >> 16) & 0x7fff);
}

static void bounce_init(int n) {
    if (n > NMAX) n = NMAX;
    bn = n;
    lcg = 12345;
    for (int i = 0; i < n; i++) {
        bx[i] = bnext() % (W - SPR);
        by[i] = bnext() % (H - SPR);
        int vx = (bnext() % 5) - 2; if (vx == 0) vx = 1; bvx[i] = vx;
        int vy = (bnext() % 5) - 2; if (vy == 0) vy = 1; bvy[i] = vy;
    }
}

static void bounce_step() {
    for (int i = 0; i < bn; i++) {
        bx[i] += bvx[i];
        if (bx[i] < 0)            { bx[i] = 0;         bvx[i] = -bvx[i]; }
        else if (bx[i] > W - SPR) { bx[i] = W - SPR;   bvx[i] = -bvx[i]; }
        by[i] += bvy[i];
        if (by[i] < 0)            { by[i] = 0;         bvy[i] = -bvy[i]; }
        else if (by[i] > H - SPR) { by[i] = H - SPR;   bvy[i] = -bvy[i]; }
    }
}

static inline void fill_rect(int x, int y, int w, int h,
                             uint8_t r, uint8_t g, uint8_t b) {
    for (int yy = y; yy < y + h; yy++) {
        uint8_t *row = fb + (yy * W + x) * 3;
        for (int xx = 0; xx < w; xx++) {
            *row++ = r; *row++ = g; *row++ = b;
        }
    }
}

static void bounce_render() {
    // Clear the backdrop (full-screen software fill, like hamSDL/pygame do).
    for (int p = 0; p < W * H; p++) { fb[p*3] = 10; fb[p*3+1] = 12; fb[p*3+2] = 20; }
    for (int i = 0; i < bn; i++) {
        fill_rect(bx[i], by[i], SPR, SPR,
                  (uint8_t)((i * 7) & 255),
                  (uint8_t)((i * 13) & 255),
                  (uint8_t)((i * 5 + 64) & 255));
    }
}

static uint64_t bounce_checksum() {
    uint64_t chk = 0;
    for (int i = 0; i < bn; i++)
        chk = chk * 31 + (uint64_t)(bx[i]*7 + by[i]*13 + (bvx[i]+8) + (bvy[i]+8)*4);
    return chk;
}

int main(int argc, char **argv) {
    int n = (argc >= 2) ? atoi(argv[1]) : 500;
    int m = (argc >= 3) ? atoi(argv[2]) : 2000;

    fb = (uint8_t *)malloc((size_t)W * H * 3);
    bounce_init(n);

    volatile uint64_t sink = 0;            // defeat dead-store elimination of the draw
    for (int f = 0; f < m; f++) {
        bounce_step();
        bounce_render();
        sink += fb[((size_t)(f % (W * H)) * 3)];
    }

    printf("CHECKSUM %016lx\n", (unsigned long)bounce_checksum());
    fprintf(stderr, "drawsink %llu\n", (unsigned long long)sink);
    free(fb);
    return 0;
}
