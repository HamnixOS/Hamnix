/*
 * tests/u-binary/src/forkpty_repro/hello.c -- QA-N29 forkpty repro.
 *
 * weston-terminal (and any terminal emulator / `script` / sshd login)
 * starts its shell via forkpty(): open a PTY master, fork, and IN THE
 * CHILD run login_tty() (setsid + ioctl(TIOCSCTTY) + dup2 slave->0/1/2
 * + close slave), THEN execve() the shell. The plain fork+execve
 * fixtures (dynamic_forkexec / forkexec_static) pass, so this isolates
 * whether the setsid/TIOCSCTTY/dup2 sequence between fork and execve is
 * what makes the exec'd child land on its user stack (NX exec-fault,
 * code=139) instead of entering the new image.
 *
 * The child execve()s /bin/u_dynamic_hello (dynamic-PIE, ld.so). The
 * parent reads the PTY master until EOF and reaps.
 *
 * Markers on serial:
 *   "FPTY: parent, forkpty child pid=N"
 *   "U42 dynamic hello"                      (child execve succeeded)
 *   "FPTY: parent reaped child status=0"     == PASS
 *   "FPTY: FAIL ..."                          on any failure
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pty.h>
#include <sys/wait.h>

extern char **environ;

int main(void) {
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, NULL);
    if (pid < 0) {
        printf("FPTY: FAIL forkpty errno=%d\n", errno);
        fflush(stdout);
        return 1;
    }
    if (pid == 0) {
        /* child: login_tty already ran inside forkpty (setsid,
         * TIOCSCTTY, dup2 slave onto 0/1/2). Now become the shell. */
        char *args[] = {"/bin/u_dynamic_hello", NULL};
        execve("/bin/u_dynamic_hello", args, environ);
        /* execve returns only on failure */
        _exit(127);
    }

    printf("FPTY: parent, forkpty child pid=%d\n", (int)pid);
    fflush(stdout);

    /* Drain the master so the child's stdout (its "U42 dynamic hello")
     * shows up on our serial, then reap. */
    char buf[256];
    for (;;) {
        ssize_t n = read(master, buf, sizeof(buf) - 1);
        if (n <= 0) {
            break;                     /* EOF / EIO when slave closes */
        }
        buf[n] = '\0';
        fputs(buf, stdout);
        fflush(stdout);
    }

    int wstatus = 0;
    pid_t reaped = waitpid(pid, &wstatus, 0);
    if (reaped != pid) {
        printf("FPTY: FAIL waitpid=%d (want %d) errno=%d\n",
               (int)reaped, (int)pid, errno);
        fflush(stdout);
        return 2;
    }
    if (!WIFEXITED(wstatus)) {
        printf("FPTY: FAIL child abnormal wstatus=0x%x\n", wstatus);
        fflush(stdout);
        return 3;
    }
    printf("FPTY: parent reaped child status=%d\n", WEXITSTATUS(wstatus));
    fflush(stdout);
    return 0;
}
