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
    .section .text, "ax"

/* ---------- per-IRQ stubs ---------------------------------------- */
    .macro IRQ_STUB n
    .align 16
    .globl irq_stub_\n
irq_stub_\n:
    pushq $0
    pushq $\n
    jmp   common_irq
    .endm

    /* Legacy IRQs 0..15 → vectors 32..47. Vectors 48..71 form the
     * "device IRQ band" used by IOAPIC-routed PCI INTx and (future)
     * MSI/MSI-X handlers. virtio-net (M16.112) lives at vector 0x40
     * (= 64). The stub indices match vector numbers one-to-one so a
     * Hamnix caller doesn't have to add/subtract any base. */
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

    /* Vector is at %rsp + 72 (9 saved quads * 8 bytes). */
    movq  72(%rsp), %rdi
    call  do_irq

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

/* ---------- irq_stub_table --------------------------------------- *
 * Sixteen entries, one per legacy IRQ vector (32..47). Same .long+0
 * encoding as trap_stub_table to dodge elf32-i386's 64-bit reloc
 * limitation. Consumed by idt_init() via get_irq_stub() to populate
 * IDT gates 32..47.
 */
    .section .rodata
    .align 8
    .globl irq_stub_table
irq_stub_table:
    .long irq_stub_32; .long 0
    .long irq_stub_33; .long 0
    .long irq_stub_34; .long 0
    .long irq_stub_35; .long 0
    .long irq_stub_36; .long 0
    .long irq_stub_37; .long 0
    .long irq_stub_38; .long 0
    .long irq_stub_39; .long 0
    .long irq_stub_40; .long 0
    .long irq_stub_41; .long 0
    .long irq_stub_42; .long 0
    .long irq_stub_43; .long 0
    .long irq_stub_44; .long 0
    .long irq_stub_45; .long 0
    .long irq_stub_46; .long 0
    .long irq_stub_47; .long 0
    .long irq_stub_48; .long 0
    .long irq_stub_49; .long 0
    .long irq_stub_50; .long 0
    .long irq_stub_51; .long 0
    .long irq_stub_52; .long 0
    .long irq_stub_53; .long 0
    .long irq_stub_54; .long 0
    .long irq_stub_55; .long 0
    .long irq_stub_56; .long 0
    .long irq_stub_57; .long 0
    .long irq_stub_58; .long 0
    .long irq_stub_59; .long 0
    .long irq_stub_60; .long 0
    .long irq_stub_61; .long 0
    .long irq_stub_62; .long 0
    .long irq_stub_63; .long 0
    .long irq_stub_64; .long 0
    .long irq_stub_65; .long 0
    .long irq_stub_66; .long 0
    .long irq_stub_67; .long 0
    .long irq_stub_68; .long 0
    .long irq_stub_69; .long 0
    .long irq_stub_70; .long 0
    .long irq_stub_71; .long 0

    .section .text, "ax"
    .align 16
    .globl get_irq_stub
get_irq_stub:
    /* %rdi = IRQ vector (32..71). Return irq_stub_table[vec-32]. */
    leaq irq_stub_table(%rip), %rax
    subq $32, %rdi
    movq (%rax, %rdi, 8), %rax
    ret

/* call_irq_handler: indirect tail-call into a Hamnix-registered IRQ
 * handler function. Adder lacks first-class function pointers (see
 * TODO.md "First-class function pointers") so the irq_handlers[]
 * table stores raw uint64 addresses; this trampoline does the
 * `call *%rax` the language can't currently emit cleanly. The
 * handler takes no arguments and returns void.                      */
    .align 16
    .globl call_irq_handler
call_irq_handler:
    /* %rdi = handler function address. */
    movq  %rdi, %rax
    call  *%rax
    ret

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

/* ---------- spin_pause: pause + check, used by busy-wait loops --- *
 * `rep; nop` is the canonical x86 pause hint. */
    .align 16
    .globl cpu_relax
cpu_relax:
    pause
    ret
