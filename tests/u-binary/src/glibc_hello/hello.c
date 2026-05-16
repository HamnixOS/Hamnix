/*
 * tests/u-binary/src/glibc_hello/hello.c -- U19 fixture.
 *
 * First glibc-linked C binary on Hamnix. Built with the host's stock
 * toolchain:
 *
 *     gcc -static-pie -O2 -o ../../u_glibc_hello hello.c
 *
 * Unlike musl static-PIE (U12), glibc's startup is heavy: __libc_start_main
 * pulls in TLS bring-up, rseq, set_robust_list, sigaction/sigprocmask
 * installations, mprotect, prlimit64, getrandom (canary), plus the usual
 * brk/mmap/writev/uname/arch_prctl(SET_FS). U19's purpose is to exercise
 * that fatter surface and discover which syscall (or fault) Hamnix
 * needs to grow next.
 *
 * Build mode is -static-pie (ET_DYN), NOT -static (ET_EXEC). U18 used
 * -static and crashed at the first .got/.got.plt indirection because
 * Hamnix's loader copies segments to a kernel-chosen base but does
 * not rewrite ET_EXEC's absolute addresses. -static-pie produces a
 * relocatable ET_DYN binary with R_X86_64_RELATIVE entries in
 * .rela.dyn that the U10 ELF loader already handles for musl_hello.
 *
 * Marker on serial:  "U18: glibc static hello"  == PASS.
 * (Marker string kept stable across U18->U19 so test fixtures and any
 * pinned grep targets continue to match.)
 */
#include <stdio.h>

int main(void) {
    printf("U18: glibc static hello\n");
    return 0;
}
