/*
 * tests/u-binary/src/musl_sigchld/sigchld.c — §3 SIGCHLD + reaping.
 *
 * Models the canonical server-daemon child-management pattern:
 *
 *   1. install a SIGCHLD handler that reaps via waitpid(-1, &st, ...)
 *   2. fork() a child that _exit(7)s immediately
 *   3. the child exit raises SIGCHLD in the parent
 *   4. the handler runs, waitpid returns the child pid, WIFEXITED is
 *      true and WEXITSTATUS == 7
 *
 * Then a SECOND child is forked and killed with SIGKILL to confirm
 * the WIFSIGNALED wait-status encoding (WTERMSIG == SIGKILL) and that
 * SIGKILL is uncatchable / unblockable — it terminates the child
 * regardless of the child's installed handlers or signal mask.
 *
 * Markers on serial:
 *   "SIGCHLD: start"
 *   "SIGCHLD: handler ran"        — SIGCHLD delivered to the parent
 *   "SIGCHLD: reaped exit 7"      — WIFEXITED + WEXITSTATUS correct
 *   "SIGCHLD: reaped killed 9"    — WIFSIGNALED + WTERMSIG correct
 *   "SIGCHLD: PASS"
 *   "SIGCHLD: FAIL ..."
 *
 * Built static-PIE with musl-gcc.
 */

#define _GNU_SOURCE
#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <sched.h>
#include <sys/wait.h>

static volatile int chld_hits  = 0;
static volatile int last_pid   = 0;
static volatile int last_exit  = -1;
static volatile int last_tsig  = -1;

static inline long do_write(int fd, const char *buf, unsigned long len) {
    long rc;
    __asm__ volatile (
        "syscall" : "=a"(rc)
        : "0"(1), "D"(fd), "S"(buf), "d"(len)
        : "rcx", "r11", "memory");
    return rc;
}
#define SAY(s) do_write(1, s "\n", sizeof(s))

/* SIGCHLD handler: drain every reapable child non-blockingly. */
static void sigchld_handler(int sig) {
    (void)sig;
    int st = 0;
    int pid;
    while ((pid = waitpid(-1, &st, WNOHANG)) > 0) {
        chld_hits++;
        last_pid = pid;
        if (WIFEXITED(st))
            last_exit = WEXITSTATUS(st);
        if (WIFSIGNALED(st))
            last_tsig = WTERMSIG(st);
    }
}

int main(void) {
    SAY("SIGCHLD: start");

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigchld_handler;
    if (sigaction(SIGCHLD, &sa, 0) != 0) {
        SAY("SIGCHLD: FAIL sigaction");
        return 1;
    }

    /* --- child 1: normal exit(7) -------------------------------- */
    pid_t c1 = fork();
    if (c1 == 0) {
        _exit(7);
    }
    if (c1 < 0) {
        SAY("SIGCHLD: FAIL fork 1");
        return 1;
    }
    /* Cooperatively yield until the SIGCHLD handler has reaped the
     * child. sched_yield hands the CPU to the child so it can run,
     * exit, and have the kernel post SIGCHLD back to us. */
    for (int i = 0; i < 2000 && chld_hits < 1; i++)
        sched_yield();
    if (chld_hits < 1) {
        SAY("SIGCHLD: FAIL handler never ran");
        return 1;
    }
    SAY("SIGCHLD: handler ran");
    if (last_exit != 7) {
        SAY("SIGCHLD: FAIL bad exit status");
        return 1;
    }
    SAY("SIGCHLD: reaped exit 7");

    /* --- child 2: killed by SIGKILL (uncatchable + unblockable) -- */
    pid_t c2 = fork();
    if (c2 == 0) {
        /* Block every signal we can and install a no-op SIGTERM
         * handler — SIGKILL must still terminate us, proving it is
         * both uncatchable and unblockable. */
        sigset_t all;
        sigfillset(&all);
        sigprocmask(SIG_BLOCK, &all, 0);
        for (;;) sched_yield();
    }
    if (c2 < 0) {
        SAY("SIGCHLD: FAIL fork 2");
        return 1;
    }
    /* Let the child get scheduled + block its signals, then SIGKILL. */
    for (int i = 0; i < 80; i++)
        sched_yield();
    kill(c2, SIGKILL);
    for (int i = 0; i < 2000 && chld_hits < 2; i++)
        sched_yield();
    if (chld_hits < 2) {
        SAY("SIGCHLD: FAIL second child not reaped");
        return 1;
    }
    if (last_tsig != SIGKILL) {
        SAY("SIGCHLD: FAIL bad term signal");
        return 1;
    }
    SAY("SIGCHLD: reaped killed 9");

    SAY("SIGCHLD: PASS");
    return 0;
}
