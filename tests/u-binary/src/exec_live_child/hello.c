/*
 * tests/u-binary/src/exec_live_child/hello.c
 *
 * Targets the SPECIFIC fork+exec COW frame-lifetime trigger the
 * dpkg_shaped fixture does NOT hit: a process that OWNS its ELF image
 * region forks a child (which COW-shares that image, bumping the per-PFN
 * cow_refcount), then the PARENT execve()s a DIFFERENT image while the
 * child is STILL ALIVE.
 *
 * do_execve -> task_free_owner_regions() does region_free(image) on the
 * outgoing image UNCONDITIONALLY (no cow_refcount check). The still-live
 * child COW-maps those same .text/.rodata frames (refcount >= 2). The
 * freed region returns to the size-bucketed region pool, and the very
 * next region_alloc (the parent's NEW exec image, or any spawn) reuses
 * those frames -- corrupting the running child's code/data underneath it.
 * The child then SIGSEGVs / mis-executes (a torn pointer, NX fault, or
 * wild value), exactly the apt-install symptom class.
 *
 * Shape:
 *   grandparent (this main):
 *     fork() -> CHILD: loop doing dynamic libc work (malloc/printf/qsort)
 *               keyed off the IMAGE's own .text+.rodata so corruption
 *               of those frames shows up as a wrong checksum / crash.
 *               Prints "ELC: child round N ok cksum=..." each iteration.
 *            -> PARENT: brief pause to let the child start, then execve()
 *               /bin/u_dynamic_hello -- which region_alloc's a fresh
 *               image (reusing the just-freed, still-COW-mapped frames).
 *   The execed hello prints "U42 dynamic hello" then exits; that orphans
 *   the child, which keeps looping. The TEST harness reaps via the shell.
 *
 * Because exec replaces the parent, we run the WHOLE thing under a
 * top-level launcher that forks the grandparent and waits, so the shell
 * gets a clean prompt back. main() here IS the grandparent.
 *
 * PASS marker (the child completed all rounds with stable checksums):
 *   "ELC: child survived all rounds"
 * FAIL: child crashes mid-loop, or a round's cksum changes (image frame
 *   was reused under it) -> marker never prints / "ELC: CKSUM DRIFT".
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

extern char **environ;

/* A const table living in .rodata of THIS image. If the parent's exec
 * frees + a region_alloc reuses these frames while we (the child) still
 * COW-map them, reading this table returns garbage and the checksum
 * drifts -- a direct probe of image-frame corruption. */
static const unsigned int RODATA_PROBE[64] = {
    0x9e3779b1u, 0x243f6a88u, 0x85a308d3u, 0x13198a2eu,
    0x03707344u, 0xa4093822u, 0x299f31d0u, 0x082efa98u,
    0xec4e6c89u, 0x452821e6u, 0x38d01377u, 0xbe5466cfu,
    0x34e90c6cu, 0xc0ac29b7u, 0xc97c50ddu, 0x3f84d5b5u,
    0xb5470917u, 0x9216d5d9u, 0x8979fb1bu, 0xd1310ba6u,
    0x98dfb5acu, 0x2ffd72dbu, 0xd01adfb7u, 0xb8e1afedu,
    0x6a267e96u, 0xba7c9045u, 0xf12c7f99u, 0x24a19947u,
    0xb3916cf7u, 0x0801f2e2u, 0x858efc16u, 0x636920d8u,
    0x71574e69u, 0xa458fea3u, 0xf4933d7eu, 0x0d95748fu,
    0x728eb658u, 0x718bcd58u, 0x82154aeeu, 0x7b54a41du,
    0xc25a59b5u, 0x9c30d539u, 0x2af26013u, 0xc5d1b023u,
    0x286085f0u, 0xca417918u, 0xb8db38efu, 0x8e79dcb0u,
    0x603a180eu, 0x6c9e0e8bu, 0xb01e8a3eu, 0xd71577c1u,
    0xbd314b27u, 0x78af2fdau, 0x55605c60u, 0xe65525f3u,
    0xaa55ab94u, 0x57489862u, 0x63e81440u, 0x55ca396au,
    0x2aab10b6u, 0xb4cc5c34u, 0x1141e8ceu, 0xa15486afu,
};

static unsigned int expected_cksum(void) {
    unsigned int c = 0;
    for (int i = 0; i < 64; i++) c = c * 1000003u + RODATA_PROBE[i];
    return c;
}

static void child_loop(void) {
    unsigned int want = expected_cksum();
    for (int round = 0; round < 200; round++) {
        /* Re-read .rodata each round; if the image frame was reused
         * under us the checksum changes. */
        unsigned int got = expected_cksum();
        if (got != want) {
            printf("ELC: CKSUM DRIFT round=%d want=%08x got=%08x\n",
                   round, want, got);
            fflush(stdout);
            _exit(4);
        }
        /* Heavy dynamic libc churn so we keep re-entering ld.so PLT
         * slots + walking malloc arenas while the parent execs. */
        unsigned long acc = 0;
        for (int i = 0; i < 32; i++) {
            char *p = malloc(128 + ((round * 31 + i * 7) & 1023));
            if (p) { memset(p, i & 0xff, 64); acc += (unsigned long)p[0]; free(p); }
        }
        char buf[48];
        snprintf(buf, sizeof(buf), "r%d-%lu", round, acc);
        if ((round % 40) == 0) {
            printf("ELC: child round %d ok cksum=%08x\n", round, got);
            fflush(stdout);
        }
        /* Brief yield so the parent's exec interleaves with our loop. */
        usleep(2000);
    }
    printf("ELC: child survived all rounds\n");
    fflush(stdout);
    _exit(0);
}

int main(void) {
    printf("ELC: grandparent start\n");
    fflush(stdout);

    /* Repeat several times: each iteration spawns a parent that forks a
     * live child then execs, maximizing the chance the freed image region
     * is reused under a live child. */
    for (int iter = 0; iter < 4; iter++) {
        pid_t gp = fork();
        if (gp < 0) { perror("fork-gp"); return 1; }
        if (gp == 0) {
            /* PARENT (owns this image region). Fork the live child. */
            pid_t ch = fork();
            if (ch < 0) { perror("fork-ch"); _exit(1); }
            if (ch == 0) {
                child_loop();          /* never returns */
            }
            /* Let the child get into its loop (so it is genuinely live and
             * COW-mapping the image) before we free our image via execve. */
            usleep(20000);
            char *args[] = {"/bin/u_dynamic_hello", NULL};
            execve("/bin/u_dynamic_hello", args, environ);
            perror("execve");
            _exit(127);
        }
        /* grandparent: wait for the PARENT (the execed hello) to exit.
         * The orphaned child keeps running; we give it time, then move on.
         * The child reparents to us (its grandparent) on the parent's
         * exit, so we can reap it too. */
        int st = 0;
        waitpid(gp, &st, 0);
        /* Reap the reparented child (now our child). */
        pid_t r;
        while ((r = waitpid(-1, &st, 0)) > 0) { /* drain */ }
    }

    printf("ELC: grandparent done\n");
    fflush(stdout);
    return 0;
}
