/* scripts/adder_llvm_runtime.c — minimal C runtime for the OPTIONAL Adder LLVM
 * backend (adder/compiler/ssa_llvm.ad, wired into host_ac.elf via
 * --backend=llvm). A whole Adder program lowered to .ll and linked with clang
 * gets its entry (_start -> main) from the C library; this stub supplies the
 * prelude/IO helpers that fall OUTSIDE the SSA integer subset and therefore
 * emit as external `declare`s in the .ll:
 *
 *   print_u64(v) — writes a decimal uint64 + newline to stdout, byte-for-byte
 *                  identical to tests/bench/opt/_prelude.ad's print_u64 (which
 *                  bails: it takes the address of a global array and issues a
 *                  raw write syscall). Returns i64 so the `.ll` ABI
 *                  `declare i64 @print_u64(i64)` matches.
 *
 * Build wrapper: scripts/adder_cc_llvm.sh. */
#include <unistd.h>

long print_u64(unsigned long v) {
    char buf[32];
    char tmp[32];
    int n = 0, t = 0;
    if (v == 0) { buf[n++] = '0'; }
    while (v) { tmp[t++] = (char)('0' + (v % 10)); v /= 10; }
    while (t) buf[n++] = tmp[--t];
    buf[n++] = '\n';
    (void)!write(1, buf, n);
    return 0;
}
