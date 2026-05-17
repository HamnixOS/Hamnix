/*
 * tests/u-binary/src/musl_syscalls/syscalls.c — U29 fixture.
 *
 * Exercises pipe2(2), dup3(2), and getdents64(2) — the three syscalls
 * U29 freshly wires in linux_abi/u_syscalls.ad. Each call uses a raw
 * inline syscall instead of musl's wrappers so the test doesn't care
 * whether musl 1.2.x has a glibc-style cancel point on these paths.
 *
 * Markers (one line each, on stdout):
 *   "U29: pipe2 rc=R fds={A,B}"
 *   "U29: dup3 same-fd rc=R (expect -22)"
 *   "U29: dup3 distinct rc=R (expect 5)"
 *   "U29: getdents64 rc=R (expect -20)"
 *
 * PASS criteria: the test_u29_syscalls.sh harness checks for those
 * four markers literally. pipe2's fds vary across runs; we only assert
 * the success rc and that A < B (allocator gives ascending fds).
 */

#include <stdint.h>

/* Minimal raw write — same shape as the other U-track fixtures. */
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

static long sys_pipe2(int *fds, int flags) {
    long rc;
    __asm__ volatile (
        "syscall"
        : "=a"(rc)
        : "0"(293L), "D"(fds), "S"((long)flags)
        : "rcx", "r11", "memory"
    );
    return rc;
}

static long sys_dup3(int oldfd, int newfd, int flags) {
    long rc;
    __asm__ volatile (
        "syscall"
        : "=a"(rc)
        : "0"(292L), "D"((long)oldfd), "S"((long)newfd), "d"((long)flags)
        : "rcx", "r11", "memory"
    );
    return rc;
}

static long sys_getdents64(int fd, void *buf, unsigned long n) {
    long rc;
    __asm__ volatile (
        "syscall"
        : "=a"(rc)
        : "0"(217L), "D"((long)fd), "S"(buf), "d"(n)
        : "rcx", "r11", "memory"
    );
    return rc;
}

/* Tiny itoa: writes `v` as signed decimal into out, returns bytes written. */
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

static int build_line(char *out, const char *prefix, long v) {
    int w = 0;
    while (*prefix) out[w++] = *prefix++;
    w += itoa(v, out + w);
    out[w++] = '\n';
    return w;
}

int main(void) {
    char line[160];
    int n;
    int fds[2] = { -1, -1 };

    long rc = sys_pipe2(fds, 0);
    {
        int w = 0;
        const char *p = "U29: pipe2 rc=";
        while (*p) line[w++] = *p++;
        w += itoa(rc, line + w);
        p = " fds={";
        while (*p) line[w++] = *p++;
        w += itoa(fds[0], line + w);
        line[w++] = ',';
        w += itoa(fds[1], line + w);
        line[w++] = '}';
        line[w++] = '\n';
        sys_write(1, line, w);
    }

    /* dup3 with oldfd == newfd: Linux says -EINVAL (-22). */
    rc = sys_dup3(fds[0], fds[0], 0);
    n = build_line(line, "U29: dup3 same-fd rc=", rc);
    sys_write(1, line, n);

    /* dup3 with distinct fds: copies fds[0] into fd 5 (a fresh slot).
     * vfs_dup2 returns newfd on success. */
    rc = sys_dup3(fds[0], 5, 0);
    n = build_line(line, "U29: dup3 distinct rc=", rc);
    sys_write(1, line, n);

    /* getdents64 on a (read) pipe fd: not a directory → -ENOTDIR (-20). */
    char buf[256];
    rc = sys_getdents64(fds[0], buf, sizeof buf);
    n = build_line(line, "U29: getdents64 rc=", rc);
    sys_write(1, line, n);

    return 0;
}
