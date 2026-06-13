/*
 * tests/u-binary/src/seccomp_bpf/seccomp_bpf.c — §6 seccomp-bpf e2e.
 *
 * Exercises Hamnix's classic-BPF seccomp filter (kernel/seccomp_bpf.ad +
 * linux_abi/u_syscalls.ad:PR_SET_SECCOMP_BPF). Installs a tiny cBPF
 * program that returns SECCOMP_RET_ERRNO|EACCES for open(2) and
 * SECCOMP_RET_ALLOW for everything else, then proves:
 *
 *   1. write(2) BEFORE arming the filter works (baseline).
 *   2. prctl(PR_SET_SECCOMP_BPF, &fprog) accepts the filter.
 *   3. write(2) AFTER arming still works (ALLOW branch).
 *   4. open("/dev/null", O_RDONLY) returns -1 with errno == EACCES
 *      (ERRNO branch: the kernel returned -EACCES in %rax, no SIGSYS).
 *
 * Markers on serial (the harness greps these):
 *   "SECCOMP_BPF: pre-arm write ok"
 *   "SECCOMP_BPF: filter armed"
 *   "SECCOMP_BPF: allowed write after arm"
 *   "SECCOMP_BPF: open denied EACCES"
 *   "seccomp_bpf: PASS" / "seccomp_bpf: FAIL ..."
 *
 * All output via raw write(2) — never through stdio — so denied
 * syscalls can't taint the test markers.
 */

#define _GNU_SOURCE
#include <unistd.h>
#include <string.h>

#ifndef PR_SET_SECCOMP_BPF
#define PR_SET_SECCOMP_BPF 0x10001
#endif

#define EACCES 13

#define BPF_LD    0x00
#define BPF_W     0x00
#define BPF_ABS   0x20
#define BPF_JMP   0x05
#define BPF_JEQ   0x10
#define BPF_K     0x00
#define BPF_RET   0x06
#define BPF_STMT(c, k) { (unsigned short)(c), 0, 0, (unsigned int)(k) }
#define BPF_JUMP(c, k, jt, jf) { (unsigned short)(c), (unsigned char)(jt), (unsigned char)(jf), (unsigned int)(k) }

#define SECCOMP_RET_ALLOW 0x7fff0000U
#define SECCOMP_RET_ERRNO 0x00050000U

#define SYS_open    2
#define SYS_openat  257

struct sock_filter { unsigned short code; unsigned char jt; unsigned char jf; unsigned int k; };
struct sock_fprog  { unsigned short len; struct sock_filter *filter; };

/* cBPF: if (nr == SYS_open || nr == SYS_openat) ret ERRNO|EACCES; else ret ALLOW; */
static struct sock_filter filter_prog[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, 0),                      /* 0: A = nr */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_open,   2, 0),      /* 1 */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_openat, 1, 0),      /* 2 */
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),               /* 3 */
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EACCES),      /* 4 */
};

static inline long do_write(int fd, const char *buf, unsigned long len) {
    long rc;
    __asm__ volatile (
        "syscall" : "=a"(rc)
        : "0"(1), "D"(fd), "S"(buf), "d"(len)
        : "rcx", "r11", "memory");
    return rc;
}
#define SAY(s) do_write(1, s "\n", sizeof(s) - 1)

static inline void do_exit(int code) {
    __asm__ volatile (
        "syscall" :: "a"(60), "D"((long)code) : "rcx", "r11", "memory");
    __builtin_unreachable();
}

static inline long do_prctl(long op, long a1, long a2, long a3, long a4) {
    long rc;
    register long r10 __asm__("r10") = a3;
    register long r8  __asm__("r8")  = a4;
    __asm__ volatile (
        "syscall" : "=a"(rc)
        : "0"(157), "D"(op), "S"(a1), "d"(a2), "r"(r10), "r"(r8)
        : "rcx", "r11", "memory");
    return rc;
}

static inline long do_open(const char *path, int flags) {
    long rc;
    __asm__ volatile (
        "syscall" : "=a"(rc)
        : "0"(2), "D"(path), "S"((long)flags), "d"(0L)
        : "rcx", "r11", "memory");
    return rc;
}

int main(void) {
    SAY("SECCOMP_BPF: pre-arm write ok");

    /* Hamnix PR_SET_SECCOMP_BPF takes (filter_addr, filter_len) as two
     * flat prctl args rather than Linux's `struct sock_fprog` container —
     * a 16-byte mixed-width struct on the user stack has ABI-shape
     * ambiguity that costs nothing to avoid here. The cBPF program shape
     * (struct sock_filter array) is unchanged. */
    unsigned long flen = sizeof(filter_prog) / sizeof(filter_prog[0]);
    long rc = do_prctl(PR_SET_SECCOMP_BPF, (long)filter_prog, (long)flen, 0, 0);
    if (rc != 0) {
        SAY("seccomp_bpf: FAIL prctl install");
        do_exit(1);
    }
    SAY("SECCOMP_BPF: filter armed");

    /* ALLOW branch */
    SAY("SECCOMP_BPF: allowed write after arm");

    /* ERRNO branch: open(2) must come back as -13 (kernel returns
     * -EACCES in %rax). Anything else (success, different errno,
     * SIGSYS-kill before we get here) is a FAIL. */
    long oh = do_open("/dev/null", 0);
    if (oh == -EACCES) {
        SAY("SECCOMP_BPF: open denied EACCES");
        SAY("seccomp_bpf: PASS");
        do_exit(0);
    }
    if (oh >= 0) {
        SAY("seccomp_bpf: FAIL open succeeded (filter let it through)");
    } else {
        SAY("seccomp_bpf: FAIL open returned non-EACCES errno");
    }
    do_exit(1);
}
