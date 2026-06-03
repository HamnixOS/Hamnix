/*
 * arch/arm64/vectors.S — Phase 3 EL1 exception vector table for Hamnix
 *                        aarch64 on QEMU `virt`.
 *
 * The AArch64 vector table is 0x800 bytes: 16 entries of 0x80 bytes each,
 * grouped in 4 sets of 4 (Synchronous / IRQ / FIQ / SError) for the source
 * exception levels:
 *   0x000 - Current EL with SP_EL0
 *   0x200 - Current EL with SP_ELx   <-- our kernel runs here (EL1h)
 *   0x400 - Lower EL using AArch64
 *   0x600 - Lower EL using AArch32
 *
 * VBAR_EL1 is pointed at `arm64_vectors` (0x800-aligned) by the Adder
 * kernel via the codegen `_install_vbar()` intrinsic. Each entry is padded
 * to 0x80 with `.balign`.
 *
 * The handlers themselves live in PURE ADDER (arch/arm64/kmain.ad): the IRQ
 * stub below saves the caller-clobbered GPR frame, calls the AAPCS64 handler
 * `arm64_irq_handler` (compiled from Adder), restores, and ERETs. Synchronous
 * / unexpected exceptions branch to the Adder diagnostics arm64_sync_panic /
 * arm64_unhandled_panic. This .S file owns ONLY the privileged table layout
 * and the register-frame save/restore that cannot be expressed from Adder.
 */

    .section .text.vectors, "ax"
    .balign 0x800
    .global arm64_vectors
arm64_vectors:

/* ---- Current EL with SP_EL0 (unused here) ---- */
    .balign 0x80
    b       arm64_unhandled         /* Synchronous */
    .balign 0x80
    b       arm64_unhandled         /* IRQ */
    .balign 0x80
    b       arm64_unhandled         /* FIQ */
    .balign 0x80
    b       arm64_unhandled         /* SError */

/* ---- Current EL with SP_ELx (this is where the kernel runs) ---- */
    .balign 0x80
    b       arm64_sync_handler      /* Synchronous (0x200) */
    .balign 0x80
    b       arm64_irq_entry         /* IRQ (0x280) */
    .balign 0x80
    b       arm64_unhandled         /* FIQ (0x300) */
    .balign 0x80
    b       arm64_unhandled         /* SError (0x380) */

/* ---- Lower EL using AArch64 (no userspace yet) ---- */
    .balign 0x80
    b       arm64_unhandled
    .balign 0x80
    b       arm64_unhandled
    .balign 0x80
    b       arm64_unhandled
    .balign 0x80
    b       arm64_unhandled

/* ---- Lower EL using AArch32 (unused) ---- */
    .balign 0x80
    b       arm64_unhandled
    .balign 0x80
    b       arm64_unhandled
    .balign 0x80
    b       arm64_unhandled
    .balign 0x80
    b       arm64_unhandled

    .balign 0x80

/*
 * IRQ entry stub. Save x0..x18 + x29/x30 (the AAPCS64 caller-saved set plus
 * the link register and frame pointer), call the Adder handler, restore, and
 * ERET. The frame stays 16-byte aligned.
 */
    .text
arm64_irq_entry:
    sub     sp, sp, #(16 * 11)
    stp     x0,  x1,  [sp, #(16 * 0)]
    stp     x2,  x3,  [sp, #(16 * 1)]
    stp     x4,  x5,  [sp, #(16 * 2)]
    stp     x6,  x7,  [sp, #(16 * 3)]
    stp     x8,  x9,  [sp, #(16 * 4)]
    stp     x10, x11, [sp, #(16 * 5)]
    stp     x12, x13, [sp, #(16 * 6)]
    stp     x14, x15, [sp, #(16 * 7)]
    stp     x16, x17, [sp, #(16 * 8)]
    stp     x18, x29, [sp, #(16 * 9)]
    str     x30,      [sp, #(16 * 10)]

    bl      arm64_irq_handler

    ldp     x0,  x1,  [sp, #(16 * 0)]
    ldp     x2,  x3,  [sp, #(16 * 1)]
    ldp     x4,  x5,  [sp, #(16 * 2)]
    ldp     x6,  x7,  [sp, #(16 * 3)]
    ldp     x8,  x9,  [sp, #(16 * 4)]
    ldp     x10, x11, [sp, #(16 * 5)]
    ldp     x12, x13, [sp, #(16 * 6)]
    ldp     x14, x15, [sp, #(16 * 7)]
    ldp     x16, x17, [sp, #(16 * 8)]
    ldp     x18, x29, [sp, #(16 * 9)]
    ldr     x30,      [sp, #(16 * 10)]
    add     sp, sp, #(16 * 11)
    eret

/*
 * Synchronous exceptions and anything unexpected: branch to the Adder
 * diagnostic (which prints a marker and halts in WFI). These never return.
 */
arm64_sync_handler:
    bl      arm64_sync_panic
1:  wfi
    b       1b

arm64_unhandled:
    bl      arm64_unhandled_panic
1:  wfi
    b       1b
