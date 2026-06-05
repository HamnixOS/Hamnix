/*
 * arch/x86/kernel/cpuregs_asm.S - CPU register primitives.
 *
 * Two M16.156 Asus real-hw triple-fault fix primitives plus the CPUID
 * dispatcher they depend on:
 *
 *   cpuid_get(leaf, subleaf, out)  - single-shot CPUID. Used by
 *                                    start_first_task to read
 *                                    CPUID.01h:ECX bit 26 (XSAVE) so
 *                                    the CR4.OSXSAVE set is conditional.
 *   fninit_helper()                - reset the FPU to power-on defaults.
 *   write_cr4(value)               - companion to read_cr4 (smp_asm.S).
 *
 * Convention mirrors arch/x86/kernel/smp_asm.S::get_bsp_cr3 and
 * tss_asm.S::tss_get_rsp0 — SysV ABI, return via %rax where applicable.
 */

    .code64
    .section .text, "ax"

/* ---------- cpuid_get(leaf, subleaf, out) ----------------------- *
 *
 * M16.156: start_first_task reads CPUID.01h:ECX bit 26 (XSAVE) to
 * decide whether to set CR4.OSXSAVE. This is the CPUID dispatcher.
 *
 * SysV ABI:
 *   %edi = leaf     (uint32)
 *   %esi = subleaf  (uint32)
 *   %rdx = out_ptr  (Ptr[uint32], 4 dwords: eax, ebx, ecx, edx)
 *
 * %rbx is callee-saved in SysV; CPUID clobbers it, so we save +
 * restore around the instruction. %rdi/%rsi/%rcx/%rdx are all
 * caller-saved — free to use as scratch.
 *
 * Pure read, no side effects, callable from any CPL=0 context.
 */
    .align 16
    .globl cpuid_get
cpuid_get:
    pushq   %rbx                       /* %rbx is callee-saved */
    movq    %rdx, %r8                  /* save out_ptr (CPUID clobbers %rdx) */
    movl    %edi, %eax                 /* leaf -> %eax */
    movl    %esi, %ecx                 /* subleaf -> %ecx */
    cpuid
    movl    %eax,  0(%r8)              /* out[0] = eax */
    movl    %ebx,  4(%r8)              /* out[1] = ebx */
    movl    %ecx,  8(%r8)              /* out[2] = ecx */
    movl    %edx, 12(%r8)              /* out[3] = edx */
    popq    %rbx
    ret

/* ---------- fninit_helper() -------------------------------------- *
 *
 * M16.156 Asus real-hw fix #1 (FPU init).
 *
 * On real laptops the firmware may leave the FPU in an inconsistent
 * state (denormal exception unmasked, stale tag word, control-word
 * defaults that the Hamnix kernel did not pick). If the very first
 * user instruction at ring-3 entry touches the FPU or SSE state, that
 * inconsistency can manifest as a #MF / #XF / #UD that the SYSRETQ
 * window's microcode treats as part of the transition.
 *
 * `fninit` issues the non-waiting form (no #MF on a pending FPU error)
 * and reinitialises the FPU to its power-on defaults: tag word = all
 * empty, status word = 0, control word = 0x037F (all exceptions
 * masked, precision=64-bit, rounding=nearest). It does NOT alter the
 * x87 / SSE register file.
 *
 * No arguments, no return value, no clobbers (the FPU touch happens
 * in coprocessor state, GP regs untouched). Safe at any CPL=0.
 */
    .align 16
    .globl fninit_helper
fninit_helper:
    fninit
    ret

/* ---------- write_cr4(value: uint64) ----------------------------- *
 *
 * M16.156 Asus real-hw fix #2 (CR4.OSXSAVE).
 *
 * Companion to read_cr4. Loads %rdi straight into %cr4. Called only
 * from start_first_task after the CPUID.01h:ECX bit-26 check so the
 * caller is responsible for OR-ing the desired bit into the live CR4
 * before invoking us. We do NOT mask or validate — this is a thin
 * "store the qword to the control register" primitive.
 *
 * SysV ABI: %rdi = new CR4 value. No return. Clobbers %cr4 only.
 */
    .align 16
    .globl write_cr4
write_cr4:
    movq    %rdi, %cr4
    ret

/* ---------- read_cr2() -> uint64 --------------------------------- *
 *
 * Copy-on-write #PF support. On a page fault the CPU latches the
 * faulting linear address into CR2; the COW page-fault handler reads
 * it to learn which page to resolve. Pure read, no side effects.
 *
 * SysV ABI: no arguments, result in %rax.
 */
    .align 16
    .globl read_cr2
read_cr2:
    movq    %cr2, %rax
    ret

    .align 16
    .globl read_cr3
read_cr3:
    movq    %cr3, %rax
    ret

/* ---------- invlpg_one(va: uint64) ------------------------------- *
 *
 * Invalidate the TLB entry for a single page. After the COW handler
 * rewrites a PTE (in the parent at fork time, or in the faulting task
 * at copy time) the stale TLB entry for that page must be flushed or
 * the CPU keeps using the old (writable, or read-only) translation.
 * `invlpg` flushes exactly the one page containing the operand and is
 * far cheaper than a full CR3 reload.
 *
 * SysV ABI: %rdi = virtual address inside the page to flush. No
 * return value.
 */
    .align 16
    .globl invlpg_one
invlpg_one:
    invlpg  (%rdi)
    ret
