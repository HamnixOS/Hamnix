/*
 * arch/x86/kernel/irq_asm.S - per-IRQ entry stubs.
 *
 * Mirrors arch/x86/entry/entry_64.S's irq entry path. Sixteen stubs
 * (one per legacy 8259 IRQ line, vectors 0x20..0x2F after the PIC
 * remap done in i8259.py) all funnel into common_irq, which saves
 * the SysV caller-clobbered set, hands the vector number to Hamnix's
 * do_irq(), restores registers, and `iretq`s back to the interrupted
 * code.
 *
 * Distinct from common_trap (idt_asm.S):
 *   - IRQ stubs always push a fake error code (no IRQ has one).
 *   - common_irq RETURNS via iretq instead of halting.
 *   - No stack realignment trickery: at IRQ entry the CPU pushes a
 *     5-quad frame (ss/rsp/rflags/cs/rip) which keeps %rsp 16-byte
 *     aligned at the call site after we push the 9 caller-saved
 *     quads (5 + 2 stub pushes + 9 = 16 quads = 128 bytes).
 */

    .code64

/* KPTI: an IRQ can fire while CPL3 (CR3 = the user PML4). The CPU fetches
 * the per-vector stub bytes under WHATEVER CR3 was active, so every
 * irq_stub_N AND common_irq must live in .kpti.text (the only high-half
 * window the user PML4 maps). common_irq swaps CR3 to the kernel table on
 * entry and back to the user table on a CPL3 return. */
    .section .kpti.text, "ax"

/* ---------- per-IRQ stubs ---------------------------------------- */
    .macro IRQ_STUB n
    .align 16
    .globl irq_stub_\n
irq_stub_\n:
    pushq $0
    pushq $\n
    jmp   common_irq
    .endm

    /* Legacy IRQs 0..15 → vectors 32..47. Vectors 48..95 form the
     * "device IRQ band" used by IOAPIC-routed PCI INTx and MSI/MSI-X
     * handlers. virtio-net INTx lives at 0x40 (= 64); its per-queue
     * MSI-X vectors land at 0x49..0x4B. The band was 32..71; it now
     * runs 32..95 so multi-vector MSI-X devices have room. The stub
     * indices match vector numbers one-to-one so a Hamnix caller
     * doesn't have to add/subtract any base. */
    IRQ_STUB 32
    IRQ_STUB 33
    IRQ_STUB 34
    IRQ_STUB 35
    IRQ_STUB 36
    IRQ_STUB 37
    IRQ_STUB 38
    IRQ_STUB 39
    IRQ_STUB 40
    IRQ_STUB 41
    IRQ_STUB 42
    IRQ_STUB 43
    IRQ_STUB 44
    IRQ_STUB 45
    IRQ_STUB 46
    IRQ_STUB 47
    IRQ_STUB 48
    IRQ_STUB 49
    IRQ_STUB 50
    IRQ_STUB 51
    IRQ_STUB 52
    IRQ_STUB 53
    IRQ_STUB 54
    IRQ_STUB 55
    IRQ_STUB 56
    IRQ_STUB 57
    IRQ_STUB 58
    IRQ_STUB 59
    IRQ_STUB 60
    IRQ_STUB 61
    IRQ_STUB 62
    IRQ_STUB 63
    IRQ_STUB 64
    IRQ_STUB 65
    IRQ_STUB 66
    IRQ_STUB 67
    IRQ_STUB 68
    IRQ_STUB 69
    IRQ_STUB 70
    IRQ_STUB 71
    IRQ_STUB 72
    IRQ_STUB 73
    IRQ_STUB 74
    IRQ_STUB 75
    IRQ_STUB 76
    IRQ_STUB 77
    IRQ_STUB 78
    IRQ_STUB 79
    IRQ_STUB 80
    IRQ_STUB 81
    IRQ_STUB 82
    IRQ_STUB 83
    IRQ_STUB 84
    IRQ_STUB 85
    IRQ_STUB 86
    IRQ_STUB 87
    IRQ_STUB 88
    IRQ_STUB 89
    IRQ_STUB 90
    IRQ_STUB 91
    IRQ_STUB 92
    IRQ_STUB 93
    IRQ_STUB 94
    IRQ_STUB 95

/* ---------- IPI vector 240 (0xF0): TLB shootdown ---------------- *
 * A dedicated stub for the cross-CPU TLB-flush IPI.  Lives outside
 * the 32..95 legacy IRQ band to avoid colliding with any device
 * vector.  Funnel through common_irq so do_irq() dispatches to the
 * registered irq_handlers[240] handler (module_map_tlb_flush_ipi).
 */
    IRQ_STUB 240

