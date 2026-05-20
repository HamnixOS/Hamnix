/*
 * arch/x86/kernel/cpuregs_asm.S - read-only CPU register accessors.
 *
 * M16.154 ring-3 transition diagnostic. start_first_task() needs to
 * print the live values of CR4, TR, LDTR, the four data-segment
 * selectors (DS/ES/FS/GS), and the GDTR base+limit so the next real-
 * hw test can hand-decode them and answer "why does iretq triple-fault
 * on Asus silicon but not under QEMU TCG". All eight helpers are
 * read-only: they do NOT change any register state, they only export
 * what the CPU already holds.
 *
 * M16.155-cpuid extends this with cpuid_get(leaf, subleaf, out): a
 * single-shot CPUID dispatcher used by start_first_task's diag block
 * to surface vendor / family / model / brand / extended-feature flags
 * (esp. CPUID.80000001h:EDX.Page1GB / bit 26) so the 1 GiB-huge-pages
 * hypothesis is decidable in one serial capture.
 *
 * Convention mirrors arch/x86/kernel/smp_asm.S::get_bsp_cr3 and
 * tss_asm.S::tss_get_rsp0 — single instruction, return via %rax,
 * SysV ABI (no clobbers beyond %rax + %rdx for the sgdt buffer
 * pointer). Each helper is callable as `extern def NAME() -> uint64`
 * from Adder.
 *
 * Why sgdt needs a scratch buffer: sgdt writes a 10-byte structure
 * (16-bit limit | 64-bit base) to memory, not to a register. We
 * keep a single 16-byte zero-initialised slot in .bss and re-use it
 * across both read_gdtr_base + read_gdtr_limit. Caller MUST treat
 * those two as "snapshot together if they need to be consistent" —
 * but for the diagnostic block we only call them once at boot, so
 * the read-back is naturally atomic.
 */

    .code64
    .section .bss
    .align 16
sgdt_scratch:
    .skip 16                            /* 10 bytes used (limit | base) */

    .section .text, "ax"

/* read_cr4 lives in arch/x86/kernel/smp_asm.S (added by M16.154-pgtable). */

/* ---------- read_tr() -> uint64 --------------------------------- *
 * `str` stores TR (16-bit selector) into r/m16. We zero %rax first
 * so the upper 48 bits are clean.                                  */
    .align 16
    .globl read_tr
read_tr:
    xorq    %rax, %rax
    str     %ax
    ret

/* ---------- read_ldtr() -> uint64 ------------------------------- *
 * `sldt` stores LDTR (16-bit selector). On a system that's never
 * loaded an LDT, this should be 0 (null LDT). A non-zero value is
 * SUSPICIOUS for a ring-3 transition — segment loads consult LDT
 * when the TI bit of the selector is set.                          */
    .align 16
    .globl read_ldtr
read_ldtr:
    xorq    %rax, %rax
    sldt    %ax
    ret

/* ---------- read_ds / read_es / read_fs / read_gs --------------- *
 * Each of these copies the corresponding segment-register's
 * 16-bit selector into %ax with the upper 48 bits zeroed. On a
 * CPL=0 path right before iretq-to-ring-3 we expect:
 *   DS = ES = 0x10 (kernel data, RPL=0) — these get overwritten
 *                                          by iretq to 0 on transition.
 *   FS = GS = 0x00 (null) — typically.
 * Any other value (e.g. 0xFFFF, or a non-existent selector) means a
 * previous code path corrupted them.                                */
    .align 16
    .globl read_ds
read_ds:
    xorq    %rax, %rax
    movw    %ds, %ax
    ret

    .align 16
    .globl read_es
read_es:
    xorq    %rax, %rax
    movw    %es, %ax
    ret

    .align 16
    .globl read_fs
read_fs:
    xorq    %rax, %rax
    movw    %fs, %ax
    ret

    .align 16
    .globl read_gs
read_gs:
    xorq    %rax, %rax
    movw    %gs, %ax
    ret

/* ---------- read_gdtr_base() -> uint64 -------------------------- *
 * sgdt writes [limit (2 bytes) | base (8 bytes)] to memory. We
 * stash to sgdt_scratch and then load the 64-bit base from offset 2.
 * The base tells us WHICH GDT the CPU is actually using — important
 * because the UEFI path swaps to a stub-built GDT and then back to
 * gdt64 (M16.125 — that's where the original tss_init #GP came from).
 *
 * read_gdtr_base + read_gdtr_limit MUST be called as a pair on the
 * same code path so they reflect the same `sgdt` snapshot.          */
    .align 16
    .globl read_gdtr_base
read_gdtr_base:
    leaq    sgdt_scratch(%rip), %rdx
    sgdt    (%rdx)
    movq    2(%rdx), %rax              /* base at offset +2 (after limit) */
    ret

/* ---------- read_gdtr_limit() -> uint64 ------------------------- */
    .align 16
    .globl read_gdtr_limit
read_gdtr_limit:
    leaq    sgdt_scratch(%rip), %rdx
    sgdt    (%rdx)
    xorq    %rax, %rax
    movw    (%rdx), %ax                /* limit at offset +0 (low 16 bits) */
    ret

/* ---------- cpuid_get(leaf, subleaf, out) ----------------------- *
 *
 * M16.155-cpuid: Asus ring-3-transition triple-fault hypothesis #N+1.
 * Both UD2 and HLT probes confirm user-RIP[0] is overwritten but
 * NEITHER fires its expected exception — the CPU triple-faults silently
 * before executing the first user instruction. The leading hypothesis
 * is that this Core-2-era pre-Penryn silicon does NOT support 1 GiB
 * huge pages (CPUID.80000001h:EDX bit 26 = Page1GB), and our PDPT
 * entries with PS=1 cause a reserved-bit-violation #PF that cascades
 * to triple-fault. Surface CPUID directly in the ring3-diag block so
 * the next real-hw test can hand-decode bit 26 in one look.
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
