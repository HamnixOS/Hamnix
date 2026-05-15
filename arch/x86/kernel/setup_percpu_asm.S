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

/* ---------- Per-CPU template accessors --------------------------
 * The codegen emits `__per_cpu_template_start` / `__per_cpu_template_end`
 * around the Pynux-side .data..percpu block. setup_per_cpu_areas()
 * reads these to memcpy() the master template into each CPU's area.
 *
 * Pynux has no extern-variable syntax, and absolute references
 * (`movl sym, %eax`) blow up under elf32-i386 (BFD_RELOC_X86_64_32S).
 * Workaround: stash the values as plain `.long sym` words in .rodata
 * where the relocation resolves to a literal 32-bit address at link
 * time, then expose accessor functions that load from there. Both
 * target addresses fit in 32 bits (~0x10xxxx) and the difference is
 * at most a few hundred bytes for the foreseeable future.
 */
    .section .rodata
    .align 4
__per_cpu_template_start_word:
    .long __per_cpu_template_start
__per_cpu_template_end_word:
    .long __per_cpu_template_end

    .section .text, "ax"

    .align 16
    .globl get_per_cpu_load
get_per_cpu_load:
    leaq    __per_cpu_template_start_word(%rip), %rax
    movl    (%rax), %eax              /* zero-extends to %rax */
    ret

    .align 16
    .globl get_per_cpu_size
get_per_cpu_size:
    leaq    __per_cpu_template_end_word(%rip), %rax
    movl    (%rax), %eax
    leaq    __per_cpu_template_start_word(%rip), %rcx
    subl    (%rcx), %eax              /* uses zero-extended sub     */
    ret
