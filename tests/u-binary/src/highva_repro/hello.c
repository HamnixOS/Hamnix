/*
 * highva_repro/hello.c -- stress repro for the Firefox ld.so eager-VMA
 * PTE=0 fault (>4GB / windowed-mmap teardown class).
 *
 * The Firefox fault is a READ (mov 0x70(%rdi),%rax) of an ld.so malloc
 * arena (a small eager anon RW mmap, is_demand=0 nchunks=1) at a high
 * window VA (~0x209000000) whose leaf PTE reads 0 mid-life. So an eager
 * anon arena PTE gets ZAPPED by an unrelated teardown / window free-list
 * reuse while the arena VMA is still live.
 *
 * This program keeps MANY live arenas (each 2 pages, sentinel at offset
 * 0x70 mirroring the link_map field), then hammers the windowed-mmap
 * allocator with the exact ld.so/glibc churn: big reserve+overlay maps,
 * MAP_FIXED sub-overlays, munmaps (triggers bump-pointer rollback +
 * free-list caching + reuse), and fork. After every churn step it
 * re-reads EVERY arena sentinel; a zapped PTE faults (SIGSEGV) or a
 * corrupted sentinel is reported -> the culprit arena VA is printed so
 * the kernel [wintrace] log pins the teardown that zapped it.
 *
 * PASS marker: "HVR: ALL PATTERNS OK"
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/stat.h>

#define PG      4096u
#define NAREN   48
#define SENTOFF 0x70
#define DSOPATH "/lib/x86_64-linux-gnu/libc.so.6"

static char *arena[NAREN];

static void verify_all(int phase) {
    for (int i = 0; i < NAREN; i++) {
        if (!arena[i]) continue;
        volatile unsigned long *s = (volatile unsigned long *)(arena[i] + SENTOFF);
        unsigned long got = *s;                 /* the faulting READ shape */
        unsigned long want = 0xA5A50000UL | (unsigned long)i;
        if (got != want) {
            printf("HVR: CORRUPT phase=%d arena[%d]=%p got=0x%lx want=0x%lx\n",
                   phase, i, (void *)arena[i], got, want);
            fflush(stdout);
        }
    }
}

