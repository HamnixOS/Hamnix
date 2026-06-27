/*
 * tests/u-binary/src/dpkg_shaped/hello.c -- dpkg-shaped fork/exec/reap repro.
 *
 * The dynamic_forkexec canary forks, the child execve()s another dynamic
 * binary, and the parent reaps -- then returns from main(). That PASSES.
 *
 * The REAL dpkg/apt fault needs one more beat: after the parent REAPS the
 * child, the parent KEEPS CALLING INTO ld.so / its own link_map (lazy
 * symbol binding, malloc arena growth, more libc work). The hypothesis is
 * that the child's execve teardown freed/reused a physical frame the parent
 * still COW-maps (its libc/.text/ld.so link_map page), so the parent's next
 * dynamic-symbol dereference loads a TORN pointer and SIGSEGVs (observed
 * cr2 ~ 0xf52e). This fixture reproduces THAT continuation, no network.
 *
 * Sequence (mirrors dpkg -> dpkg-split helper -> dpkg continues):
 *   1. parent: print "DPKGS: before fork"
 *   2. parent: fork(); child execve()s /bin/u_dynamic_hello (2nd-gen dyn)
 *   3. child: prints "U42 dynamic hello", exits 0
 *   4. parent: waitpid() reaps the child
 *   5. parent: NOW does heavy dynamic work -- malloc/free churn (grows the
 *      glibc main arena, walks ld.so structures), lazily binds fresh libc
 *      symbols (strdup, snprintf, qsort, strtol, getenv), repeats the whole
 *      fork+exec+reap cycle several times (dpkg unpacks many helpers).
 *   6. parent: print "DPKGS: parent survived post-reap dynamic work" == PASS
 *
 * Markers on serial:
 *   "DPKGS: before fork"
 *   "U42 dynamic hello"                                  (per child)
 *   "DPKGS: parent survived post-reap dynamic work"      == PASS
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

extern char **environ;

static int cmp_int(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}

/* Do work that forces ld.so lazy binding + malloc arena traversal,
 * i.e. dereferences the parent's own link_map / libc structures that
 * a buggy child-exec teardown may have freed out from under us. */
static unsigned long churn(int round) {
    unsigned long acc = 0;
    /* malloc/free churn: grows + walks the main arena. */
    for (int i = 0; i < 64; i++) {
        size_t n = (size_t)(64 + ((round * 37 + i * 13) & 4095));
        char *p = (char *)malloc(n);
        if (!p) continue;
        memset(p, (i ^ round) & 0xff, n);
        /* snprintf -> lazily binds vfprintf internals through the PLT. */
        char buf[64];
        snprintf(buf, sizeof(buf), "r%d-i%d-n%zu", round, i, n);
        acc += (unsigned long)strtol(buf + 1, NULL, 10);
        char *d = strdup(buf);            /* strdup -> malloc again */
        if (d) { acc += (unsigned long)strlen(d); free(d); }
        free(p);
    }
    /* qsort -> another PLT slot, calls back into our comparator. */
    int arr[32];
    for (int i = 0; i < 32; i++) arr[i] = (i * 2654435761u + round) & 0xffff;
    qsort(arr, 32, sizeof(int), cmp_int);
    for (int i = 0; i < 32; i++) acc += (unsigned long)arr[i];
    /* getenv -> walks environ via libc. */
    const char *pth = getenv("PATH");
    if (pth) acc += (unsigned long)strlen(pth);
    return acc;
}

static int fork_exec_reap(void) {
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return -1; }
    if (pid == 0) {
        char *args[] = {"/bin/u_dynamic_hello", NULL};
        execve("/bin/u_dynamic_hello", args, environ);
        perror("execve");
        _exit(127);
    }
    int wstatus = 0;
    pid_t reaped = waitpid(pid, &wstatus, 0);
    if (reaped != pid) {
        printf("DPKGS: waitpid returned %d (expected %d)\n", reaped, pid);
        return -1;
    }
    if (!WIFEXITED(wstatus) || WEXITSTATUS(wstatus) != 0) {
        printf("DPKGS: child bad status 0x%x\n", wstatus);
        return -1;
    }
    return 0;
}

int main(void) {
    printf("DPKGS: before fork\n");
    fflush(stdout);

    unsigned long acc = 0;
    /* dpkg unpacks/configures MANY packages: repeat the fork+exec+reap+
     * heavy-dynamic-work cycle so a frame freed by ANY child's exec
     * teardown is reused before the parent next dereferences it. */
    for (int round = 0; round < 5; round++) {
        if (fork_exec_reap() != 0)
            return 2;
        /* THE KEYSTONE BEAT: parent reaped, now keep walking ld.so/libc. */
        acc += churn(round);
        printf("DPKGS: round %d ok (acc=%lu)\n", round, acc);
        fflush(stdout);
    }

    printf("DPKGS: parent survived post-reap dynamic work (acc=%lu)\n", acc);
    fflush(stdout);
    return 0;
}
