/*
 * arch/x86/kernel/tss_asm.S - 64-bit TSS storage + TR programming.
 *
 * The TSS in long mode is a 104-byte structure whose only real job is
 * to tell the CPU which kernel stack to load when an interrupt or
 * exception causes a CPL transition from user (3) to kernel (0). We
 * fill in TSS.RSP0 at boot, build a 16-byte TSS descriptor in the
 * GDT slot reserved by arch/x86/boot/header.S (at offset 0x28), and
 * load TR with selector 0x28. After that, a timer IRQ that fires
 * while CPL=3 will land on RSP0 instead of triple-faulting.
 *
 * TSS field offsets we touch:
 *
 *   offset 0   reserved      (uint32)
 *   offset 4   RSP0          (uint64, NOT 8-byte aligned by spec; x86
 *                              tolerates the unaligned 64-bit access)
 *   offset 12  RSP1          (unused — we have no CPL 1/2)
 *   offset 20  RSP2          (unused)
 *   offset 28..             IST1..IST7, reserved, IO map base
 *
 * Total size: 104 bytes (limit = 0x67). Linux uses larger TSS to hold
 * an IO permission bitmap; we don't issue user-mode IO and skip it.
 *
 * GDT TSS descriptor layout (16 bytes, two GDT slots in long mode):
 *
 *   Low quad:
 *     bits 0..15  limit_lo            (0x0067 for 104-byte TSS)
 *     bits 16..39 base[23:0]          (low 24 bits of TSS address)
 *     bits 40..47 type/attr (0x89)    (present | DPL=0 |
 *                                       type = 64-bit available TSS)
 *     bits 48..55 limit_hi (4 bits) + AVL + 0 + 0 + G (we leave all 0)
 *     bits 56..63 base[31:24]
 *
 *   High quad:
 *     bits 0..31  base[63:32]         (our TSS lives < 4 GiB so == 0)
 *     bits 32..63 reserved
 *
 * tss_init(rsp0) is a single asm helper that performs all three
 * runtime steps (set RSP0, build descriptor, ltr) so Hamnix callers
 * don't have to express the bit-packing themselves.
 */

    .code64
    .section .bss
    .align 8
    .globl tss64
tss64:
    .skip 104                          /* zero-init at .bss load     */

    .section .text, "ax"

    .align 16
    .globl tss_init
tss_init:
    /* %rdi = RSP0 value to install. Caller's responsibility that this
     * is a valid kernel stack with enough headroom — the IRQ entry
     * path pushes 5 quads (iret frame) + stub vec/ec + caller-saved
     * regs, so ~256 bytes minimum.                                  */
    leaq    tss64(%rip), %r8           /* %r8 = base of TSS         */
    movq    %rdi, 4(%r8)               /* tss64.rsp0 = rsp0          */

    /* Build descriptor low quad in %rax. */
    movq    %r8, %r9                   /* %r9 = base                 */
    movq    $0x67, %rax                /* limit_lo                   */

    movq    %r9, %r10
    andq    $0xFFFFFF, %r10
    shlq    $16, %r10
    orq     %r10, %rax                 /* | base[23:0] << 16         */

    movq    $0x89, %r10
    shlq    $40, %r10
    orq     %r10, %rax                 /* | type_attr (0x89) << 40   */

    movq    %r9, %r10
    shrq    $24, %r10
    andq    $0xFF, %r10
    shlq    $56, %r10
    orq     %r10, %rax                 /* | base[31:24] << 56        */

    /* Store low quad at gdt64 + 0x28. */
    leaq    gdt64(%rip), %r8
    movq    %rax, 0x28(%r8)

    /* High quad = base[63:32] (zero for our < 4 GiB TSS). */
    movq    %r9, %rax
    shrq    $32, %rax
    movq    %rax, 0x30(%r8)

    /* Load TR with selector 0x28. */
    movw    $0x28, %ax
    ltr     %ax
    ret

/* ---------- tss_set_rsp0(rsp0) ---------------------------------- *
 * Update the RSP0 slot of the already-installed TSS in place. Called
 * from schedule() each time we context-switch to a new user task so
 * that a subsequent IRQ-from-user lands on THAT task's kernel stack
 * rather than the previous task's. The CPU re-reads TSS.RSP0 on the
 * next CPL change automatically; no TR reload needed.            */
    .align 16
    .globl tss_set_rsp0
tss_set_rsp0:
    leaq    tss64(%rip), %rax
    movq    %rdi, 4(%rax)
    ret

/* ---------- tss_get_rsp0() -> uint64 ----------------------------- *
 * M16.153: read-back of the currently-installed RSP0 slot. Used by
 * the start_first_task() ring-3-transition diagnostic block to prove
 * the value the CPU will load on the next CPL=3 -> 0 transition (a
 * stale RSP0 here is a classic "user syscall lands on garbage kstack
 * -> triple-fault" cause on real silicon).                          */
    .align 16
    .globl tss_get_rsp0
tss_get_rsp0:
    leaq    tss64(%rip), %rax
    movq    4(%rax), %rax
    ret
