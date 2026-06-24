/*
 * tests/u-binary/src/dynamic_forkexec/hello.c -- dynamic fork+execve.
 *
 * Reproduces dpkg/apt's EXACT process pattern: a DYNAMICALLY linked
 * (PT_INTERP) glibc binary fork()s, and the CHILD execve()s into
 * ANOTHER dynamically-linked binary (just as dpkg forks dpkg-split /
 * dpkg-deb). The interesting case is the SECOND-generation dynamic
 * execve: ld.so re-runs in the child after the fork, re-allocating the
 * TLS/TCB. A simple dynamic fork (dynamic_fork fixture) already works;
 * this fixture exercises the fork->execve(dynamic) chain that the dpkg
 * install path needs.
 *
 * The child execve's /bin/u_dynamic_hello (the dynamic_hello fixture,
 * also a PT_INTERP glibc PIE) which prints "U42 dynamic hello".
 *
 * Markers on serial:
 *   "DYNFE: parent before fork"
 *   "U42 dynamic hello"                       (child execve succeeded)
 *   "DYNFE: parent reaped child status=0"     == PASS
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

extern char **environ;

int main(void) {
    printf("DYNFE: parent before fork\n");
    fflush(stdout);
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 1; }
    if (pid == 0) {
        char *args[] = {"/bin/u_dynamic_hello", NULL};
        execve("/bin/u_dynamic_hello", args, environ);
        perror("execve");
        _exit(127);
    }
    int wstatus = 0;
    pid_t reaped = waitpid(pid, &wstatus, 0);
    if (reaped != pid) {
        printf("DYNFE: waitpid returned %d (expected %d)\n", reaped, pid);
        return 2;
    }
    if (!WIFEXITED(wstatus)) {
        printf("DYNFE: child did not exit normally: %d\n", wstatus);
        return 3;
    }
    printf("DYNFE: parent reaped child status=%d\n", WEXITSTATUS(wstatus));
    fflush(stdout);
    return 0;
}
