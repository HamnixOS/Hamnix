/*
 * arch/x86/kernel/smap_probe_asm.S - SMAP enforcement positive-test probe.
 *
 * smap_probe_load(uvaddr) performs a DIRECT supervisor (CPL=0) byte read
 * of `uvaddr` WITHOUT a preceding STAC. If CR4.SMAP=1 and `uvaddr` walks
 * to a US=1 (user) leaf, the CPU raises #PF (P=1, U=0, the SMAP signature)
 * on the `movb` below. The kernel #PF handler (do_page_fault) recognises
 * the fault RIP == &smap_probe_fault_rip, records the fault, and advances
 * the iret RIP to smap_probe_fixup so this routine returns cleanly.
 *
 * Returns:
 *   the byte read (zero-extended) if NO fault occurred (SMAP not enforcing
 *     on this leaf — a FAIL for the positive test), OR
 *   0xFFFFFFFFFFFFFFFF if the load faulted and the handler recovered us
 *     (SMAP enforcement is LIVE — a PASS).
 *
 * The handler distinguishes "faulted" from "byte happened to be 0xFF" via
 * the smap_probe_faulted global it sets, so the test reads that flag, not
 * the return value, for the verdict. The sentinel return is belt-and-
 * suspenders.
 *
 * SysV: %rdi = uvaddr.
 */

    .code64
    .section .text, "ax"

    .align 16
    .globl smap_probe_load
smap_probe_load:
    /* No STAC. Direct CPL=0 read of the user vaddr. */
    .globl smap_probe_fault_rip
smap_probe_fault_rip:
    movb    (%rdi), %al               /* <-- faults here under SMAP        */
    /* No fault: zero-extend the byte we read and return it. */
    movzbq  %al, %rax
    ret

    /* The #PF handler points the iret RIP here on a recovered SMAP fault. */
    .globl smap_probe_fixup
smap_probe_fixup:
    movq    $-1, %rax                 /* sentinel: "we faulted + recovered" */
    ret
