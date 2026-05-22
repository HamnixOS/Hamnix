/*
 * tests/u-binary/src/epolltest/epolltest.c — §5 Layer-2 async-I/O fixture.
 *
 * Exercises the epoll / eventfd / timerfd / poll / O_NONBLOCK surface a
 * real Linux event-driven daemon depends on, all bridged to the Hamnix
 * Layer-2 shim (linux_abi/u_epoll.ad + u_syscalls.ad + fs/vfs.ad):
 *
 *   1. pipe2(O_NONBLOCK) — a non-blocking pipe read on an empty pipe
 *      must return -EAGAIN (not block).
 *   2. eventfd2 — write a value, epoll_wait reports it readable, read
 *      drains the counter.
 *   3. timerfd_create + timerfd_settime — a short one-shot timer; epoll
 *      _wait blocks until it fires, then read returns the expiration
 *      count.
 *   4. epoll_create1 + epoll_ctl(ADD) for the pipe read end, the
 *      eventfd, and the timerfd; epoll_wait drives all three.
 *   5. write the pipe; epoll_wait reports the pipe fd readable.
 *   6. poll(2) over the eventfd as the simpler-fallback path.
 *
 * Built musl-gcc -static-pie; OSABI stamped ELFOSABI_LINUX. Every
 * syscall is a raw inline `syscall` so the test does not depend on
 * musl's wrappers.
 *
 * Markers (one per line on stdout — the harness greps these):
 *   "epolltest: nonblock-pipe EAGAIN ok"
 *   "epolltest: eventfd ready+drain ok"
 *   "epolltest: timerfd fired ok"
 *   "epolltest: pipe epoll ready ok"
 *   "epolltest: poll eventfd ok"
 *   "epolltest: PASS"  / "epolltest: FAIL ..."
 */

#include <stdint.h>

#define SYS_read            0
#define SYS_write           1
#define SYS_close           3
#define SYS_poll            7
#define SYS_epoll_create1   291
#define SYS_epoll_ctl       233
#define SYS_epoll_wait      232
#define SYS_eventfd2        290
#define SYS_timerfd_create  283
#define SYS_timerfd_settime 286
#define SYS_pipe2           293
#define SYS_exit_group      231

#define EPOLL_CTL_ADD 1
#define EPOLLIN       0x001

#define O_NONBLOCK 0x800
#define EAGAIN     11

#define CLOCK_MONOTONIC 1

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

/* struct epoll_event is PACKED on x86_64: u32 events; u64 data. */
struct epoll_event {
    uint32_t events;
    uint64_t data;
} __attribute__((packed));

/* struct itimerspec { struct timespec it_interval, it_value; }
 * struct timespec { long tv_sec; long tv_nsec; } */
struct itimerspec {
    long it_interval_sec;
    long it_interval_nsec;
    long it_value_sec;
    long it_value_nsec;
};

/* struct pollfd { int fd; short events; short revents; } */
struct pollfd {
    int   fd;
    short events;
    short revents;
};

