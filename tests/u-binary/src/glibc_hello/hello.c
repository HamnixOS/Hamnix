/*
 * tests/u-binary/src/glibc_hello/hello.c -- U18 fixture.
 *
 * First attempt at running a real glibc-static-linked C binary on
 * Hamnix. Built with the host's stock toolchain:
 *
 *     gcc -static -O2 -o ../../u_glibc_hello hello.c
 *
 * Unlike musl static-PIE (U12), glibc's static startup is heavy:
 * __libc_start_main pulls in TLS bring-up, rseq, set_robust_list,
 * sigaction/sigprocmask installations, mprotect, plus the usual
 * brk/mmap/writev/uname/arch_prctl(SET_FS). U18's purpose is to
 * exercise that fatter surface and discover which syscall (or fault)
 * Hamnix needs to grow next.
 *
 * The binary is ET_EXEC (not ET_DYN) with fixed VAs starting at
 * 0x400000, which sits inside Hamnix's 4 GiB identity map so the
 * existing ELF64 loader's "rebase relative to lowest_v" copy strategy
 * happens to land the segments at their link-time addresses too.
 *
 * Marker on serial:  "U18: glibc static hello"  == PASS.
 */
#include <stdio.h>

int main(void) {
    printf("U18: glibc static hello\n");
    return 0;
}
