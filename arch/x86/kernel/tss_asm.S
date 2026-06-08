/*
 * arch/x86/kernel/tss_asm.S - 64-bit PER-CPU TSS + per-CPU GDT.
 *
 * The TSS in long mode is a 104-byte structure whose only real job is
 * to tell the CPU which kernel stack to load when an interrupt or
 * exception causes a CPL transition from user (3) to kernel (0), plus
 * the IST table for exceptions that need a known-good stack (#DF).
 *
 * LINUX MIRROR — WHY PER-CPU GDT (not a shared GDT with per-CPU TSS
 * descriptor slots):
 *   Linux gives every logical CPU its OWN GDT (cpu_gdt_table / the
 *   per-CPU `gdt_page`). Each CPU's GDT carries the TSS descriptor at
 *   the SAME selector index (GDT_ENTRY_TSS), but that descriptor points
 *   at THAT CPU's own per-CPU TSS. So `ltr <fixed selector>` on any CPU
 *   loads that CPU's private TSS, and there is NO cross-CPU write race:
 *   a CPU only ever touches its own GDT + its own TSS.
 *
 *   The alternative — one shared GDT whose single 0x28 TSS descriptor is
 *   rewritten right before each CPU's `ltr` — works only because `ltr`
 *   caches the TSS base into the hidden TR register, but it forces every
 *   CPU to mutate the one shared GDT slot during bring-up (a race the
 *   moment two APs come up concurrently, and a footgun for any later
 *   descriptor edit). Per-CPU GDT is both closer to Linux and race-free,
 *   so that is what we do here.
 *
 * The BSP keeps using the boot-time `gdt64` (in .boot.data) until
 * tss64_percpu_init(0, ...) installs its per-CPU GDT copy with TR.
 * After that the BSP, like every AP, runs on its own per-CPU GDT.
 *
 * TSS field offsets we touch:
 *   offset 4   RSP0   (uint64) — kernel stack for CPL 3 -> 0 transitions
 *   offset 36  IST1   (uint64) — #DF dedicated stack
 * Total size: 104 bytes (limit = 0x67).
 *
 * GDT TSS descriptor layout (16 bytes, two GDT slots in long mode):
 *   Low quad:
 *     bits 0..15  limit_lo  (0x0067 for 104-byte TSS)
 *     bits 16..39 base[23:0]
 *     bits 40..47 type/attr (0x89 = present | DPL=0 | 64-bit avail TSS)
 *     bits 48..63 limit_hi/flags(0) | base[31:24]
 *   High quad:
 *     bits 0..31  base[63:32]  (our TSS lives < 4 GiB so == 0)
 */

    .code64

/* ---------- Per-CPU storage --------------------------------------- *
 * NR_TSS_CPUS must be >= MAX_CPUS (arch/x86/kernel/smp.ad). 16 today.
 *
 *  - per_cpu_tss[i]   : the i-th CPU's 104-byte TSS, padded to 128 for
 *                       cache-line friendliness and easy index math.
 *  - per_cpu_gdt[i]   : the i-th CPU's private 7-entry (56-byte) GDT copy
 *                       (null/kcode/kdata/udata/ucode/tss-lo/tss-hi).
 *  - per_cpu_df_stk[i]: the i-th CPU's dedicated 4 KiB IST1 #DF stack, so
 *                       two CPUs taking a #DF concurrently don't corrupt a
 *                       single shared scratch stack. Top = base + 4096.
 *  - per_cpu_gdtr[i]  : a 10-byte lgdt operand (2-byte limit + 8-byte base)
 *                       for the i-th CPU's GDT.
 */
    .equ NR_TSS_CPUS, 16
    .equ TSS_STRIDE,  128
    .equ GDT_STRIDE,  64          /* 56 bytes rounded up to 64          */
    .equ GDT_LIMIT,   0x37        /* 7 entries * 8 - 1                  */
    .equ DF_STK_SIZE, 4096
    .equ GDTR_STRIDE, 16          /* 10 used, padded to 16              */

    .section .bss
    .align 16
    .globl per_cpu_tss
