/*
 * arch/x86/kernel/fpu_asm.S - FPU / SSE / AVX extended-state save & restore.
 *
 * Hamnix historically swapped only the 6 callee-saved GPRs across a context
 * switch (sched_asm.S::__switch_to_asm) and NEVER preserved the x87 / SSE /
 * AVX register file. XCR0 was raised to 0x7 (x87|SSE|AVX) in start_first_task
 * purely to stop glibc's VEX-encoded AVX ops from #UD-ing — the vector file
 * was left un-saved. Consequence: any native float64 / SIMD computation
 * corrupts the instant the task is preempted and another task (or the kernel)
 * clobbers an xmm/ymm lane. The native `js` tool evaluating `2.0*3.0+1.0`
 * returned 1 instead of 7 for exactly this reason.
 *
 * These helpers give kernel/sched/core.ad the primitives it needs to XSAVE
 * the outgoing task's extended state and XRSTOR the incoming task's on every
 * switch (eager FPU, correctness-first — no lazy-#NM scheme). A FXSAVE /
 * FXRSTOR fallback covers pre-XSAVE silicon (legacy 512-byte area).
 *
 * ALIGNMENT CONTRACT (caller's responsibility):
 *   - XSAVE / XRSTOR require the memory operand be 64-byte aligned.
 *   - FXSAVE / FXRSTOR require 16-byte alignment.
 * core.ad over-allocates the per-task area and hands us a 64-byte-aligned
 * pointer, so both constraints are satisfied.
 *
 * ENABLE CONTRACT (caller's responsibility):
 *   - XSAVE/XRSTOR require CR4.OSXSAVE=1 and a configured XCR0.
 *   - FXSAVE/FXRSTOR require CR4.OSFXSR=1.
 * core.ad gates every call on g_fpu_ready, which fpu_init_bsp() only raises
 * AFTER it has armed those control bits, so we never execute a #UD/#GP-prone
 * instruction on an un-armed CPU.
 *
 * Convention mirrors cpuregs_asm.S — SysV ABI, no GP clobbers beyond the
 * scratch %rax/%rcx/%rdx the mask setup uses.
 */

    .code64
    .section .text, "ax"

/* ---------- fpu_xsave(area: Ptr[uint8], mask: uint64) ----------- *
 *
 * XSAVE the current extended state into `area`, restricted to the feature
 * components in `mask` (the requested-feature bitmap, ANDed with XCR0 by the
 * CPU). Callers pass mask = XCR0 value (0x7 = x87|SSE|AVX, or 0x3 without
 * AVX). XSAVE reads the bitmap from EDX:EAX.
 *
 * SysV ABI: %rdi = 64-byte-aligned area ptr, %rsi = feature mask.
 * Clobbers caller-saved %rax/%rdx only.
 */
    .align 16
    .globl fpu_xsave
fpu_xsave:
    movq    %rsi, %rax                 /* low 32 bits of RFBM -> EAX */
    movq    %rsi, %rdx
    shrq    $32, %rdx                  /* high 32 bits of RFBM -> EDX */
    xsave64 (%rdi)
    ret

/* ---------- fpu_xrstor(area: Ptr[uint8], mask: uint64) ---------- *
 *
 * XRSTOR the extended state from `area`, restricted to the components in
 * `mask`. For a freshly-initialised area (XSTATE_BV=0, but FCW=0x037F at
 * offset 0 and MXCSR=0x1F80 at offset 24) XRSTOR loads INIT state for every
 * component in the mask — clean x87 (CW 0x037F), zeroed XMM/YMM, and MXCSR
 * from memory (0x1F80, all SIMD exceptions masked). See core.ad's
 * fpu_task_init for how that clean area is built.
 *
 * SysV ABI: %rdi = 64-byte-aligned area ptr, %rsi = feature mask.
 * Clobbers caller-saved %rax/%rdx only.
 */
    .align 16
    .globl fpu_xrstor
