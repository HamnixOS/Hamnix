/*
 * tests/u-binary/src/epoll_rdy/epoll_rdy.c — #145 epoll readiness fixture.
 *
 * Exercises the Linux epoll surface bridged to the Hamnix Layer-2 shim
 * (linux_abi/u_epoll.ad uepoll_* interest-list + u_syscalls.ad):
 *
 *   1. eventfd2(0, 0)        — create an eventfd, initially NOT readable.
 *   2. epoll_create1(0)      — create an epoll set.
 *   3. epoll_ctl(ADD, efd, EPOLLIN) — register the eventfd.
 *   4. epoll_wait(timeout=0) BEFORE writing — must report 0 ready (the
 *      eventfd is empty, so the readiness probe must say "not ready").
 *   5. write(efd, 1)         — make the eventfd readable.
 *   6. epoll_wait(timeout=200ms) — must return 1, with the ready fd's
 *      events==EPOLLIN and data == the cookie we registered.
 *   7. epoll_ctl(DEL)        — drop it; a follow-up epoll_wait reports 0.
 *
 * struct epoll_event is PACKED on x86_64: u32 events @0, u64 data @4
 * (12 bytes). The kernel side reads/writes exactly that layout.
 *
 * Built musl-gcc -static-pie; OSABI stamped ELFOSABI_LINUX. Every
 * syscall is a raw inline `syscall` so the test does not depend on
 * musl's epoll wrappers.
 *
 * Markers (the harness greps these on serial):
 *   "EPOLL: empty not-ready ok"
 *   "EPOLL: ready after write ok"
 *   "EPOLL: data cookie ok"
 *   "EPOLL: del then empty ok"
 *   "epoll_rdy: PASS" / "epoll_rdy: FAIL ..."
 */

#include <stdint.h>

#define SYS_write           1
#define SYS_close           3
#define SYS_exit_group      231
#define SYS_eventfd2        290
#define SYS_epoll_create1   291
#define SYS_epoll_ctl       233
#define SYS_epoll_wait      232

#define EPOLLIN          0x001
#define EPOLL_CTL_ADD    1
#define EPOLL_CTL_DEL    2

/* struct epoll_event { u32 events; u64 data; } PACKED -> 12 bytes. */
struct epoll_event {
    uint32_t events;
    uint64_t data;
} __attribute__((packed));