per_cpu_tss:
    .skip TSS_STRIDE * NR_TSS_CPUS

    .align 16
    .globl per_cpu_gdt
per_cpu_gdt:
    .skip GDT_STRIDE * NR_TSS_CPUS

    .align 16
    .globl per_cpu_df_stack
per_cpu_df_stack:
    .skip DF_STK_SIZE * NR_TSS_CPUS

    .align 16
    .globl per_cpu_gdtr
per_cpu_gdtr:
    .skip GDTR_STRIDE * NR_TSS_CPUS

    .section .text, "ax"

/* ---------- helper: %rdi = cpu_id -> %rax = &per_cpu_tss[cpu_id] --- */
    .align 16
tss_base_for:
    /* clamp cpu_id to [0, NR_TSS_CPUS) so a bogus id can't write OOB */
    movq    %rdi, %rcx
    cmpq    $NR_TSS_CPUS, %rcx
    jb      1f
    xorq    %rcx, %rcx
1:  imulq   $TSS_STRIDE, %rcx, %rax
    movabsq $per_cpu_tss, %r11
    addq    %r11, %rax
    ret

/* ---------- tss64_percpu_init(cpu_id, rsp0, ist1) -----------------
 * Build CPU `cpu_id`'s private GDT (copy of the boot gdt64 with a TSS
 * descriptor pointing at per_cpu_tss[cpu_id]), seed RSP0/IST1 in that
 * TSS, lgdt the per-CPU GDT and ltr selector 0x28.
 *
 *   %rdi = cpu_id   %rsi = rsp0   %rdx = ist1 (#DF stack top; 0 = leave)
 *
 * Replaces the old tss_init(rsp0): callers now pass their cpu id so the
 * BSP and each AP install their OWN GDT + TSS. The AP path calls this
 * after its %gs per-CPU area is live (so get_cpu_id() is valid).
 */
    .align 16
    .globl tss64_percpu_init
tss64_percpu_init:
    pushq   %rbx
    pushq   %r12
    pushq   %r13
    pushq   %r14
    pushq   %r15

    movq    %rdi, %r12              /* r12 = cpu_id (clamped below)      */
    cmpq    $NR_TSS_CPUS, %r12
    jb      1f
    xorq    %r12, %r12
1:
    movq    %rsi, %r13             /* r13 = rsp0                        */
    movq    %rdx, %r14             /* r14 = ist1                        */

    /* r15 = &per_cpu_tss[cpu_id] */
    imulq   $TSS_STRIDE, %r12, %r15
    movabsq $per_cpu_tss, %rax
    addq    %rax, %r15

    /* TSS.RSP0 = rsp0 */
    movq    %r13, 4(%r15)
    /* TSS.IST1 = ist1 (only if non-zero, so callers can leave it alone) */
    testq   %r14, %r14
    je      2f
    movq    %r14, 36(%r15)
2:

    /* rbx = &per_cpu_gdt[cpu_id] (this CPU's private GDT) */
    imulq   $GDT_STRIDE, %r12, %rbx
    movabsq $per_cpu_gdt, %rax
    addq    %rax, %rbx

    /* Copy the 7 boot GDT entries (56 bytes) into the per-CPU GDT.
     * gdt64 lives in the low .boot.data region; materialise its
     * absolute address with movabsq (R_X86_64_64). */
    movabsq $gdt64, %rsi
    movq    %rbx, %rdi
    movl    $7, %ecx
