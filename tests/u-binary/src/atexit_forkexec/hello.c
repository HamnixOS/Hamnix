/*
 * tests/u-binary/src/atexit_forkexec/hello.c
 *
 * TIGHTER REPRO for the XWayland X-display gate (fork+exec .bss exit-list
 * COW corruption). Isolates the COW-teardown corruption away from
 * Xwayland/dash: the PARENT registers atexit()/__cxa_atexit handlers (which
 * glibc stores, pointer-mangled, in its __exit_funcs list in libc .bss),
 * fork()s a child that execve()s a SECOND dynamic binary, reaps it, then
 * returns from main() so glibc __run_exit_handlers walks the exit list and
 * CALLS each handler. If the child's do_execve/COW teardown corrupted a
 * .bss page COW-shared with the parent, the parent's exit-handler pointer
 * (or the list linkage) is scribbled and the call jumps into .bss (RW+NX)
 * -> NX exec-fault -> SIGSEGV (== the dash System() failure). If the COW is
 * honest, every handler runs and the PASS marker prints.
 *
 * To maximise COW churn on .bss the parent also owns a large global (.bss)
 * table of function pointers it writes before the fork and VERIFIES after
 * reaping the child — a direct check that a COW-shared .bss frame was not
 * mutated behind the parent's back. The fork+exec+wait is looped (like a
 * shell running several external commands) to match dash's System() usage.
 *
 * Child execve target: /bin/u_dynamic_hello (the dynamic_hello fixture).
 *
 * Markers on serial:
 *   "AXFE: parent before fork round N"
 *   "U42 dynamic hello"                    (child execve succeeded)
 *   "AXFE: reaped child round N status=0"
 *   "AXFE: bss table intact"               (COW .bss not corrupted)
 *   "AXFE: atexit handler ran tag=..."     (exit list survived)
 *   "AXFE: PASS all exit handlers ran"     == PASS (printed from last handler)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>

extern char **environ;

#define NPTRS 4096
/* A large .bss table of function pointers -- spans several .bss pages so a
 * COW-teardown scribble is very likely to land inside it. */
static void (*bss_table[NPTRS])(void);
/* A canary function whose address we plant across the whole table. */
static void canary(void) { /* nothing */ }

#define NHANDLERS 8
static volatile int handlers_run;

static void exit_handler_last(void) {
    /* If the exit list / this fn pointer were corrupted we would never
     * reach here (we'd NX-fault jumping to a bad pointer instead). */
    printf("AXFE: atexit handler ran tag=last run_count=%d\n", handlers_run);
    if (handlers_run == NHANDLERS)
        printf("AXFE: PASS all exit handlers ran\n");
    else
        printf("AXFE: FAIL only %d/%d exit handlers ran\n",
               handlers_run, NHANDLERS);
    fflush(stdout);
}
static void exit_handler_n(void) {
    handlers_run++;
}

int main(void) {
    /* Fill the whole .bss pointer table with a valid .text address. */
    for (int i = 0; i < NPTRS; i++)
        bss_table[i] = canary;

    /* Register a stack of exit handlers -> glibc grows __exit_funcs in
     * libc .bss (or a malloc'd extension block). exit_handler_last is
     * registered FIRST so it runs LAST (LIFO). */
    atexit(exit_handler_last);
    for (int i = 0; i < NHANDLERS; i++)
        atexit(exit_handler_n);

    for (int round = 0; round < 3; round++) {
        printf("AXFE: parent before spawn round %d\n", round);
        fflush(stdout);
        /* RAW vfork(2) is exactly what dash's vforkexec uses: clone(
         * CLONE_VM|CLONE_VFORK|SIGCHLD, child_stack=0, ...). The child
         * resumes on the PARENT's copied RSP (do_clone's child_stack==0
         * resume-%rdi path), then execve's the target while the parent is
         * SUSPENDED. This is a THIRD, distinct do_clone path (not plain
         * fork(), not posix_spawn's child_stack path) and is the one the
         * XWayland -> dash -> xkbcomp chain actually rides. */
        char *args[] = {"/bin/u_dynamic_hello", NULL};
        pid_t pid = vfork();
        if (pid < 0) { perror("vfork"); return 1; }
        if (pid == 0) {
            execve("/bin/u_dynamic_hello", args, environ);
            _exit(127);
        }
        int wstatus = 0;
        pid_t reaped = waitpid(pid, &wstatus, 0);
        if (reaped != pid || !WIFEXITED(wstatus)) {
            printf("AXFE: bad reap round %d reaped=%d st=%d\n",
                   round, reaped, wstatus);
            return 2;
        }
        printf("AXFE: reaped child round %d status=%d\n",
               round, WEXITSTATUS(wstatus));
        fflush(stdout);

        /* Verify the parent's COW-shared .bss table was not scribbled by
         * the child's exec teardown. */
        int bad = 0;
        for (int i = 0; i < NPTRS; i++)
            if (bss_table[i] != canary) { bad = i; break; }
        if (bad) {
            printf("AXFE: FAIL bss table CORRUPTED at idx=%d val=%p round=%d\n",
                   bad, (void *)bss_table[bad], round);
            fflush(stdout);
            return 3;
        }
    }
    printf("AXFE: bss table intact\n");
    fflush(stdout);
    /* Return -> glibc __run_exit_handlers walks __exit_funcs and calls each
     * registered handler. This is the exact path dash takes at System()'s
     * dash-child exit that NX-faults on the corrupted pointer. */
    return 0;
}
