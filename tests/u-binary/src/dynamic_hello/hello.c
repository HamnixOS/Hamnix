/*
 * tests/u-binary/src/dynamic_hello/hello.c -- U42 dynamic-ELF fixture.
 *
 * First DYNAMICALLY linked C binary on Hamnix. Built with the host's
 * stock toolchain in default (dynamic) mode:
 *
 *     gcc -O2 -Wl,-dynamic-linker,/lib64/ld-linux-x86-64.so.2 \
 *         -o ../../u_dynamic_hello hello.c
 *
 * Unlike U18..U22 (static-PIE glibc) and U27 (musl pthread, also
 * static-PIE), this binary has a PT_INTERP segment pointing at
 * /lib64/ld-linux-x86-64.so.2. The kernel's ELF loader has to:
 *
 *   1. Detect PT_INTERP.
 *   2. Open the named interpreter (a full glibc ld.so, ~230 KB on
 *      Debian) AS ITS OWN ELF.
 *   3. Load the interpreter at a reserved base distinct from the
 *      application's own image.
 *   4. Populate the auxv with AT_BASE pointing at the interpreter's
 *      load base (NOT the application's), AT_PHDR pointing at the
 *      application's program-header table, and AT_ENTRY pointing at
 *      the application's e_entry.
 *   5. Transfer control to the INTERPRETER's e_entry — not the
 *      application's. ld.so then walks the application's PT_DYNAMIC,
 *      resolves DT_NEEDED entries, applies relocations, and finally
 *      jumps to the application's e_entry from inside userspace.
 *
 * Marker on serial:  "U42 dynamic hello"  == PASS.
 */
#include <stdio.h>

int main(void) {
    puts("U42 dynamic hello");
    return 0;
}
