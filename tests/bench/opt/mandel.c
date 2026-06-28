/* mandel — Mandelbrot escape-iteration count over a W x H grid. Float64 inner
 * loop; integer iteration-count checksum. Mirrors tests/bench/opt/mandel.ad
 * EXACTLY (same grid, same maxit, same escape accounting). */
#include <stdio.h>
#include <stdint.h>

int main(void) {
    int64_t W = 400, H = 300, maxit = 200;
    double four = 4.0;
    int64_t acc = 0;
    for (int64_t py = 0; py < H; py++) {
        double cy = (double)py / (double)H * 2.0 - 1.0;
        for (int64_t px = 0; px < W; px++) {
            double cx = (double)px / (double)W * 3.0 - 2.0;
            double zx = 0.0, zy = 0.0;
            int64_t it = 0;
            int64_t result = maxit;
            while (it < maxit) {
                double xx = zx * zx;
                double yy = zy * zy;
                if (xx + yy > four) {
                    result = it;
                    it = maxit;
                } else {
                    double ny = 2.0 * zx * zy + cy;
                    zx = xx - yy + cx;
                    zy = ny;
                    it = it + 1;
                }
            }
            acc += result;
        }
    }
    printf("%llu\n", (unsigned long long)(uint64_t)acc);
    return (int)(acc & 255);
}
