/*
 * tests/u-binary/src/forkexec_static/hello.c -- QA-N29 minimal repro.
 *
 * A static-PIE (ET_DYN, no ld.so) parent that fork()s and, IN THE
 * CHILD, execve()s /bin/u_glibc_hello (another static-PIE fixture),
 * then the parent waitpid()s the child. Isolates the fork->execve
 * return-frame bug from weston/forkpty/ld.so: no dynamic linker, no
 * PTY, no threads. If the exec'd child lands on its own user stack
 * (NX exec-fault, code=139) instead of entering /bin/u_glibc_hello,
 * this reproduces QA-N29 in the smallest possible form.
 *
 * A non-forked execve (glibc_exec fixture) works; the contrast is
 * that the execve here runs in a FORK CHILD (image_cow_shared=1).
 *
 * Markers on serial:
 *   "FES: parent before fork"
 *   "U18: glibc static hello"                (child execve succeeded)
 *   "FES: parent reaped child status=0"      == PASS
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

extern char **environ;

int main(void) {
    printf("FES: parent before fork\n");
    fflush(stdout);

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }
    if (pid == 0) {
        char *args[] = {"/bin/u_glibc_hello", NULL};
        execve("/bin/u_glibc_hello", args, environ);
        perror("execve");
        _exit(127);
    }

    int wstatus = 0;
    pid_t reaped = waitpid(pid, &wstatus, 0);
    if (reaped != pid) {
        printf("FES: waitpid returned %d (expected %d)\n", reaped, pid);
        return 2;
    }
    if (!WIFEXITED(wstatus)) {
        printf("FES: child did not exit normally: %d\n", wstatus);
        return 3;
    }
    printf("FES: parent reaped child status=%d\n", WEXITSTATUS(wstatus));
    fflush(stdout);
    return 0;
}