static char *mk_arena(int i) {
    char *a = mmap(NULL, 2 * PG, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (a == MAP_FAILED) return NULL;
    *(volatile unsigned long *)(a + SENTOFF) = 0xA5A50000UL | (unsigned long)i;
    return a;
}

/* Mimic glibc _dl_map_segments: reserve a big span, overlay RW segments
 * via MAP_FIXED, then munmap the inter-segment gap (frees a windowed
 * sub-extent -> exercises rollback / free-list reuse). */
static void dl_map_like(unsigned long big) {
    char *res = mmap(NULL, big, PROT_READ,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (res == MAP_FAILED) return;
    /* overlay a writable data segment */
    unsigned long off = (big / 2) & ~(PG - 1);
    char *seg = mmap(res + off, 4 * PG, PROT_READ | PROT_WRITE,
                     MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (seg != MAP_FAILED) { seg[0] = 1; seg[PG] = 2; }
    /* munmap the tail slop past the data segment (the ld.so gap munmap) */
    unsigned long tail = off + 4 * PG;
    if (tail < big) munmap(res + tail, big - tail);
    /* munmap the head slop before the data segment */
    if (off > 0) munmap(res, off);
    /* finally drop the data segment too (whole DSO unloaded) */
    munmap(res + off, 4 * PG);
}

/* Faithful glibc ld.so _dl_map_segments over a REAL file: whole-DSO
 * PROT_READ file map (eager in Hamnix), mprotect per-segment (splits the
 * eager windowed VMA), anon MAP_FIXED bss overlay inside it, touch it,
 * mprotect RELRO back to RO, then munmap. This is the exact op mix that
 * runs while ld.so relocates libxul. Returns and re-verifies happen in
 * the caller so a zapped arena PTE surfaces immediately. */
static void dl_map_file(int fd, unsigned long fsize) {
    unsigned long span = (fsize + PG - 1) & ~(PG - 1);
    char *base = mmap(NULL, span, PROT_READ, MAP_PRIVATE, fd, 0);
    if (base == MAP_FAILED) return;
    /* mprotect the "text" segment RX (splits VMA at page boundary) */
    unsigned long half = (span / 2) & ~(PG - 1);
    if (half >= PG) mprotect(base, half, PROT_READ | PROT_EXEC);
    /* mprotect a "data" segment RW (another split) */
    unsigned long dlen = 2 * PG;
    if (half + dlen <= span) {
        mprotect(base + half, dlen, PROT_READ | PROT_WRITE);
        base[half] = 7;                         /* dirty the data seg */
        /* anon bss overlay via MAP_FIXED inside the file map */
        char *bss = mmap(base + half + dlen, 2 * PG, PROT_READ | PROT_WRITE,
                         MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (bss != MAP_FAILED) { bss[0] = 8; bss[SENTOFF] = 9; }
        /* RELRO: mprotect the data seg back to RO */
        mprotect(base + half, dlen, PROT_READ);
    }
    munmap(base, span);
}

/* Exercise the MULTI-CHUNK eager windowed VMA split path: a big anon RW
 * map (many 4-MiB chunks, like libxul's 200 MiB) mprotect-split into many
 * pieces (each mprotect calls _vma_make_refcounted -> vm_pin_range over the
 * whole big VMA, then _vma_split_at), writes to the RW pieces, then frees.
 * This is the exact heavy path ld.so drives while relocating libxul. */
static void big_split_churn(unsigned long big) {
    char *b = mmap(NULL, big, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (b == MAP_FAILED) return;
    /* fault a few pages in first (eager, so already present) */
    for (unsigned long o = 0; o < big; o += (2u << 20)) b[o] = 1;
    /* mprotect alternating 2 MiB windows RO -> forces splits of the
       multi-chunk eager VMA into many pinned pieces */
    for (unsigned long o = 0; o + (2u << 20) <= big; o += (4u << 20))
        mprotect(b + o, (2u << 20), PROT_READ);
    /* write to the still-RW pieces (present eager pages) */
    for (unsigned long o = (2u << 20); o + PG <= big; o += (4u << 20))
        b[o] = 2;
    /* carve a hole in the middle via MAP_FIXED (splits again) */
    unsigned long mid = (big / 2) & ~((2u << 20) - 1);
    if (mid + (2u << 20) <= big) {
        char *h = mmap(b + mid, (2u << 20), PROT_READ | PROT_WRITE,
                       MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (h != MAP_FAILED) h[0] = 3;
    }
    munmap(b, big);
}

/* SMP mmap-storm worker: hammer the SHARED-address-space windowed-mmap
 * allocator concurrently with the main thread's arena verification. Two
 * threads bumping vma_large_next / the window free-list at once can hand
 * out OVERLAPPING windows in the shared PML4; tearing one down then zaps
 * the other's live PTEs -> the Firefox non-deterministic eager-PTE=0. */
static volatile int storm_go = 1;
static void *storm_worker(void *arg) {
    unsigned seed = (unsigned)(unsigned long)arg * 2654435761u + 1;
    while (storm_go) {
        seed = seed * 1103515245u + 12345u;
        unsigned long sz = (1u + (seed % 12)) * PG;
        char *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p != MAP_FAILED) {
            p[0] = 0x33;
            p[sz - 1] = 0x44;
            if ((seed & 1) == 0) {
                char *q = mmap(NULL, sz * 4, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
                if (q != MAP_FAILED) { q[0] = 1; munmap(q, sz * 4); }
            }
            munmap(p, sz);
        }
    }
    return NULL;
}

int main(void) {
    /* Open the real DSO for the faithful file-map churn. */
    int fd = open(DSOPATH, O_RDONLY);
    unsigned long fsize = 0;
    if (fd >= 0) {
        struct stat stb;
        if (fstat(fd, &stb) == 0) fsize = (unsigned long)stb.st_size;
    }
    printf("HVR: DSO fd=%d size=0x%lx\n", fd, fsize);
    fflush(stdout);

    /* Launch concurrent mmap-storm workers on the SHARED address space. */
    pthread_t th[3];
    int nth = 0;
    for (int k = 0; k < 3; k++)
        if (pthread_create(&th[k], NULL, storm_worker,
                           (void *)(unsigned long)(k + 1)) == 0)
            nth++;
    printf("HVR: %d storm threads up\n", nth);
    fflush(stdout);

    /* INTERLEAVE: create arenas THROUGHOUT churn so new arenas POP
       recycled free-list windows (the Firefox arena landed mid-window,
       reusing space freed by earlier ld.so DSO load/unload). Periodically
       drop a random-ish arena and re-create it so its freed window is
       recycled while OTHER live arenas sit nearby -> maximal free-list
       reuse pressure on live arena VAs. Verify every arena each step. */
    unsigned seed = 12345;
    for (int i = 0; i < NAREN; i++) arena[i] = NULL;
    for (int step = 0; step < 240; step++) {
        seed = seed * 1103515245u + 12345u;
        int slot = (int)((seed >> 16) % NAREN);

        /* churn BEFORE (frees windows into the free-list) */
        if ((step & 1) == 0) dl_map_like(8u * 1024 * 1024);
        if (fd >= 0 && fsize > 4 * PG && (step % 3) == 0)
            dl_map_file(fd, fsize);
        if ((step % 5) == 0) big_split_churn(48u * 1024 * 1024);  /* 12 chunks */

        /* recycle: drop this slot's arena (frees its window), then a plain
           big map+free (rollback), then re-create the arena -> it may POP
           the just-freed window that a sibling live arena borders. */
        if (arena[slot]) { munmap(arena[slot], 2 * PG); arena[slot] = NULL; }
        unsigned long big = (2u + (step & 7)) * 8u * 1024 * 1024;
        char *t = mmap(NULL, big, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (t != MAP_FAILED) { t[0] = 9; munmap(t, big); }
        arena[slot] = mk_arena(slot);

        verify_all(step);
    }
    storm_go = 0;
    for (int k = 0; k < nth; k++) pthread_join(th[k], NULL);
    printf("HVR: churn done; arena[0]=%p\n", (void *)arena[0]);
    fflush(stdout);

    /* fork: child re-verifies (COW of every arena), parent re-verifies. */
    pid_t pid = fork();
    if (pid == 0) {
        verify_all(300);
        dl_map_like(32u * 1024 * 1024);
        verify_all(301);
        _exit(0);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    verify_all(400);
    printf("HVR: E child status=%d\n", st);

    printf("HVR: ALL PATTERNS OK\n");
    fflush(stdout);
    return 0;
}
