/*
 * arch/x86/kernel/idt_asm.S - low-level trap entry stubs.
 *
 * Mirrors arch/x86/entry/entry_64.S's per-vector entry stubs in Linux.
 * 32 trap stubs (one per CPU exception vector) all funnel into
 * common_trap, which saves the caller-saved register set, hands the
 * vector number to the Pynux `do_trap()`, and halts.
 *
 * Asymmetry between vectors:
 *   - The CPU pushes an error code only for certain vectors (8, 10,
 *     11, 12, 13, 14, 17, 21, 29, 30 on modern x86_64). The remaining
 *     vectors push nothing. To keep common_trap's stack layout
 *     uniform, every "no error code" stub pushes a fake zero so that
 *     the saved frame always looks like:
 *         [ ec ][ vec ][ rip ][ cs ][ rflags ][ rsp ][ ss ]
 *     from high to low after the per-vector stub runs.
 *
 * Symbol export: `trap_stub_table` is a 32-quad array of trap stub
 * addresses, consumed by `idt_init()` in arch/x86/kernel/idt.py to
 * populate IDT gate offsets. Keeping the dispatch table in asm avoids
 * a chain of leaq's in Pynux and gives us a single place to add
 * vectors later.
 */

    .code64
    .section .text, "ax"

/* ---------- per-vector stubs ------------------------------------- */
    .macro TRAP_STUB_NO_EC n
    .align 16
    .globl trap_stub_\n
trap_stub_\n:
    pushq $0
    pushq $\n
    jmp   common_trap
    .endm

    .macro TRAP_STUB_HAS_EC n
    .align 16
    .globl trap_stub_\n
trap_stub_\n:
    /* CPU has already pushed an error code at this point. */
    pushq $\n
    jmp   common_trap
    .endm

    /* Vectors that do NOT push an error code: 0,1,2,3,4,5,6,7,9,
     * 15,16,18,19,20,22..28,31. */
    TRAP_STUB_NO_EC  0
    TRAP_STUB_NO_EC  1
    TRAP_STUB_NO_EC  2
    TRAP_STUB_NO_EC  3
    TRAP_STUB_NO_EC  4
    TRAP_STUB_NO_EC  5
    TRAP_STUB_NO_EC  6
    TRAP_STUB_NO_EC  7
    TRAP_STUB_HAS_EC 8           /* #DF  double fault */
    TRAP_STUB_NO_EC  9
    TRAP_STUB_HAS_EC 10          /* #TS  invalid TSS */
    TRAP_STUB_HAS_EC 11          /* #NP  segment not present */
    TRAP_STUB_HAS_EC 12          /* #SS  stack-segment fault */
    TRAP_STUB_HAS_EC 13          /* #GP  general protection */
    TRAP_STUB_HAS_EC 14          /* #PF  page fault */
    TRAP_STUB_NO_EC  15
    TRAP_STUB_NO_EC  16
    TRAP_STUB_HAS_EC 17          /* #AC  alignment check */
    TRAP_STUB_NO_EC  18
    TRAP_STUB_NO_EC  19
    TRAP_STUB_NO_EC  20
    TRAP_STUB_HAS_EC 21          /* #CP  control protection */
    TRAP_STUB_NO_EC  22
    TRAP_STUB_NO_EC  23
    TRAP_STUB_NO_EC  24
    TRAP_STUB_NO_EC  25
    TRAP_STUB_NO_EC  26
    TRAP_STUB_NO_EC  27
    TRAP_STUB_NO_EC  28
    TRAP_STUB_HAS_EC 29          /* #VC  VMM communication */
    TRAP_STUB_HAS_EC 30          /* #SX  security exception */
    TRAP_STUB_NO_EC  31

/* ---------- common dispatch -------------------------------------- *
 * On entry the stack contains, from high to low addresses:
 *   ss, rsp, rflags, cs, rip, error_code, vector
 * %rsp points at `vector`. We save the SysV caller-saved set, load
 * the vector into %rdi (1st arg), and call into Pynux. We never
 * return — Pynux's do_trap halts.
 */
    .align 16
    .globl common_trap
