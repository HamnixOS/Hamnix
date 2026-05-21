/*
 * tests/u-binary/src/musl_clock/clock.c — clock_gettime fixture.
 *
 * Verifies Hamnix's clock_gettime(2) syscall (Linux x86_64 nr 228)
 * now that arch/x86/kernel/time.ad backs it with a TSC-derived
 * high-resolution monotonic clock instead of the old 10 ms jiffies
 * derivation.
 *
 * What this checks (markers on stdout, one line each):
 *
 *   "U-clock: monotonic t0 ok"
 *       clock_gettime(CLOCK_MONOTONIC) succeeds and yields a
 *       non-negative timespec.
 *
 *   "U-clock: monotonic advanced"
 *       a second CLOCK_MONOTONIC read, taken after a bounded busy
 *       spin, is STRICTLY GREATER than the first — the clock moved
 *       forward and never backward.
 *
 *   "U-clock: hires ok"
 *       the elapsed nanoseconds across the busy spin are NOT a whole
 *       multiple of 10 ms — i.e. the clock has sub-jiffy resolution.
 *       The old jiffies-derived handler could only ever report
 *       multiples of 10000000 ns, so a non-multiple proves the TSC
 *       high-resolution source is live.
 *
 *   "U-clock: realtime ok"
 *       clock_gettime(CLOCK_REALTIME) yields a plausible wall-clock
 *       value — seconds well past the 2020 Unix epoch (1577836800),
 *       proving the RTC boot epoch + monotonic delta wiring works.
 *
 * Any failed check emits "U-clock: <name> FAIL" instead; the test
 * script (scripts/test_u_clock.sh) greps for the four PASS markers.
 *
 * Raw inline syscalls are used throughout so the test does not depend
 * on musl's clock_gettime() wrapper (which on some musl versions
 * routes through a vDSO probe). Build: musl-gcc -static-pie -O2.
 */

#include <stdint.h>

struct ts { long tv_sec; long tv_nsec; };

#define SYS_write          1
#define SYS_clock_gettime  228

#define CLOCK_REALTIME   0
#define CLOCK_MONOTONIC  1

static long sys_clock_gettime(long clk, struct ts *tp) {
    long ret;
    register long r10 __asm__("r10") = 0;
    __asm__ volatile (
        "syscall"
        : "=a"(ret)
        : "a"((long)SYS_clock_gettime), "D"(clk), "S"(tp), "d"(0), "r"(r10)
        : "rcx", "r11", "memory"
    );
    return ret;
}

static void write_str(const char *s) {
    long n = 0;
    while (s[n]) n++;
    __asm__ volatile (
        "syscall"
        : : "a"((long)SYS_write), "D"(1L), "S"(s), "d"(n)
        : "rcx", "r11", "memory"
    );
}

/* Minimal unsigned-decimal print so a failure transcript carries the
 * actual numbers (helps diagnose a wrong-rate calibration). */
static void write_u64(uint64_t v) {
    char buf[24];
    int i = 24;
    if (v == 0) { write_str("0"); return; }
    while (v) { buf[--i] = (char)('0' + (v % 10)); v /= 10; }
    char out[24];
    int j = 0;
    while (i < 24) out[j++] = buf[i++];
    out[j] = 0;
    write_str(out);
}

int main(void) {
    struct ts t0, t1, rt;

    /* --- CLOCK_MONOTONIC, first read --- */
    if (sys_clock_gettime(CLOCK_MONOTONIC, &t0) != 0
        || t0.tv_sec < 0 || t0.tv_nsec < 0 || t0.tv_nsec >= 1000000000L) {
        write_str("U-clock: monotonic t0 FAIL\n");
        return 1;
    }
    write_str("U-clock: monotonic t0 ok\n");

    /* Bounded busy spin so the two reads straddle a real interval.
     * `volatile` defeats -O2 dead-loop elimination. */
    for (volatile uint64_t i = 0; i < 8000000ULL; i++) { }

    /* --- CLOCK_MONOTONIC, second read --- */
    if (sys_clock_gettime(CLOCK_MONOTONIC, &t1) != 0) {
        write_str("U-clock: monotonic t1 FAIL\n");
        return 1;
    }

    uint64_t ns0 = (uint64_t)t0.tv_sec * 1000000000ULL + (uint64_t)t0.tv_nsec;
    uint64_t ns1 = (uint64_t)t1.tv_sec * 1000000000ULL + (uint64_t)t1.tv_nsec;

    if (ns1 <= ns0) {
        write_str("U-clock: monotonic advanced FAIL ns0=");
        write_u64(ns0);
        write_str(" ns1=");
        write_u64(ns1);
        write_str("\n");
        return 1;
    }
    uint64_t delta = ns1 - ns0;
    write_str("U-clock: monotonic advanced (delta_ns=");
    write_u64(delta);
    write_str(")\n");

    /* High-resolution check: the old jiffies-derived handler could
     * only report multiples of 10 ms (10000000 ns). A delta that is
     * not such a multiple proves the TSC sub-jiffy clock is live.
     * (The busy spin is many ms long, so a delta that happened to
     * land exactly on a 10 ms boundary is astronomically unlikely —
     * but if it did, this would false-FAIL; the script tolerates one
     * retry by treating a clean transcript as the source of truth.) */
    if (delta != 0 && (delta % 10000000ULL) != 0) {
        write_str("U-clock: hires ok\n");
    } else {
        write_str("U-clock: hires FAIL (delta is a 10ms multiple)\n");
        return 1;
    }

    /* --- CLOCK_REALTIME --- */
    if (sys_clock_gettime(CLOCK_REALTIME, &rt) != 0) {
        write_str("U-clock: realtime FAIL (syscall)\n");
        return 1;
    }
    /* 1577836800 = 2020-01-01 UTC. A real RTC epoch is well past it. */
    if ((uint64_t)rt.tv_sec > 1577836800ULL) {
        write_str("U-clock: realtime ok (epoch=");
        write_u64((uint64_t)rt.tv_sec);
        write_str(")\n");
    } else {
        write_str("U-clock: realtime FAIL (epoch=");
        write_u64((uint64_t)rt.tv_sec);
        write_str(")\n");
        return 1;
    }

    write_str("U-clock: done\n");
    return 0;
}
