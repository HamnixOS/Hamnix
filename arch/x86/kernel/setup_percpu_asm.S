/*
 * arch/x86/kernel/setup_percpu_asm.S - low-level per-CPU helpers.
 *
 * Mirrors the inline-asm bits scattered through arch/x86/kernel/setup_percpu.c
 * and arch/x86/include/asm/percpu.h. Pynux's asm_volatile is zero-operand,
 * so anything that needs register-bound operands lives here as plain
 * SysV-AMD64 function calls.
 *
 * What we provide:
 *   wrmsr_gsbase(value)  - write IA32_GS_BASE (MSR 0xC0000101). This is
 *                          the canonical way to anchor per-CPU storage:
 *                          subsequent accesses `mov %gs:offset, ...`
 *                          will displace from this address. Loading via
 *                          MSR (not swapgs) is correct for kernel-mode
 *                          per-CPU; IA32_KERNEL_GS_BASE is for the
 *                          swapgs-on-syscall path we don't have yet.
 *
 *   read_cpu_id_percpu() - read the 8 bytes at %gs:0. The convention
 *                          (set up in setup_per_cpu_areas) is that
 *                          offset 0 of every per-CPU area stores the
 *                          logical CPU id (so smp_processor_id()
 *                          becomes a one-instruction load).
 */

    .code64
    .section .text, "ax"

    .align 16
    .globl wrmsr_gsbase
wrmsr_gsbase:
    /* %rdi = value to install in IA32_GS_BASE.
     * wrmsr takes %ecx = MSR index, edx:eax = value (high:low). */
    movl    $0xC0000101, %ecx
    movq    %rdi, %rax
    movq    %rdi, %rdx
    shrq    $32, %rdx
    wrmsr
    ret

    .align 16
    .globl read_cpu_id_percpu
read_cpu_id_percpu:
    movq    %gs:0, %rax
    ret