common_trap:
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11

    /* %rsp + 72 == saved `vector` slot (9 quads of registers above). */
    movq  72(%rsp), %rdi
    /* %rsp + 80 == saved error code slot. */
    movq  80(%rsp), %rsi

    /* Align stack to 16 before the call (we pushed 9 quads + the
     * interrupt frame already had vector+ec). Easier: just align
     * %rsp to 16 by masking. We don't return so we can clobber it. */
    andq  $-16, %rsp

    call  do_trap

    /* do_trap is __noreturn but be paranoid. */
    cli
1:  hlt
    jmp 1b

/* ---------- trap_stub_table -------------------------------------- *
 * Array of 32 quad pointers, one per vector. Consumed by idt_init().
 * Note that each entry is the FULL 64-bit virtual address of the
 * stub — but in our elf32-i386 wrapper they're really 32-bit-zero-
 * extended (we live below 4 GiB), and storing them as .quad keeps
 * the format compatible if/when we grow into the higher half.
 */
    .section .rodata
    .align 8
    .globl trap_stub_table
    /* Each slot is 8 bytes: low 32 = stub address, high 32 = 0.
     * `.quad sym` would create a 64-bit relocation that elf32-i386
     * can't represent, so we split into `.long sym; .long 0`. All
     * stub addresses live below 4 GiB (we load at 1 MiB), so the
     * high half is genuinely zero — get_trap_stub reads the whole
     * 8-byte slot via `movq` and yields the correct 64-bit value. */
trap_stub_table:
    .long trap_stub_0;  .long 0
    .long trap_stub_1;  .long 0
    .long trap_stub_2;  .long 0
    .long trap_stub_3;  .long 0
    .long trap_stub_4;  .long 0
    .long trap_stub_5;  .long 0
    .long trap_stub_6;  .long 0
    .long trap_stub_7;  .long 0
    .long trap_stub_8;  .long 0
    .long trap_stub_9;  .long 0
    .long trap_stub_10; .long 0
    .long trap_stub_11; .long 0
    .long trap_stub_12; .long 0
    .long trap_stub_13; .long 0
    .long trap_stub_14; .long 0
    .long trap_stub_15; .long 0
    .long trap_stub_16; .long 0
    .long trap_stub_17; .long 0
    .long trap_stub_18; .long 0
    .long trap_stub_19; .long 0
    .long trap_stub_20; .long 0
    .long trap_stub_21; .long 0
    .long trap_stub_22; .long 0
    .long trap_stub_23; .long 0
    .long trap_stub_24; .long 0
    .long trap_stub_25; .long 0
    .long trap_stub_26; .long 0
    .long trap_stub_27; .long 0
    .long trap_stub_28; .long 0
    .long trap_stub_29; .long 0
    .long trap_stub_30; .long 0
    .long trap_stub_31; .long 0

/* ---------- idt_load: build descriptor on stack, lidt ------------ *
 * Pynux's asm_volatile() is zero-operand, so byte-packing the 10-byte
 * lidt operand from Pynux would be awkward. We take just the base
 * address in %rdi (SysV first arg) and build the full descriptor in
 * a stack-allocated 16-byte slot here, then `lidt` from it. Limit is
 * a fixed constant: 256 gates × 16 bytes − 1 = 4095.
 */
    .section .text, "ax"
    .align 16
    .globl idt_load
idt_load:
    /* Build a 10-byte LIDT operand in a 16-byte stack slot:
     *   bytes 0..1 = limit (4095)
     *   bytes 2..9 = base (%rdi).
     * Use red zone? No — invalid in kernel context (and we may
     * trap before iret restores things). Carve real stack space.   */
    subq    $16, %rsp
    movw    $4095, (%rsp)
    movq    %rdi, 2(%rsp)
    lidt    (%rsp)
    addq    $16, %rsp
    ret

/* get_trap_stub: return trap_stub_table[vector] for vector in %rdi.
 * Used by Pynux's idt_init() to populate gate offsets without needing
 * to express asm-symbol-address arithmetic at the language level. */
    .align 16
    .globl get_trap_stub
get_trap_stub:
    leaq trap_stub_table(%rip), %rax
    movq (%rax, %rdi, 8), %rax
    ret

/* trigger_int3: provoke vector 3 from Pynux. Single byte 0xCC.
 * A Pynux-side smoke test calls this after idt_init() to confirm
 * the handler chain works end-to-end. */
    .align 16
    .globl trigger_int3
trigger_int3:
    int3
    ret
