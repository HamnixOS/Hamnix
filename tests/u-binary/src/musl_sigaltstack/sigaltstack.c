/*
 * tests/u-binary/src/musl_sigaltstack/sigaltstack.c -- U37 fixture.
 *
 * Exercises sigaltstack(2) via a raw inline syscall (number 131 on
 * x86_64). U37 wires _u_sigaltstack into linux_abi/u_syscalls.ad so
 * glibc's static-PIE signal-setup path no longer trips -ENOSYS during
 * busybox sh's first probe.
 *
 * Test plan:
 *
 *   1. Install an alt stack with a known sp/size/flags via
 *      sigaltstack(&ss, NULL). Expect rc == 0.
 *   2. Read it back with sigaltstack(NULL, &oss). Expect rc == 0 and
 *      the three fields to round-trip identically.
 *   3. A second combined call (set + retrieve old) reports the values
 *      from step 1 in oss while installing fresh ones from ss.
 *
 * Markers (one per line, on stdout):
 *
 *     "U37: install rc=R"           PASS if R == 0
 *     "U37: query rc=R sp=... size=... flags=..."  PASS if the three
 *                                                   fields match step 1.
 *     "U37: combined rc=R sp=... size=... flags=..."
 *     "U37: PASS"  (only emitted when every assertion above held)
 *
 * Built with musl-gcc -static-pie -O2 so the static-PIE loader path is
 * identical to the other U-track fixtures.
 */

#include <stdint.h>

typedef struct {
    void   *ss_sp;
    int     ss_flags;
    /* 4 bytes pad to next 8-byte alignment */
    unsigned long ss_size;
} stack_t;

static long sys_write(int fd, const void *buf, unsigned long n) {
    long rc;
    __asm__ volatile (
        "syscall"
        : "=a"(rc)
        : "0"(1L), "D"((long)fd), "S"(buf), "d"(n)
        : "rcx", "r11", "memory"
    );
    return rc;
}

static long sys_sigaltstack(const stack_t *ss, stack_t *oss) {
    long rc;
    __asm__ volatile (
        "syscall"
        : "=a"(rc)
        : "0"(131L), "D"(ss), "S"(oss)
        : "rcx", "r11", "memory"
    );
    return rc;
}

static int itoa(long v, char *out) {
    char tmp[32];
    int n = 0, neg = 0;
    unsigned long u;
    if (v < 0) { neg = 1; u = (unsigned long)(-v); }
    else        { u = (unsigned long)v; }
    if (u == 0) tmp[n++] = '0';
    while (u) { tmp[n++] = '0' + (int)(u % 10); u /= 10; }
    int w = 0;
    if (neg) out[w++] = '-';
    while (n--) out[w++] = tmp[n];
    return w;
}

static int xtoa(unsigned long v, char *out) {
    /* Hex without 0x prefix, no padding -- compact and grep-friendly. */
    char tmp[32];
    int n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v) {
        int d = (int)(v & 0xf);
        tmp[n++] = (d < 10) ? ('0' + d) : ('a' + (d - 10));
        v >>= 4;
    }
    int w = 0;
    while (n--) out[w++] = tmp[n];
    return w;
}

static int put_str(char *out, const char *s) {
    int w = 0;
    while (*s) out[w++] = *s++;
    return w;
}

/* Two 8 KiB chunks of static .bss — used as known-good alt-stack
 * backing memory. Static (not heap) so the address is stable across
 * runs and we don't drag malloc in. */
static unsigned char altbuf1[8192];
static unsigned char altbuf2[16384];

int main(void) {
    char line[256];
    int w;

    /* Step 1: install. */
    stack_t ss;
    ss.ss_sp    = altbuf1;
    ss.ss_size  = sizeof altbuf1;
    ss.ss_flags = 0;
    long rc = sys_sigaltstack(&ss, (stack_t *)0);
    w  = put_str(line, "U37: install rc=");
    w += itoa(rc, line + w);
    line[w++] = '\n';
    sys_write(1, line, w);
    int ok = (rc == 0);

    /* Step 2: query. */
    stack_t oss;
    oss.ss_sp    = (void *)0;
    oss.ss_size  = 0;
    oss.ss_flags = 0;
    rc = sys_sigaltstack((const stack_t *)0, &oss);
    w  = put_str(line, "U37: query rc=");
    w += itoa(rc, line + w);
    w += put_str(line + w, " sp=");
    w += xtoa((unsigned long)oss.ss_sp, line + w);
    w += put_str(line + w, " size=");
    w += itoa((long)oss.ss_size, line + w);
    w += put_str(line + w, " flags=");
    w += itoa(oss.ss_flags, line + w);
    line[w++] = '\n';
    sys_write(1, line, w);
    if (rc != 0)               ok = 0;
    if (oss.ss_sp != altbuf1)  ok = 0;
    if (oss.ss_size != sizeof altbuf1) ok = 0;
    if (oss.ss_flags != 0)     ok = 0;

    /* Step 3: combined call -- install fresh + retrieve prior. */
    ss.ss_sp    = altbuf2;
    ss.ss_size  = sizeof altbuf2;
    ss.ss_flags = 0;
    oss.ss_sp    = (void *)0;
    oss.ss_size  = 0;
    oss.ss_flags = 0;
    rc = sys_sigaltstack(&ss, &oss);
    w  = put_str(line, "U37: combined rc=");
    w += itoa(rc, line + w);
    w += put_str(line + w, " sp=");
    w += xtoa((unsigned long)oss.ss_sp, line + w);
    w += put_str(line + w, " size=");
    w += itoa((long)oss.ss_size, line + w);
    w += put_str(line + w, " flags=");
    w += itoa(oss.ss_flags, line + w);
    line[w++] = '\n';
    sys_write(1, line, w);
    if (rc != 0)              ok = 0;
    if (oss.ss_sp != altbuf1) ok = 0;
    if (oss.ss_size != sizeof altbuf1) ok = 0;

    if (ok) {
        sys_write(1, "U37: PASS\n", 10);
        return 0;
    }
    sys_write(1, "U37: FAIL\n", 10);
    return 1;
}
