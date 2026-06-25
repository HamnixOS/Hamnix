/*
 * tests/u-binary/src/interactive_forkexec/hello.c -- interactive
 * fork+exec loop fixture (reproduces the `enter linux {sh}` crash).
 *
 * The non-interactive dpkg/apt path (dynamic_forkexec fixture) forks
 * ONCE, the child execve's a dynamic binary, and the parent reaps it.
 * That works. The USER-REPORTED bug is specific to the INTERACTIVE
 * shell: dash reads a command from a PTY/stdin, fork()s a child that
 * execve()s the command, reaps it, then LOOPS BACK to read the NEXT
 * command and fork AGAIN. The second/third fork's child (or the
 * long-lived parent) crashes with an NX exec-fault whose RIP resolves
 * to a KERNEL high-half text VA (0xffffffff80xxxxxx) -> SIGSEGV +
 * coredump, pid 60 + 61 (shell + child) both die.
 *
 * This fixture reproduces that pattern WITHOUT needing a full Debian
 * dash: a long-lived dynamic-PIE parent that, in a loop, reads a line
 * from stdin, fork()s, the child execve's /bin/u_dynamic_hello, the
 * parent waitpid()s the child, and loops. Each iteration is an
 * independent fork+exec+reap, just like dash's interactive REPL. The
 * crash (if present) fires on the 2nd or 3rd iteration when the
 * long-lived parent's kernel-stack frame / COW state from the first
 * fork has been disturbed.
 *
 * Markers on serial:
 *   "ITFE: parent ready, reading commands"
 *   "U42 dynamic hello"                       (a child execve succeeded)
 *   "ITFE: iter=N reaped child status=0"      (one loop completed)
 *   "ITFE: all iters done"                    == PASS
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

extern char **environ;

/* The long-lived parent does NITERS independent fork+exec+reap cycles.
 * dash's interactive REPL is exactly this loop with an fgets(stdin) at
 * the top; the crash is in the fork+exec+reap machinery of a long-lived
 * parent, not the stdin read, so we drive it self-contained (no PTY
 * handoff needed: hamsh execs this fixture once and it loops internally).
 * 5 iterations is enough — the user's crash fires on iter 2. */
#define NITERS 5

int main(void) {
    printf("ITFE: parent ready, looping fork+exec\n");
    fflush(stdout);

    int iter = 0;
    while (iter < NITERS) {
        iter++;
        printf("ITFE: iter=%d forking\n", iter);
        fflush(stdout);

        pid_t pid = fork();
        if (pid < 0) {
            perror("fork");
            return 1;
        }
        if (pid == 0) {
            /* child: execve a dynamic binary, just like dash exec'ing
             * /bin/ls or /bin/echo for the typed command. */
            char *args[] = {"/bin/u_dynamic_hello", NULL};
            execve("/bin/u_dynamic_hello", args, environ);
            perror("execve");
            _exit(127);
        }

        int wstatus = 0;
        pid_t reaped = waitpid(pid, &wstatus, 0);
        if (reaped != pid) {
            printf("ITFE: waitpid returned %d (expected %d)\n", reaped, pid);
            return 2;
        }
        if (!WIFEXITED(wstatus)) {
            printf("ITFE: iter=%d child did not exit normally: %d\n",
                   iter, wstatus);
            return 3;
        }
        printf("ITFE: iter=%d reaped child status=%d\n",
               iter, WEXITSTATUS(wstatus));
        fflush(stdout);
    }

    printf("ITFE: all iters done\n");
    fflush(stdout);
    return 0;
}
