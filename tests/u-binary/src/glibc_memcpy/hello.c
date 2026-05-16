/*
 * tests/u-binary/src/glibc_memcpy/hello.c -- U20 fixture.
 *
 * U20 milestone: kernel ELF loader stopped processing relocations.
 * glibc's own _dl_relocate_static_pie must now fix up RELATIVE,
 * GLOB_DAT, JUMP_SLOT *and* IRELATIVE entries in startup. The
 * IRELATIVE entries point at IFUNC resolver functions that pick the
 * fastest variant of memcpy / memset / strlen / etc. for the CPU.
 *
 * If the IFUNC pass didn't run, the .got slot for memcpy points at
 * the resolver function instead of the resolved implementation; the
 * first call lands in the resolver, runs CPUID dispatch, and returns
 * — but the call site is expecting memcpy semantics, so the binary
 * either segfaults or writes garbage. This fixture deliberately
 * exercises that path: copy a literal string with memcpy, then fputs
 * it. If "U20: ifunc memcpy ok" appears on serial, glibc's startup
 * ran the IFUNC resolvers to completion.
 *
 * Build: gcc -static-pie -O2 (same as the U19 glibc_hello fixture).
 */
#include <stdio.h>
#include <string.h>
int main(void) {
    char dst[64] = {0};
    const char *src = "U20: ifunc memcpy ok\n";
    memcpy(dst, src, 21);
    fputs(dst, stdout);
    return 0;
}