static long sys1(long nr, long a) {
    long rc;
    __asm__ volatile ("syscall" : "=a"(rc)
        : "0"(nr), "D"(a) : "rcx", "r11", "memory");
    return rc;
}
static long sys2(long nr, long a, long b) {
    long rc;
    __asm__ volatile ("syscall" : "=a"(rc)
        : "0"(nr), "D"(a), "S"(b) : "rcx", "r11", "memory");
    return rc;
}
static long sys3(long nr, long a, long b, long c) {
    long rc;
    __asm__ volatile ("syscall" : "=a"(rc)
        : "0"(nr), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
    return rc;
}
static long sys4(long nr, long a, long b, long c, long d) {
    long rc;
    register long r10 __asm__("r10") = d;
    __asm__ volatile ("syscall" : "=a"(rc)
        : "0"(nr), "D"(a), "S"(b), "d"(c), "r"(r10)
        : "rcx", "r11", "memory");
    return rc;
}

static unsigned long u_strlen(const char *s) {
    unsigned long n = 0;
    while (s[n]) n++;
    return n;
}
static void puts_str(const char *s) {
    sys3(SYS_write, 1, (long)s, (long)u_strlen(s));
}
static void puts_dec_line(const char *prefix, long v) {
    char line[96];
    unsigned long p = 0;
    const char *s = prefix;
    while (*s) line[p++] = *s++;
    char tmp[24];
    int ti = 0, neg = 0;
    unsigned long uv;
    if (v < 0) { neg = 1; uv = (unsigned long)(-v); }
    else       { uv = (unsigned long)v; }
    if (uv == 0) tmp[ti++] = '0';
    while (uv) { tmp[ti++] = (char)('0' + (uv % 10)); uv /= 10; }
    if (neg) line[p++] = '-';
    while (ti) line[p++] = tmp[--ti];
    line[p++] = '\n';
    sys3(SYS_write, 1, (long)line, (long)p);
}
static void die(const char *msg) {
    puts_str(msg);
    sys1(SYS_exit_group, 1);
}

int main(void) {
    /* ---- 1. create an empty eventfd ----------------------------- */
    long efd = sys2(SYS_eventfd2, 0, 0);
    if (efd < 0) {
        puts_dec_line("epoll_rdy: FAIL eventfd2 rc=", efd);
        sys1(SYS_exit_group, 1);
    }

    /* ---- 2. create the epoll set -------------------------------- */
    long epfd = sys1(SYS_epoll_create1, 0);
    if (epfd < 0) {
        puts_dec_line("epoll_rdy: FAIL epoll_create1 rc=", epfd);
        sys1(SYS_exit_group, 1);
    }

    /* ---- 3. register the eventfd for EPOLLIN --------------------- */
    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data   = 0xC0FFEEULL;          /* cookie we expect echoed back */
    long crc = sys4(SYS_epoll_ctl, epfd, EPOLL_CTL_ADD, efd, (long)&ev);
    if (crc != 0) {
        puts_dec_line("epoll_rdy: FAIL epoll_ctl ADD rc=", crc);
        sys1(SYS_exit_group, 1);
    }

    /* ---- 4. before any write: nothing must be ready ------------- */
    struct epoll_event out[4];
    long n = sys4(SYS_epoll_wait, epfd, (long)out, 4, 0 /* timeout=0 */);
    if (n != 0) {
        puts_dec_line("epoll_rdy: FAIL empty wait n=", n);
        sys1(SYS_exit_group, 1);
    }
    puts_str("EPOLL: empty not-ready ok\n");

    /* ---- 5. write 1 to the eventfd: it becomes readable --------- */
    uint64_t one = 1;
    long wn = sys3(SYS_write, efd, (long)&one, 8);
    if (wn != 8) {
        puts_dec_line("epoll_rdy: FAIL eventfd write wn=", wn);
        sys1(SYS_exit_group, 1);
    }

    /* ---- 6. now epoll_wait must report the eventfd ready -------- */
    n = sys4(SYS_epoll_wait, epfd, (long)out, 4, 200 /* ms */);
    if (n < 1) {
        puts_dec_line("epoll_rdy: FAIL ready wait n=", n);
        sys1(SYS_exit_group, 1);
    }
    if (!(out[0].events & EPOLLIN)) {
        puts_dec_line("epoll_rdy: FAIL events=", (long)out[0].events);
        sys1(SYS_exit_group, 1);
    }
    puts_str("EPOLL: ready after write ok\n");

    if (out[0].data != 0xC0FFEEULL) {
        puts_dec_line("epoll_rdy: FAIL data cookie=", (long)out[0].data);
        sys1(SYS_exit_group, 1);
    }
    puts_str("EPOLL: data cookie ok\n");

    /* ---- 7. DEL the eventfd; with it gone, nothing is ready ----- */
    long drc = sys4(SYS_epoll_ctl, epfd, EPOLL_CTL_DEL, efd, 0);
    if (drc != 0) {
        puts_dec_line("epoll_rdy: FAIL epoll_ctl DEL rc=", drc);
        sys1(SYS_exit_group, 1);
    }
    n = sys4(SYS_epoll_wait, epfd, (long)out, 4, 0);
    if (n != 0) {
        puts_dec_line("epoll_rdy: FAIL post-DEL wait n=", n);
        sys1(SYS_exit_group, 1);
    }
    puts_str("EPOLL: del then empty ok\n");

    sys1(SYS_close, efd);
    sys1(SYS_close, epfd);

    puts_str("epoll_rdy: PASS\n");
    sys1(SYS_exit_group, 0);
    return 0;
}