/* ---------- IPI vector 242 (0xF2): RESCHEDULE ------------------- *
 * A dedicated stub for the cross-CPU reschedule IPI.  An idle AP HLTs
 * with interrupts enabled; smp_send_reschedule() targets it with this
 * vector so the AP falls out of HLT and re-scans the runqueue.  Same
 * prologue/epilogue/iretq shape as irq_stub_240 — funnels through
 * common_irq so do_irq() dispatches to irq_handlers[242] (resched_ipi)
 * and sends the single LAPIC EOI afterwards.  The handler body is
 * nearly empty: the wakeup (the IPI itself bumping the AP out of HLT)
 * IS the point.
 */
    IRQ_STUB 242

/* ---------- IPI vector 243 (0xF3): CPU STOP --------------------- *
 * A dedicated stub for the cross-CPU stop IPI.  The BSP broadcasts this
 * from the poweroff / reboot path (halt_other_cpus()) BEFORE the ACPI S5
 * / reset write so every other CPU parks permanently in `cli; hlt`.  Same
 * prologue/epilogue shape as the other IPI stubs — funnels through
 * common_irq so do_irq() dispatches to irq_handlers[243] (stop_ipi).  Note
 * that handler never returns: it bumps the ack counter then HLTs forever,
 * so the iretq/EOI tail of common_irq is never reached for this vector
 * (the AP is dead).  That's intentional: a stopped AP cannot spin and
 * overheat the board if S5 fails to cut power.
 */
    IRQ_STUB 243

/* ---------- common IRQ dispatch ---------------------------------- */
    .align 16
    .globl common_irq
common_irq:
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11

    /* KPTI: swap CR3 to the kernel table before do_irq touches kernel
     * data/code. If this IRQ nested on kernel context CR3 was already the
     * kernel table — reloading it is a harmless no-op. The 9 pushes above
     * landed on the kernel stack (TSS.RSP0, PML4[0]) when coming from
     * CPL3, so they were safe pre-swap. %rax/%rcx are saved, use as
     * scratch. cpu_id @ %gs:0. */
    movq  %gs:0, %rax
    leaq  kpti_kernel_cr3_slots(%rip), %rcx
    movq  (%rcx, %rax, 8), %rax
    movq  %rax, %cr3

    /* Stack layout right now (low -> high), 9 caller-saved quads
     * pushed above the stub's vec/ec and the CPU's iret frame:
     *    0..64  r11/r10/r9/r8/rdi/rsi/rdx/rcx/rax
     *    72     vector       (pushed by the per-IRQ stub)
     *    80     error_code   (fake 0, pushed by the stub)
     *    88     rip          (pushed by the CPU)
     *    96     cs           (pushed by the CPU)
     *   104     rflags
     *   112     rsp
     *   120     ss
     *
     * arg1 (%rdi) = vector; arg2 (%rsi) = the interrupted CS. The
     * preemption gate in timer_interrupt() inspects CS's low two
     * bits: RPL 3 means the timer hit ring-3 (userland) code, which
     * is the only context safe to preempt. Passing CS here keeps the
     * ring test in C-level Adder rather than smearing it across asm. */
    movq  72(%rsp), %rdi
    movq  96(%rsp), %rsi
    call  do_irq

    /* KPTI exit: if we are returning to CPL3 (saved CS RPL == 3 at
     * 96(%rsp)), swap CR3 to the USER table before the pops + iretq. The
     * pops read the kernel stack (PML4[0], mapped in the user table) and
     * the iretq frame is there too, so they resolve post-swap; the iretq
     * fetch is from .kpti.text. If returning to CPL0 (nested kernel IRQ),
     * leave the kernel table loaded. %rax/%rcx are restored by the pops
     * below, so clobbering them here is fine. */
    movq  96(%rsp), %rax              /* saved CS */
    andq  $3, %rax
    cmpq  $3, %rax
    jne   1f
    movq  %gs:0, %rax
    leaq  kpti_user_cr3_slots(%rip), %rcx
    movq  (%rcx, %rax, 8), %rax
    movq  %rax, %cr3
1:
    popq  %r11
    popq  %r10
    popq  %r9
    popq  %r8
    popq  %rdi
    popq  %rsi
    popq  %rdx
    popq  %rcx
    popq  %rax

    /* Drop the vector + dummy error code pushed by the stub. */
    addq  $16, %rsp

    iretq

    /* Back to plain .text/.rodata for the lookup table + IRQ-control
     * wrappers below; these run only in kernel context (kernel CR3). */
    .section .text, "ax"

/* ---------- irq_stub_table --------------------------------------- *
 * Sixty-four entries, one per IRQ vector (32..95). Consumed by
 * idt_init() via get_irq_stub() to populate IDT gates 32..95. Each
 * entry is the full 64-bit virtual address of the stub; the kernel
 * is a true elf64-x86-64 object so `.quad sym` (R_X86_64_64) works
 * directly — no more `.long sym; .long 0` split (the kernel is
 * linked in the higher half now, where the addresses genuinely need
 * 64 bits).
 */
    .section .rodata
    .align 8
    .globl irq_stub_table
