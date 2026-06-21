/*
 * user/syscall_nums.h — per-target syscall-number table for the Adder
 * userspace runtimes.
 *
 * Historically the syscall numbers were scattered as bare `movq $N,%rax`
 * literals across user/runtime.S (Hamnix native ABI). Each new target —
 * x86-adder-user (Hamnix), x86_64-linux, aarch64-* — risked copy-paste
 * divergence. This header centralizes the numbers as named `.set` symbols
 * so a runtime stub reads `movq $SYS_write, %rax` and the number lives in
 * exactly one place per ABI.
 *
 * Selection is by a `-DHAMNIX_ABI` / `-DLINUX_ABI` flag the build passes
 * explicitly (assemble the .S through `gcc`/`cpp` so the #ifdefs resolve).
 * The two ABIs are deliberately DISJOINT number spaces:
 *
 *   - Hamnix native ABI  (HAMNIX_ABI): the kernel dispatch table in
 *     arch/x86/kernel/syscall.ad. user/runtime.S still inlines these as
 *     raw literals (it is load-bearing + heavily annotated; left as-is to
 *     avoid destabilizing the Hamnix boot path), but they are MIRRORED
 *     here so a new Hamnix-side stub can name them instead of copy-pasting.
 *
 *   - Linux x86_64 ABI   (LINUX_ABI): the stable arch/x86/entry syscall
 *     table. user/linux-runtime.S consumes these for the freestanding
 *     `x86_64-linux` Adder target (host-native ELF, no libc).
 *
 * The aarch64 Linux numbers (write=64, exit=93, ...) live in the codegen
 * itself (adder/compiler/codegen_arm64.py) because that backend emits its
 * own inline `_start`; they are noted at the bottom for cross-reference.
 */

#ifndef HAMNIX_SYSCALL_NUMS_H
#define HAMNIX_SYSCALL_NUMS_H

/* -------------------------------------------------------------------------
 * Linux x86_64 ABI (asm/unistd_64.h). Used by user/linux-runtime.S for the
 * `x86_64-linux` freestanding target, which runs on the HOST Linux kernel.
 * ---------------------------------------------------------------------- */
#ifdef LINUX_ABI
    .set SYS_read,   0
    .set SYS_write,  1
    .set SYS_open,   2
    .set SYS_close,  3
    .set SYS_lseek,  8
    .set SYS_exit,   60
#endif /* LINUX_ABI */

/* -------------------------------------------------------------------------
 * Hamnix native ABI (arch/x86/kernel/syscall.ad dispatch table). Mirrored
 * for new native stubs; the legacy literals in user/runtime.S are kept in
 * sync by hand. NOTE: these are NOT Linux numbers — e.g. native write=8,
 * exit=1 — so the two blocks must never be active at once.
 * ---------------------------------------------------------------------- */
#ifdef HAMNIX_ABI
    .set HAMNIX_SYS_putc,          0
    .set HAMNIX_SYS_exit,          1
    .set HAMNIX_SYS_get_jiffies,   2
    .set HAMNIX_SYS_getpid,        4
    .set HAMNIX_SYS_open,          5
    .set HAMNIX_SYS_read,          6
    .set HAMNIX_SYS_close,         7
    .set HAMNIX_SYS_write,         8
    .set HAMNIX_SYS_lseek,         9
    .set HAMNIX_SYS_execve,        10
    .set HAMNIX_SYS_open_write,    13
#endif /* HAMNIX_ABI */

/*
 * aarch64 Linux ABI (for cross-reference; defined in codegen_arm64.py):
 *   SYS_write = 64, SYS_exit = 93
 */

#endif /* HAMNIX_SYSCALL_NUMS_H */
