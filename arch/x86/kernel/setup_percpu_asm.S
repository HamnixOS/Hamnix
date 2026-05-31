/*
 * arch/x86/kernel/setup_percpu_asm.S - low-level per-CPU helpers.
 *
 * Mirrors the inline-asm bits scattered through arch/x86/kernel/setup_percpu.c
 * and arch/x86/include/asm/percpu.h. Hamnix's asm_volatile is zero-operand,
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
 * around the Hamnix-side .data..percpu block. setup_per_cpu_areas()
 * reads these to memcpy() the master template into each CPU's area.
 *
 * Hamnix has no extern-variable syntax. We stash the linker symbol
 * VALUES as `.quad sym` words in .rodata (resolved at link time),
 * then expose accessor functions that load from there.
 *
 * HIGHER-HALF: the kernel is linked at 0xffffffff80000000+, so
 * __per_cpu_template_start / __per_cpu_template_end are 64-bit VMAs.
 * They are stored as `.quad sym` (R_X86_64_64) and loaded with movq.
 * get_per_cpu_load returns the template's higher-half VMA — every
 * caller (setup_per_cpu_areas) reads the bytes through that virtual
 * address, which is mapped by the kernel high-half PML4 entry. */
    .section .rodata
    .align 8
__per_cpu_template_start_word:
    .quad __per_cpu_template_start
__per_cpu_template_end_word:
    .quad __per_cpu_template_end

    .section .text, "ax"

    .align 16
    .globl get_per_cpu_load
get_per_cpu_load:
    leaq    __per_cpu_template_start_word(%rip), %rax
    movq    (%rax), %rax
    ret

    .align 16
    .globl get_per_cpu_size
get_per_cpu_size:
    leaq    __per_cpu_template_end_word(%rip), %rax
    movq    (%rax), %rax
    leaq    __per_cpu_template_start_word(%rip), %rcx
    subq    (%rcx), %rax
    ret

/* ---------- Linux-ABI current_task per-CPU offset ----------------
 * linux_current_task_offset() returns the byte OFFSET of the
 * `linux_current_task_pcpu` slot within the per-CPU area — i.e.
 * (&linux_current_task_pcpu - __per_cpu_template_start). The codegen
 * emits `linux_current_task_pcpu` as a .globl whose link-time VALUE is
 * its VMA inside the .data..percpu template, and the template's base is
 * __per_cpu_template_start, so the difference is exactly the per-CPU
 * displacement the CPU adds to GS_base.
 *
 * The L-series loader (linux_abi/loader.ad) resolves a stock module's
 * R_X86_64_32S relocation against the `current_task` symbol to THIS
 * offset, so `mov %gs:offset,%rax` lands on the slot we seeded with a
 * dummy task_struct pointer. */
    .section .rodata
    .align 8
__linux_current_task_pcpu_word:
    .quad linux_current_task_pcpu
__per_cpu_template_start_word2:
    .quad __per_cpu_template_start

    .section .text, "ax"

    .align 16
    .globl linux_current_task_offset
linux_current_task_offset:
    leaq    __linux_current_task_pcpu_word(%rip), %rax
    movq    (%rax), %rax
    leaq    __per_cpu_template_start_word2(%rip), %rcx
    subq    (%rcx), %rax
    ret
