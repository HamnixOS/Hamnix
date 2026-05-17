/* tests/u-binary/src/musl_thread_join_many/hello.c -- U28 stress
 * fixture.
 *
 * 4 workers each do an mmap+write+munmap loop. Tests:
 *   - fd-table sharing across threads (every worker writes to stdout
 *     which lives in the shared fd table set up by do_clone),
 *   - mmap table thread-safety (concurrent mmap/munmap from multiple
 *     workers — kernel's mmap allocator is single-threaded today, so
 *     each syscall serializes naturally, but the entry/exit ordering
 *     matters),
 *   - per-thread state isolation: each worker has its own page pointer
 *     in a stack local, never racing with peers.
 *
 * NUM_THREADS is held to 4 so the runqueue (NTASKS=16 in U28) stays
 * comfortably below ceiling alongside init/hamsh/main + the mmap-loop
 * peak (the kernel's LINUX_MMAP_SLOTS=32 also caps concurrent
 * mmappings; each worker holds at most one mapping at a time).
 *
 * PASS: all worker-done markers + the final counter:
 *   - "U28: jthread N done" for N in 1..4
 *   - "U28: jcounter=4 (expect 4)"
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>

#define NUM_THREADS 4
#define MMAP_ITERS  3
#define MMAP_SIZE   4096

static int jcounter = 0;
static pthread_mutex_t jlock = PTHREAD_MUTEX_INITIALIZER;

void *jworker(void *arg) {
    long id = (long)arg;
    /* Each iteration: allocate a 4 KiB page, scribble in it, free it.
     * If page protection or fd-table sharing were broken, the writes
     * would crash or write to the wrong stream. */
    for (int i = 0; i < MMAP_ITERS; i++) {
        void *p = mmap(NULL, MMAP_SIZE, PROT_READ | PROT_WRITE,
                       MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
        if (p == MAP_FAILED) {
            printf("U28: jthread %ld mmap FAILED\n", id);
            fflush(stdout);
            return NULL;
        }
        memset(p, (int)id, MMAP_SIZE);
        /* Read back one byte to make sure the page is actually
         * writable for THIS thread (catches false-sharing bugs). */
        unsigned char got = ((unsigned char *)p)[0];
        if (got != (unsigned char)id) {
            printf("U28: jthread %ld MISMATCH (got=%d)\n", id,
                   (int)got);
            fflush(stdout);
        }
        munmap(p, MMAP_SIZE);
    }
    pthread_mutex_lock(&jlock);
    jcounter++;
    pthread_mutex_unlock(&jlock);
    printf("U28: jthread %ld done\n", id);
    fflush(stdout);
    return NULL;
}

int main(void) {
    pthread_t t[NUM_THREADS];
    for (long i = 0; i < NUM_THREADS; i++) {
        pthread_create(&t[i], NULL, jworker, (void *)(i + 1));
    }
    for (int i = 0; i < NUM_THREADS; i++) {
        pthread_join(t[i], NULL);
    }
    printf("U28: jcounter=%d (expect %d)\n", jcounter, NUM_THREADS);
    fflush(stdout);
    return jcounter == NUM_THREADS ? 0 : 1;
}
