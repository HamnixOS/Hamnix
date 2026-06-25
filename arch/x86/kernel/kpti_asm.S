/*
 * arch/x86/kernel/kpti_asm.S — KPTI (Meltdown mitigation) per-CPU CR3
 * bookkeeping + trampoline primitives.
 *
 * Everything declared here lives in the .kpti output section (kernel.lds)
 * so it is mapped in BOTH the full kernel PML4 and every per-task USER
 * PML4. The user PML4 maps ONLY .kpti's 2 MiB leaves in the high half;
 * the kernel image bulk + the KASLR module window are ABSENT. So the few
 * instructions that run under the user CR3 at entry — the CR3-swap-to-
 * kernel shim — and the few that run under it at exit — the CR3-swap-to-
 * user shim — MUST be fetched from .kpti.text, and the per-CPU CR3 slots
 * they read MUST live in .kpti.bss.
 *
 * Per-CPU slots are indexed by the logical CPU id (cpu_id_pcpu, pinned to
 * per-CPU byte offset 0 by the Adder codegen — read via %gs:0; Hamnix has
 * NO swapgs, kernel and entry path share the GS base). This mirrors how
 * per_cpu_tss[] is indexed in tss_asm.S.
 *
 *   kpti_kernel_cr3_slots[cpu] : the FULL kernel PML4 phys for the task
 *                                currently dispatched on `cpu`. schedule()
 *                                writes task_table[nxt].cr3 here. The
 *                                entry trampoline loads it into CR3.
 *   kpti_user_cr3_slots[cpu]   : the USER (isolated) PML4 phys for that
 *                                task. schedule() writes
 *                                task_table[nxt].user_cr3 here. The exit
 *                                trampoline loads it into CR3 when
 *                                returning to CPL3.
 *
 * When KPTI is disabled the Adder side stores the FULL cr3 into BOTH
 * slots, so the swaps are no-ops (load the same table) and the code path
 * stays exercised regardless.
 */

    .equ KPTI_NR_CPUS, 16
    .equ KPTI_STRIDE,  8

/* ---------- per-CPU CR3 slots + the IDT, all in .kpti.bss ---------- */
    .section .kpti.bss, "aw", @nobits
    .align 16
    .globl kpti_kernel_cr3_slots
kpti_kernel_cr3_slots:
    .skip KPTI_STRIDE * KPTI_NR_CPUS

    .align 16
    .globl kpti_user_cr3_slots
kpti_user_cr3_slots:
    .skip KPTI_STRIDE * KPTI_NR_CPUS

/* A tiny per-CPU scratch quad the entry shim can spill a register into
 * before it has a kernel stack guaranteed-mapped (the kernel stack IS in
 * PML4[0] low identity, mapped in both tables, but the scratch keeps the
 * shim self-contained and re-entrancy-obvious). */
    .align 16
    .globl kpti_scratch_slots
kpti_scratch_slots:
    .skip KPTI_STRIDE * KPTI_NR_CPUS

/* The IDT lives here (NOT in the Adder-codegen .bss) so the CPU can read
 * gate descriptors while CR3 = user PML4 at interrupt-vector time. 256
 * entries * 16 bytes = 4096 bytes. Accessed from idt.ad via the
 * kpti_idt_table_addr() accessor below. */
    .align 16
    .globl kpti_idt_table
kpti_idt_table:
    .skip 4096

/* ---------- kpti_enabled: runtime master switch ------------------- *
 * Lives in .kpti.data (NOT .kpti.bss) so it is mapped in BOTH the kernel
 * and every user PML4 AND carries a defined initial value of 0 (KPTI
 * OFF) from the image — the entry/exit trampolines read it under the
 * USER CR3, so it MUST be in the .kpti window. kpti_init() sets it to 1
 * only when KPTI_RUNTIME_ENABLE==1.
 *
 * WHY a runtime gate and not just "load the same CR3": Hamnix runs with
 * CR4.PGE=0 (no global pages) and no PCID, so EVERY `mov X,%cr3` is a
 * FULL TLB flush even when X equals the current CR3. With KPTI staged
 * OFF, an unconditional reload on every syscall/IRQ entry+exit flushes
 * the TLB 2-4x per kernel transition and crawls the boot (the heartbeat
 * never reaches steady idle). Gating on this flag makes the OFF path a
 * single predicted-not-taken branch — zero TLB cost, baseline speed. */
    .section .kpti.data, "aw"
    .align 8
    .globl kpti_enabled
kpti_enabled:
    .quad 0

    .section .text, "ax"
    .code64

/* ---------- kpti_set_enabled(v) ----------------------------------- *
 * Adder-side setter (kpti_init writes 1 when KPTI_RUNTIME_ENABLE==1).
 * SysV: %rdi = value. Runs with the kernel CR3, so plain .text is fine. */
    .align 16
    .globl kpti_set_enabled
kpti_set_enabled:
    leaq    kpti_enabled(%rip), %rax
    movq    %rdi, (%rax)
    ret

/* ---------- kpti_idt_table_addr() -> uint64 ----------------------- *
 * Return the high-half VMA of the .kpti-resident IDT buffer so idt.ad
 * can populate gates and lidt it. (These accessors themselves may live
 * in plain .text — they run with the kernel CR3.) */
    .align 16
    .globl kpti_idt_table_addr
kpti_idt_table_addr:
    leaq    kpti_idt_table(%rip), %rax
    ret

/* ---------- kpti linker-symbol accessors -------------------------- *
 * __kpti_start / __kpti_end are linker symbols (high-half VMAs). Stash
 * their values as .quad words and expose them so cpu_kpti.ad can walk
 * [__kpti_start, __kpti_end) by 2 MiB when building the user PML4. */
    .section .rodata
    .align 8
__kpti_start_word:
    .quad __kpti_start
__kpti_end_word:
    .quad __kpti_end

    .section .text, "ax"
    .align 16
    .globl kpti_section_start
kpti_section_start:
    leaq    __kpti_start_word(%rip), %rax
    movq    (%rax), %rax
    ret

    .align 16
    .globl kpti_section_end
kpti_section_end:
    leaq    __kpti_end_word(%rip), %rax
    movq    (%rax), %rax
    ret

/* ---------- per-CPU CR3 slot writers (called from schedule()) ----- *
 * kpti_set_cpu_cr3(cpu, kernel_cr3, user_cr3): store the dispatched
 * task's full + user CR3 into THIS CPU's slots so the entry/exit
 * trampolines can find them. SysV: %rdi=cpu, %rsi=kernel_cr3,
 * %rdx=user_cr3. */
    .align 16
    .globl kpti_set_cpu_cr3
kpti_set_cpu_cr3:
    movq    %rdi, %rcx
    cmpq    $KPTI_NR_CPUS, %rcx
    jb      1f
    xorq    %rcx, %rcx
1:  leaq    kpti_kernel_cr3_slots(%rip), %rax
    movq    %rsi, (%rax, %rcx, 8)
    leaq    kpti_user_cr3_slots(%rip), %rax
    movq    %rdx, (%rax, %rcx, 8)
    ret

/* ---------- entry/exit trampoline macros -------------------------- *
 * These are inlined by the entry stubs (.kpti.text in the stub files).
 * We expose them as a header the assembler includes? Adder build can't
 * #include across .S files easily, so the actual swap sequences are
 * written INLINE in syscall_64.S / irq_asm.S / trap_asm.S using the
 * symbols above. This file only provides the storage + accessors. */