irq_stub_table:
    .quad irq_stub_32
    .quad irq_stub_33
    .quad irq_stub_34
    .quad irq_stub_35
    .quad irq_stub_36
    .quad irq_stub_37
    .quad irq_stub_38
    .quad irq_stub_39
    .quad irq_stub_40
    .quad irq_stub_41
    .quad irq_stub_42
    .quad irq_stub_43
    .quad irq_stub_44
    .quad irq_stub_45
    .quad irq_stub_46
    .quad irq_stub_47
    .quad irq_stub_48
    .quad irq_stub_49
    .quad irq_stub_50
    .quad irq_stub_51
    .quad irq_stub_52
    .quad irq_stub_53
    .quad irq_stub_54
    .quad irq_stub_55
    .quad irq_stub_56
    .quad irq_stub_57
    .quad irq_stub_58
    .quad irq_stub_59
    .quad irq_stub_60
    .quad irq_stub_61
    .quad irq_stub_62
    .quad irq_stub_63
    .quad irq_stub_64
    .quad irq_stub_65
    .quad irq_stub_66
    .quad irq_stub_67
    .quad irq_stub_68
    .quad irq_stub_69
    .quad irq_stub_70
    .quad irq_stub_71
    .quad irq_stub_72
    .quad irq_stub_73
    .quad irq_stub_74
    .quad irq_stub_75
    .quad irq_stub_76
    .quad irq_stub_77
    .quad irq_stub_78
    .quad irq_stub_79
    .quad irq_stub_80
    .quad irq_stub_81
    .quad irq_stub_82
    .quad irq_stub_83
    .quad irq_stub_84
    .quad irq_stub_85
    .quad irq_stub_86
    .quad irq_stub_87
    .quad irq_stub_88
    .quad irq_stub_89
    .quad irq_stub_90
    .quad irq_stub_91
    .quad irq_stub_92
    .quad irq_stub_93
    .quad irq_stub_94
    .quad irq_stub_95

    .section .text, "ax"
    .align 16
    .globl get_irq_stub
get_irq_stub:
    /* %rdi = IRQ vector (32..95). Return irq_stub_table[vec-32]. */
    leaq irq_stub_table(%rip), %rax
    subq $32, %rdi
    movq (%rax, %rdi, 8), %rax
    ret

/* call_irq_handler removed: Adder now has a first-class function-
 * pointer type, so arch/x86/kernel/irq.ad's irq_handlers[] table is
 * typed Array[256, Fn[None]] and do_irq() invokes the handler
 * directly (`irq_handlers[vector]()`). The indirect-call trampoline
 * that used to live here is no longer needed.                       */

/* ---------- sti / cli wrappers ----------------------------------- *
 * Hamnix can express these via asm_volatile("sti") / asm_volatile("cli")
 * directly, but giving them function names keeps the call sites
 * readable and makes them grep-able when porting.
 */
    .align 16
    .globl local_irq_enable
local_irq_enable:
    sti
    ret

    .align 16
    .globl local_irq_disable
local_irq_disable:
    cli
    ret

/* ---------- local_irq_save / local_irq_restore ------------------ *
 * Nesting-safe IRQ masking. local_irq_save() snapshots RFLAGS (which
 * carries the IF bit) into %rax and then disables IRQs (cli).
 * local_irq_restore(flags) writes the saved RFLAGS back, so IF is
 * re-enabled ONLY if it was set when saved. This makes the guards
 * safe to nest: an inner save/restore pair invoked while IRQs are
 * already off will keep them off, never spuriously re-enabling. */
    .align 16
    .globl local_irq_save
local_irq_save:
    pushfq
    popq %rax
    cli
    ret

    .align 16
    .globl local_irq_restore
local_irq_restore:
    /* %rdi = saved RFLAGS */
    pushq %rdi
    popfq
    ret

/* ---------- spin_pause: pause + check, used by busy-wait loops --- *
 * `rep; nop` is the canonical x86 pause hint. */
    .align 16
    .globl cpu_relax
cpu_relax:
    pause
    ret

/* ---------- safe_halt: atomic sti;hlt (Linux native_safe_halt) --- *
 * Enable interrupts and HLT in one breath. The x86 architecture
 * guarantees that an interrupt cannot be serviced between `sti` and
 * the instruction that follows it (sti delays IF taking effect by one
 * instruction), so `sti; hlt` is race-free: any interrupt that was
 * pending — or that the wakeup path raised AFTER the caller's final
 * runqueue re-scan but BEFORE this call — fires precisely at the hlt,
 * waking the core immediately rather than wedging it.
 *
 * This is the idle CPU's wait primitive: the AP idle loop re-scans the
 * runqueue with IRQs OFF, finds no work, then calls safe_halt() to park
 * until the reschedule IPI (vector 0xF2) bumps it out of hlt. On return
 * IRQs are ENABLED (the iret from the IPI handler restores IF=1). */
    .align 16
    .globl safe_halt
safe_halt:
    sti
    hlt
    ret