fpu_xrstor:
    movq    %rsi, %rax                 /* low 32 bits of RFBM -> EAX */
    movq    %rsi, %rdx
    shrq    $32, %rdx                  /* high 32 bits of RFBM -> EDX */
    xrstor64 (%rdi)
    ret

/* ---------- fpu_fxsave(area: Ptr[uint8]) ------------------------ *
 *
 * Legacy fallback for CPUs without XSAVE: FXSAVE the x87 + SSE state into the
 * 512-byte legacy area. FXSAVE64 stores the full 64-bit FPU IP/DP form.
 *
 * SysV ABI: %rdi = 16-byte-aligned area ptr. No GP clobbers.
 */
    .align 16
    .globl fpu_fxsave
fpu_fxsave:
    fxsave64 (%rdi)
    ret

/* ---------- fpu_fxrstor(area: Ptr[uint8]) ----------------------- *
 *
 * Legacy fallback: FXRSTOR the x87 + SSE state from the 512-byte legacy area.
 *
 * SysV ABI: %rdi = 16-byte-aligned area ptr. No GP clobbers.
 */
    .align 16
    .globl fpu_fxrstor
fpu_fxrstor:
    fxrstor64 (%rdi)
    ret

/* ==================================================================
 * FPU context-switch torture-test primitives (kernel selftest only)
 * ==================================================================
 * These back kernel/sched/core.ad::fpu_ctxsw_torture_selftest, which spawns
 * two kthreads that each load a DISTINCT pattern across the whole xmm bank,
 * yield (forcing a real __switch_to_asm), and verify the pattern survived. If
 * per-task FPU save/restore is broken the sibling's load bleeds through and
 * the verify reports mismatches. Not used by production code paths.
 */

/* ---------- fpu_torture_store(seed: uint64) --------------------- *
 * Write seed, seed+1, ..., seed+15 into the low 64 bits of xmm0..xmm15.
 * SysV ABI: %rdi = seed. Clobbers %rax + the xmm bank (that's the point).
 */
    .align 16
    .globl fpu_torture_store
fpu_torture_store:
    movq    %rdi, %rax
    movq    %rax, %xmm0
    incq    %rax
    movq    %rax, %xmm1
    incq    %rax
    movq    %rax, %xmm2
    incq    %rax
    movq    %rax, %xmm3
    incq    %rax
    movq    %rax, %xmm4
    incq    %rax
    movq    %rax, %xmm5
    incq    %rax
    movq    %rax, %xmm6
    incq    %rax
    movq    %rax, %xmm7
    incq    %rax
    movq    %rax, %xmm8
    incq    %rax
    movq    %rax, %xmm9
    incq    %rax
    movq    %rax, %xmm10
    incq    %rax
    movq    %rax, %xmm11
    incq    %rax
    movq    %rax, %xmm12
    incq    %rax
    movq    %rax, %xmm13
    incq    %rax
    movq    %rax, %xmm14
    incq    %rax
    movq    %rax, %xmm15
    ret

/* ---------- fpu_torture_verify(seed: uint64) -> uint64 ---------- *
 * Compare the low 64 bits of xmm0..xmm15 against seed..seed+15 and return the
 * number of MISMATCHES (0 == the whole bank survived intact). SysV ABI:
 * %rdi = seed, result in %rax. Clobbers %rax/%rcx/%rdx.
 */
    .align 16
    .globl fpu_torture_verify
fpu_torture_verify:
    movq    %rdi, %rdx                 /* expected running value = seed */
    xorq    %rcx, %rcx                 /* mismatch counter */
    movq    %xmm0, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm1, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm2, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm3, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm4, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm5, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm6, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm7, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm8, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm9, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm10, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm11, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm12, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm13, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm14, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:  incq    %rdx
    movq    %xmm15, %rax
    cmpq    %rdx, %rax
    je      1f
    incq    %rcx
1:
    movq    %rcx, %rax
    ret
