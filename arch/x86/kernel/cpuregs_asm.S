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

/* ---------- _ap_monitor(addr: uint64) --------------------------- *
 *
 * AP idle power fix: arm the MONITOR hardware on the cache line that
 * contains `addr`. After this the core "watches" that line; a later
 * MWAIT will wake when any CPU WRITES to it (or on certain other
 * events). Pairs with _ap_mwait below.
 *
 * MONITOR: EAX = linear address to watch, ECX = extensions (0),
 *          EDX = hints (0). No memory operand bytes are read; the
 *          address is taken from EAX (DS:EAX). Privileged-friendly:
 *          executes at CPL=0 with no interrupts required.
 *
 * SysV ABI: %rdi = address to monitor. No return, no GP clobbers
 * beyond the scratch %rax/%rcx/%rdx (all caller-saved).
 */
    .align 16
    .globl _ap_monitor
_ap_monitor:
    movq    %rdi, %rax                 /* watched linear address -> EAX */
    xorq    %rcx, %rcx                 /* ECX = 0 (no extensions) */
    xorq    %rdx, %rdx                 /* EDX = 0 (no hints) */
    monitor                            /* arm address-range monitor */
    ret

/* ---------- _ap_mwait(hints: uint64, ext: uint64) --------------- *
 *
 * AP idle power fix: enter the implementation-dependent optimized
 * (low-power) state armed by a preceding MONITOR. The core stays
 * there until the monitored line is written by another CPU, then
 * resumes right after MWAIT. Crucially this needs NO interrupt and
 * NO armed LAPIC — exactly why it is correct for the AP idle loop
 * whose LAPIC is software-disabled.
 *
 * MWAIT: EAX = hints (0 => C1/default state), ECX = extensions
 *        (bit 0 = treat masked interrupts as break events; we pass 0
 *        since APs run with IF effectively unused here and we always
 *        re-scan after waking anyway).
 *
 * SysV ABI: %rdi = hints, %rsi = ext. No return value.
 */
    .align 16
    .globl _ap_mwait
_ap_mwait:
    movq    %rdi, %rax                 /* hints -> EAX */
    movq    %rsi, %rcx                 /* extensions -> ECX */
    mwait                              /* enter optimized idle state */
    ret

/* ---------- _stac() / _clac() ------------------------------------ *
 *
 * SMAP (Supervisor Mode Access Prevention) discipline. When CR4.SMAP
 * is set, a CPL=0 access to a user (US=1) page #PFs unless AC=1 in
 * RFLAGS. STAC sets AC; CLAC clears it.
 *
 * The kernel-side uaccess primitives (mm/uaccess.ad::copy_to_user /
 * copy_from_user) walk the running task's PML4, translate the user
 * vaddr to a physical frame, then memcpy via the low-mem identity
 * window. Because that destination IS a user-allocated page with
 * US=1 in its PTE, a CPL=0 memcpy with SMAP enabled #PFs without
 * STAC. We bracket the memcpy with _stac() / _clac().
 *
 * Both are no-ops on CPUs that lack SMAP (CR4.SMAP=0 means AC is a
 * normal user-clearable flag; STAC/CLAC #UD on pre-Broadwell parts).
 * The boot-time setup_smep_smap() only enables CR4.SMAP when CPUID
 * reports SMAP support, so callers must be sure not to hit the asm
 * on older silicon. We gate them via the global cr4_smap_enabled
 * flag in init/main.ad — see uaccess.ad's _ua_stac / _ua_clac.
 *
 * SysV ABI: no args, no return, no clobbers.
 */
    .align 16
    .globl _stac
_stac:
    stac
    ret

    .align 16
    .globl _clac
_clac:
    clac
    ret
