/*
 * tests/u-binary/src/musl_sigpipe/sigpipe.c — §3 SIGPIPE on a broken
 * pipe write.
 *
 * Models the server-daemon "client hung up mid-response" path:
 *
 *   1. install a SIGPIPE handler (a daemon either ignores SIGPIPE or
 *      catches it — the default action would kill the process)
 *   2. create a pipe, close the READ end
 *   3. write() to the WRITE end — there is no reader, so the kernel
 *      raises SIGPIPE in the writer AND write(2) returns -1/EPIPE
 *   4. confirm the handler ran and write reported EPIPE
 *
 * Then a second check installs SIG_IGN for SIGPIPE and confirms a
 * broken-pipe write still returns EPIPE without terminating.
 *
 * Markers on serial:
 *   "SIGPIPE: start"
 *   "SIGPIPE: handler ran"     — SIGPIPE delivered to a real handler
 *   "SIGPIPE: write got EPIPE" — write(2) returned -1 with errno EPIPE
 *   "SIGPIPE: ignored ok"      — SIG_IGN path survived + got EPIPE
 *   "SIGPIPE: PASS"
 *   "SIGPIPE: FAIL ..."
 *
 * Built static-PIE with musl-gcc.
 */

#define _GNU_SOURCE
#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

static volatile int pipe_hits = 0;

static inline long do_write(int fd, const char *buf, unsigned long len) {
    long rc;
    __asm__ volatile (
        "syscall" : "=a"(rc)
        : "0"(1), "D"(fd), "S"(buf), "d"(len)
        : "rcx", "r11", "memory");
    return rc;
}
#define SAY(s) do_write(1, s "\n", sizeof(s))

static void sigpipe_handler(int sig) {
    (void)sig;
    pipe_hits++;
}

int main(void) {
    SAY("SIGPIPE: start");

    /* --- 1. caught SIGPIPE -------------------------------------- */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigpipe_handler;
    if (sigaction(SIGPIPE, &sa, 0) != 0) {
        SAY("SIGPIPE: FAIL sigaction");
        return 1;
    }

    int fds[2];
    if (pipe(fds) != 0) {
        SAY("SIGPIPE: FAIL pipe");
        return 1;
    }
    close(fds[0]);                 /* drop the only reader */

    errno = 0;
    long w = write(fds[1], "x", 1);
    /* Spin so the syscall-tail signal delivery lands the handler. */
    for (volatile int i = 0; i < 200000; i++) ;
    if (pipe_hits < 1) {
        SAY("SIGPIPE: FAIL handler never ran");
        return 1;
    }
    SAY("SIGPIPE: handler ran");
    if (w != -1 || errno != EPIPE) {
        SAY("SIGPIPE: FAIL write did not report EPIPE");
        return 1;
    }
    SAY("SIGPIPE: write got EPIPE");
    close(fds[1]);

    /* --- 2. ignored SIGPIPE ------------------------------------- */
    struct sigaction ign;
    memset(&ign, 0, sizeof(ign));
    ign.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &ign, 0) != 0) {
        SAY("SIGPIPE: FAIL sigaction ign");
        return 1;
    }
    int fd2[2];
    if (pipe(fd2) != 0) {
        SAY("SIGPIPE: FAIL pipe 2");
        return 1;
    }
    close(fd2[0]);
    errno = 0;
    long w2 = write(fd2[1], "y", 1);
    if (w2 != -1 || errno != EPIPE) {
        SAY("SIGPIPE: FAIL ignored write did not report EPIPE");
        return 1;
    }
    SAY("SIGPIPE: ignored ok");
    close(fd2[1]);

    SAY("SIGPIPE: PASS");
    return 0;
}
