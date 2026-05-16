/*
 * tests/u-binary/src/musl_argv/hello.c — U15 fixture.
 *
 * Second "real toolchain-built C binary" target for Hamnix's U-track.
 * Where U12 (tests/u-binary/src/musl_hello/hello.c) bypassed musl's
 * stdio with a raw inline write(2) syscall, this fixture exercises the
 * entire musl printf path: format-string parsing, locale lookup, the
 * FILE* lock, and the writev/write fallback for line-buffered stdout.
 *
 * Build:
 *
 *     musl-gcc -static-pie -O2 -o ../../u_musl_argv hello.c
 *
 * What this stresses (relative to U12):
 *   - printf(3) — pulls in vfprintf, FILE init, locale, exit-time flush.
 *   - argc/argv walk — verifies the kernel's process startup hands main()
 *     a valid argv[] (Hamnix doesn't build a real auxv, so argv is the
 *     interesting layout question).
 *   - setvbuf(_IONBF) — forces stdout unbuffered so we don't depend on
 *     musl flushing on exit. With buffered stdout + a kernel exit_group
 *     that doesn't run libc atexit handlers, printf output would silently
 *     vanish; this neutralises that failure mode.
 *
 * Marker: "U15: musl printf works! argc=N" on serial == U15 PASS.
 */

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    /* Force stdout to unbuffered so printf hits the kernel writev path
     * immediately. Otherwise musl line-buffers stdout when fstat(1)
     * reports a non-tty, and a sudden exit_group() truncates the
     * buffer. Hamnix's _u_fstat returns S_IFREG (the "everything is a
     * regular file" stub), so without this call we'd be line-buffered.
     * Even with line buffering the trailing '\n' would flush each
     * printf, but being explicit makes the test deterministic. */
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("U15: musl printf works! argc=%d\n", argc);
    for (int i = 0; i < argc; i++) {
        printf("  arg[%d]=%s\n", i, argv[i] ? argv[i] : "(null)");
    }

    /* Belt-and-braces: explicit flush in case printf above queued
     * anything despite _IONBF (or if a future toolchain re-buffers
     * around the setvbuf call). Returning from main runs musl's
     * atexit chain which also flushes, but we may exit_group before
     * that depending on how Hamnix's runtime unwinds. */
    fflush(stdout);
    return 0;
}