3:  movq    (%rsi), %rax
    movq    %rax, (%rdi)
    addq    $8, %rsi
    addq    $8, %rdi
    decl    %ecx
    jnz     3b

    /* Build the 16-byte TSS descriptor into per_cpu_gdt[cpu_id] at the
     * 0x28 selector slot (offsets 0x28 lo / 0x30 hi within the GDT). */
    movq    %r15, %r9              /* r9 = TSS base                     */
    movq    $0x67, %rax           /* limit_lo                          */
    movq    %r9, %r10
    andq    $0xFFFFFF, %r10
    shlq    $16, %r10
    orq     %r10, %rax            /* | base[23:0] << 16                */
    movq    $0x89, %r10
    shlq    $40, %r10
    orq     %r10, %rax            /* | type_attr (0x89) << 40          */
    movq    %r9, %r10
    shrq    $24, %r10
    andq    $0xFF, %r10
    shlq    $56, %r10
    orq     %r10, %rax            /* | base[31:24] << 56               */
    movq    %rax, 0x28(%rbx)      /* low quad of TSS descriptor         */
    movq    %r9, %rax
    shrq    $32, %rax
    movq    %rax, 0x30(%rbx)      /* high quad = base[63:32]            */

    /* Build the 10-byte lgdt operand into per_cpu_gdtr[cpu_id]. */
    imulq   $GDTR_STRIDE, %r12, %rcx
    movabsq $per_cpu_gdtr, %rax
    addq    %rax, %rcx            /* rcx = &per_cpu_gdtr[cpu_id]        */
    movw    $GDT_LIMIT, (%rcx)    /* 2-byte limit                      */
    movq    %rbx, 2(%rcx)        /* 8-byte base = &per_cpu_gdt[cpu_id] */

    /* Load this CPU's private GDT. The selectors keep the same numeric
     * values (0x08 kcode / 0x10 kdata / ...), so no segment reload is
     * needed: CS/DS/SS already hold those selectors and the descriptors
     * are byte-identical to the boot GDT. Only the 0x28 TSS slot differs,
     * and it isn't loaded into any segment register. */
    lgdt    (%rcx)

    /* Load TR with selector 0x28 -> caches THIS CPU's per_cpu_tss base. */
    movw    $0x28, %ax
    ltr     %ax

    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %rbx
    ret

/* ---------- tss_set_rsp0(rsp0) ---------------------------------- *
 * Update the RSP0 slot of the CALLING CPU's TSS in place. Called from
 * schedule() each time we context-switch to a new user task so that a
 * subsequent IRQ-from-user lands on THAT task's kernel stack. Indexes
 * per_cpu_tss[] by the calling CPU's logical id (read from %gs:0, the
 * cpu_id_pcpu slot, which the codegen pins to per-CPU offset 0).
 * The CPU re-reads TSS.RSP0 on the next CPL change
 * automatically; no TR reload needed.                              */
    .align 16
    .globl tss_set_rsp0
tss_set_rsp0:
    movq    %rdi, %rsi             /* rsi = rsp0                        */
    /* rdi = cpu_id. Read via %gs:0 — the codegen PINS cpu_id_pcpu to
     * per-CPU offset 0 (ABI invariant, see setup_percpu_asm.S header).
     * Matches read_cpu_id_percpu and the codegen's cpu_id_pcpu read. */
    movq    %gs:0, %rdi
    call    tss_base_for          /* rax = &per_cpu_tss[cpu_id]        */
    movq    %rsi, 4(%rax)
    ret

/* ---------- tss_get_rsp0() -> uint64 ----------------------------- *
 * Read-back of the calling CPU's installed RSP0 slot (diagnostic).  */
    .align 16
    .globl tss_get_rsp0
tss_get_rsp0:
    movq    %gs:0, %rdi            /* cpu_id @ pinned per-CPU offset 0   */
    call    tss_base_for
    movq    4(%rax), %rax
    ret

/* ---------- get_percpu_df_stack_top(cpu_id) -> uint64 ------------ *
 * Top (highest address) of CPU `cpu_id`'s dedicated IST1 #DF stack.
 * Used by the AP/BSP TSS bring-up to seed IST1 so two CPUs faulting
 * concurrently don't corrupt a single shared #DF scratch stack.     */
    .align 16
    .globl get_percpu_df_stack_top
get_percpu_df_stack_top:
    movq    %rdi, %rcx
    cmpq    $NR_TSS_CPUS, %rcx
    jb      1f
    xorq    %rcx, %rcx
1:  imulq   $DF_STK_SIZE, %rcx, %rax
    movabsq $per_cpu_df_stack, %r11
    addq    %r11, %rax
    addq    $DF_STK_SIZE, %rax     /* top = base + size                 */
    ret
