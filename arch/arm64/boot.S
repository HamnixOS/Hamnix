/*
 * arch/arm64/boot.S — Phase 2 bare-metal aarch64 boot stub.
 *
 * QEMU's `virt` machine, when given `-kernel <image>`, loads the image at
 * physical 0x4008_0000 and jumps to its entry point (the first byte of the
 * loaded image) on the primary CPU with the MMU OFF, caches off, and one
 * of EL1/EL2/EL3 selected by the model (cortex-a72 under -M virt enters at
 * EL1 with no EL3 firmware). This stub is the reset entry: it parks any
 * secondary CPUs, installs a stack, and branches to the Adder `kmain`.
 *
 * It deliberately does the MINIMUM: no MMU, no page tables, no GIC, no
 * exception vectors. kmain runs on the identity-mapped physical address
 * space with the stack we set up here and talks to the PL011 UART via MMIO.
 * Porting the real kernel's MMU/vectors/scheduler is a later phase.
 *
 * The linker script (arch/arm64/kernel.lds) places this file's `.boot.text`
 * section first so `_start` lands at the image load/entry address.
 */

    .section .boot.text, "ax"
    .globl _start
    .type _start, %function
_start:
    /*
     * Secondary-CPU park: QEMU virt may release more than one CPU. Read the
     * affinity field of MPIDR_EL1; anything other than CPU 0 spins in a
     * low-power wait loop so only the primary CPU runs kmain.
     */
    mrs     x0, mpidr_el1
    and     x0, x0, #0xff
    cbnz    x0, park_secondary

    /*
     * Install the boot stack. SP must be 16-byte aligned on aarch64. The
     * stack grows down from __stack_top (reserved in the linker script).
     */
    ldr     x0, =__stack_top
    mov     sp, x0

    /* Hand off to the Adder kernel entry. */
    bl      kmain

    /*
     * kmain is expected to halt and never return; if it ever does, fall
     * through into the same low-power halt loop as the secondary CPUs.
     */
halt:
    wfi
    b       halt

park_secondary:
    wfi
    b       park_secondary
    .size _start, .-_start