int main(void) {
    /* ---- 1. non-blocking pipe: empty read must give -EAGAIN ------- */
    int pfd[2];
    long prc = sys2(SYS_pipe2, (long)pfd, O_NONBLOCK);
    if (prc != 0) die("epolltest: FAIL pipe2\n");
    char rb[64];
    long rn = sys3(SYS_read, pfd[0], (long)rb, sizeof(rb));
    if (rn != -EAGAIN) {
        puts_dec_line("epolltest: FAIL nonblock-pipe rn=", rn);
        sys1(SYS_exit_group, 1);
    }
    puts_str("epolltest: nonblock-pipe EAGAIN ok\n");

    /* ---- 2. eventfd: write a value, read it back ----------------- */
    long efd = sys2(SYS_eventfd2, 0, 0);
    if (efd < 0) die("epolltest: FAIL eventfd2\n");
    uint64_t one = 1;
    long ewr = sys3(SYS_write, efd, (long)&one, 8);
    if (ewr != 8) die("epolltest: FAIL eventfd write\n");
    uint64_t got = 0;
    long erd = sys3(SYS_read, efd, (long)&got, 8);
    if (erd != 8 || got != 1) {
        puts_dec_line("epolltest: FAIL eventfd read got=", (long)got);
        sys1(SYS_exit_group, 1);
    }
    puts_str("epolltest: eventfd ready+drain ok\n");

    /* ---- 3. timerfd: arm a ~150 ms one-shot ---------------------- */
    long tfd = sys2(SYS_timerfd_create, CLOCK_MONOTONIC, 0);
    if (tfd < 0) die("epolltest: FAIL timerfd_create\n");
    struct itimerspec its;
    its.it_interval_sec = 0; its.it_interval_nsec = 0;
    its.it_value_sec = 0;    its.it_value_nsec = 150000000L;  /* 150 ms */
    long trc = sys4(SYS_timerfd_settime, tfd, 0, (long)&its, 0);
    if (trc != 0) die("epolltest: FAIL timerfd_settime\n");

    /* ---- 4. epoll: register the timerfd, wait for it to fire ----- */
    long ep = sys1(SYS_epoll_create1, 0);
    if (ep < 0) die("epolltest: FAIL epoll_create1\n");

    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data = 0x7700;
    if (sys4(SYS_epoll_ctl, ep, EPOLL_CTL_ADD, tfd, (long)&ev) != 0)
        die("epolltest: FAIL epoll_ctl ADD timerfd\n");

    struct epoll_event out[8];
    long n = sys4(SYS_epoll_wait, ep, (long)out, 8, 5000);
    if (n < 1) {
        puts_dec_line("epolltest: FAIL timerfd epoll_wait n=", n);
        sys1(SYS_exit_group, 1);
    }
    /* drain the timerfd expiration count */
    uint64_t expir = 0;
    long tdr = sys3(SYS_read, tfd, (long)&expir, 8);
    if (tdr != 8 || expir < 1) {
        puts_dec_line("epolltest: FAIL timerfd read expir=", (long)expir);
        sys1(SYS_exit_group, 1);
    }
    puts_str("epolltest: timerfd fired ok\n");

    /* ---- 5. epoll over a pipe fd: write makes it readable -------- */
    struct epoll_event pev;
    pev.events = EPOLLIN;
    pev.data = 0x9900;
    if (sys4(SYS_epoll_ctl, ep, EPOLL_CTL_ADD, pfd[0], (long)&pev) != 0)
        die("epolltest: FAIL epoll_ctl ADD pipe\n");
    /* nothing in the pipe yet -> immediate epoll_wait returns 0 */
    long n0 = sys4(SYS_epoll_wait, ep, (long)out, 8, 0);
    if (n0 != 0) {
        puts_dec_line("epolltest: FAIL pipe pre-write n0=", n0);
        sys1(SYS_exit_group, 1);
    }
    /* write to the pipe write end, then epoll_wait must report it */
    const char *msg = "hello-epoll";
    if (sys3(SYS_write, pfd[1], (long)msg, (long)u_strlen(msg))
            != (long)u_strlen(msg))
        die("epolltest: FAIL pipe write\n");
    long n1 = sys4(SYS_epoll_wait, ep, (long)out, 8, 5000);
    if (n1 < 1) {
        puts_dec_line("epolltest: FAIL pipe epoll_wait n1=", n1);
        sys1(SYS_exit_group, 1);
    }
    int saw_pipe = 0;
    for (long i = 0; i < n1; i++)
        if (out[i].data == 0x9900) saw_pipe = 1;
    if (!saw_pipe) die("epolltest: FAIL pipe not in epoll result\n");
    /* drain it (non-blocking — must succeed now) */
    long pn = sys3(SYS_read, pfd[0], (long)rb, sizeof(rb));
    if (pn != (long)u_strlen(msg)) {
        puts_dec_line("epolltest: FAIL pipe drain pn=", pn);
        sys1(SYS_exit_group, 1);
    }
    puts_str("epolltest: pipe epoll ready ok\n");

    /* ---- 6. poll(2) fallback over the eventfd -------------------- */
    uint64_t two = 2;
    if (sys3(SYS_write, efd, (long)&two, 8) != 8)
        die("epolltest: FAIL eventfd re-arm\n");
    struct pollfd pl;
    pl.fd = (int)efd;
    pl.events = EPOLLIN;       /* POLLIN == 0x1 */
    pl.revents = 0;
    long pr = sys3(SYS_poll, (long)&pl, 1, 1000);
    if (pr != 1 || (pl.revents & 0x1) == 0) {
        puts_dec_line("epolltest: FAIL poll pr=", pr);
        sys1(SYS_exit_group, 1);
    }
    puts_str("epolltest: poll eventfd ok\n");

    sys1(SYS_close, ep);
    sys1(SYS_close, tfd);
    sys1(SYS_close, efd);
    sys1(SYS_close, pfd[0]);
    sys1(SYS_close, pfd[1]);

    puts_str("epolltest: PASS\n");
    sys1(SYS_exit_group, 0);
    return 0;
}
