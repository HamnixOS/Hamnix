/*
 * arch/x86/kernel/syscall_64.S - SYSCALL entry path + user-mode glue.
 *
 * Mirrors the role of arch/x86/entry/entry_64.S's `entry_SYSCALL_64`
 * at the smallest meaningful scale: a hand-off stub that
 *
 *   1. saves the user's RIP (came in via %rcx) and RFLAGS (via %r11),
 *   2. switches RSP from user_rsp to kernel_rsp,
 *   3. shuffles the syscall-ABI registers into SysV positions and
 *      calls a Hamnix `do_syscall(nr, a0, a1, a2)`,
 *   4. restores everything and sysretq's back to user.
 *
 * Plus a few helpers Hamnix needs that touch privileged MSRs / segment
 * selectors / iretq, neither expressible in pure Hamnix today:
 *
 *   write_msr / read_msr   - generic MSR access
 *   set_efer_sce            - flip IA32_EFER.SCE so SYSCALL works at all
 *   enter_user_mode         - iretq into ring-3 with a fabricated frame
 *   user_demo_entry         - tiny ring-3 program that exercises the
 *                              syscall path so the smoke test has
 *                              something to observe
 *
 * Single-CPU only. The user_rsp_save / kernel_rsp slots live in
 * regular .data globals (declared in arch/x86/kernel/syscall.py),
 * which is fine without SMP. When we go SMP these become Percpu[T]
 * and the stub does swapgs to reach them.
 */

    .code64

/* syscall_entry must be FETCHED under the user CR3 (on SYSCALL entry CR3
 * is still the user PML4), so it lives in .kpti.text — the only high-half
 * window the user PML4 maps. The CR3 swap to the kernel table is the
 * first real action; after it the rest of the body runs fully-mapped. */
    .section .kpti.text, "ax"

/* ---------- syscall_entry: the SYSCALL handoff ------------------- */

    .align 16
    .globl syscall_entry
syscall_entry:
    /* KPTI: swap CR3 user -> kernel as the ABSOLUTE first action. On
     * SYSCALL entry %rsp still points at the user stack (US=1, mapped in
     * BOTH tables via PML4[0]), so we can spill two scratch regs there to
     * compute the kernel CR3 from this CPU's kpti_kernel_cr3_slots[cpu].
     * STAC: CPL=0 stores to a US=1 page need AC under CR4.SMAP. cpu_id is
     * at %gs:0 (codegen-pinned). kpti_kernel_cr3_slots is in .kpti.bss
     * (mapped in the user PML4). When KPTI is disabled this slot holds the
     * FULL cr3 too, so the load is a harmless reload of the same table. */
    stac
    pushq   %rax                      /* save user nr (restored below)   */
    pushq   %rcx                      /* save user RIP (restored below)  */
    /* KPTI master switch. CR4.PGE=0 means EVERY mov-to-cr3 is a full TLB
     * flush even reloading the same value, so when KPTI is staged OFF we
     * must SKIP the reload entirely (a single predicted branch), not load
     * an identical table. kpti_enabled is in .kpti.data (mapped under the
     * user CR3). */
    leaq    kpti_enabled(%rip), %rax
    movq    (%rax), %rax
    testq   %rax, %rax
    jz      8f
    movq    %gs:0, %rax               /* cpu_id (pinned per-CPU offset 0) */
    leaq    kpti_kernel_cr3_slots(%rip), %rcx
    movq    (%rcx, %rax, 8), %rax     /* kernel CR3 for this CPU's task   */
    movq    %rax, %cr3
8:  popq    %rcx                      /* restore user RIP                */
    popq    %rax                      /* restore user nr                 */
    clac
    /* On entry from SYSCALL:
     *   %rax = syscall number
     *   %rdi, %rsi, %rdx, %r10, %r8, %r9 = syscall args
     *   %rcx = saved user RIP
     *   %r11 = saved user RFLAGS
     *   CS / SS already loaded from STAR[47:32]
     *   IF cleared per IA32_FMASK
     *
     * Per SysV the user expects every callee-saved register
     * (%rbx, %rbp, %r12..%r15) intact across the syscall, plus the
     * caller-saved set that the syscall ABI doesn't carve out
     * (%rdi/%rsi/%rdx/%r10/%r8/%r9 are inputs but we shouldn't return
     * with them changed by the dispatch path).
     *
     * Per-task syscall stack (M16.35): we read the current task's
     * kernel stack from TSS.RSP0 (kept current by schedule()) and
     * stash the user RSP on THAT stack. Earlier revs spilled to a
     * single global (user_rsp_save / kernel_rsp) which broke as soon
     * as SYS_WAITPID started yielding mid-syscall — the child's own
     * later syscall_entry would overwrite the parent's saved slot.
     *
     * We use %r12 as a transient scratch — park user %r12 on the
     * user stack first so we can restore it on return.
     *
     * SMAP v3b: SYSCALL doesn't switch stacks — on entry %rsp still
     * points at the user stack (US=1 page). The two pushq's below are
     * CPL=0 stores to a US=1 page, which #PF under CR4.SMAP=1 unless
     * RFLAGS.AC is set. STAC here; CLAC after we switch RSP to the
     * kernel stack (TSS.RSP0) a few instructions down so SMAP protects
     * the rest of kernel execution. STAC/CLAC are #UD on pre-Broadwell
     * silicon, but cpu_mitigations.c only flips CR4.SMAP when CPUID
     * reports SMAP — and the instructions themselves are legal whenever
     * the CPU supports SMAP, regardless of CR4.SMAP state.
     */
    stac                              /* SMAP: allow CPL=0 user-stack writes */
    pushq   %r12                      /* park user %r12 on user stack */
    pushq   %r13                      /* park user %r13 (per-CPU scratch) */
    clac                              /* SMAP back on for the kernel body */

    /* %r12 = current task's kernel stack top = THIS CPU's TSS.RSP0.
     * schedule() keeps per_cpu_tss[cpu_id].rsp0 pointed at
     * task->kstack_top on every switch. PER-CPU: the syscall runs on
     * whatever CPU the user task is on, so we must read THAT CPU's TSS,
     * not a single global one — index per_cpu_tss[] by cpu_id (the
     * cpu_id_pcpu slot; kernel %gs is the per-CPU area base, no swapgs
     * in Hamnix). cpu_id is read via %gs:0: the Adder codegen PINS
     * cpu_id_pcpu to per-CPU offset 0 (ABI invariant — see
     * setup_percpu_asm.S). Regression #402 was exactly this read picking
     * up a different Percpu global (local_timer_ticks) that had drifted
     * to offset 0: the timer-tick counter was used as a CPU id, indexed
     * a wild per_cpu_tss[] slot, and the garbage RSP0 #GP'd on the
     * kernel-stack write below. TSS_STRIDE = 128 = 1<<7. */
    movq    %gs:0, %r12               /* r12 = cpu_id (pinned offset 0)  */
    shlq    $7, %r12                  /* r12 = cpu_id * 128 (TSS_STRIDE) */
    movabsq $per_cpu_tss, %r13        /* r13 = &per_cpu_tss[0]           */
    addq    %r13, %r12                /* r12 = &per_cpu_tss[cpu_id]      */
    movq    4(%r12), %r12             /* r12 = TSS.RSP0 (kstack top)     */

    /* Park user RSP at kstack_top - 8, then switch to that slot.
     * After this, subsequent pushes land below the user-RSP slot,
     * and the matching popq %rsp at the tail restores it directly. */
    movq    %rsp, -8(%r12)            /* user rsp (with r12 push) -> kstack */
    leaq    -8(%r12), %rsp            /* RSP -> kernel stack just below it  */

    /* Save the SYSCALL hardware-saved regs for sysretq later. */
    pushq   %r11                      /* user RFLAGS */
    pushq   %rcx                      /* user RIP    */

    /* fork(2) register inheritance: a forked child is a brand-new task
     * whose initial kstack frame zeroes the 6 callee-saved registers
     * (see _build_initial_kstack). For the child to resume the C/asm
     * caller correctly it must inherit the PARENT's callee-saved set.
     * %r12/%r13 are already parked on the USER stack above (and read by
     * do_clone from kstack_top-8/-16). The remaining four — %rbx %rbp
     * %r14 %r15 — are otherwise never spilled by the kernel (the SysV C
     * ABI just preserves them in-register across do_syscall for the
     * returning parent), so do_clone has no copy to give the child.
     * Spill them here, at the user's values, into fixed kernel-stack
     * slots BELOW the rcx/r11 pair so the kstack_top-8/-16/-24 offsets
     * do_clone already reads stay valid. Layout (from kstack_top):
     *   -8  user rsp (with r12 push)   [parked above]
     *   -16 user RFLAGS (r11)
     *   -24 user RIP (rcx)
     *   -32 user %rbx     <-- new
     *   -40 user %rbp     <-- new
     *   -48 user %r14     <-- new
     *   -56 user %r15     <-- new
     * Popped symmetrically on the sysret path so the parent's own
     * registers are unperturbed. */
    pushq   %rbx                      /* user %rbx  (callee-saved) */
    pushq   %rbp                      /* user %rbp  (callee-saved) */
    pushq   %r14                      /* user %r14  (callee-saved) */
    pushq   %r15                      /* user %r15  (callee-saved) */

    /* Save all 6 user-arg regs + nr. Linux's x86_64 syscall ABI says
     * %rdi/%rsi/%rdx/%r10/%r8/%r9 are preserved across SYSCALL.
     * Musl's __lockfile spin loop holds &f->lock in %rdi across
     * FUTEX_WAIT and re-CASes after wake — and musl's open()/opendir()
     * keep the just-opened fd in %rdi across the trailing
     * fcntl(F_SETFD,FD_CLOEXEC) syscall and the call to __syscall_ret.
     * So %rdi MUST be restored to the caller's value on EVERY syscall
     * exit, exactly as %rsi/%rdx/%r10/%r8/%r9 already are.
     *
     * (Historical note: U27 zeroed %rdi for non-FUTEX exits as a
     * workaround for a glibc-2.39 static-pie startup failure whose
     * root cause was never identified. That zeroing is an x86_64
     * SYSCALL-ABI violation: it corrupted the fd musl's opendir()
     * holds in %rdi across fcntl(), so musl's open() returned 0 and
     * busybox `ls` enumerated nothing. The glibc failure no longer
     * reproduces — u_glibc_hello / u_glibc_idprobe pass with %rdi
     * preserved — so the workaround has been removed. Verified
     * non-regressing across fork (test_u26), busybox ls (test_u32,
     * now XPASS), musl pthreads (test_u27), signals, and the full
     * compiler suite.)
     *
     * Push order is the reverse of pop order. 8 pushes (6 args + nr +
     * pad) keep `call` 16-byte aligned with the subsequent pad + a5. */
    pushq   %r9
    pushq   %r8
    pushq   %r10
    pushq   %rdx
    pushq   %rsi
    pushq   %rdi
    pushq   %rax                      /* stash nr (orig user %rax) */
    pushq   $0                        /* pad to keep `call` 16B aligned */
    pushq   $0                        /* alignment pad (higher addr than a5) */
    pushq   %r9                       /* a5 -> stack arg 7 (still user_r9
                                       *      — shuffle hasn't run yet) */

    /* Now do the register shuffle. Order matters: read each source
     * register before any move that would clobber it. r9 (target a4)
     * needs the old r8 (a4) BEFORE we trash r8 with r10 (a3). */
    movq    %r8,  %r9                 /* a4 (r9 = user r8) */
    movq    %r10, %r8                 /* a3 (r8 = user r10) */
    movq    %rdx, %rcx                /* a2 */
    movq    %rsi, %rdx                /* a1 */
    movq    %rdi, %rsi                /* a0 */
    movq    %rax, %rdi                /* nr */

    call    do_syscall                /* return value lands in %rax */

    /* Reclaim the 16 bytes pushed for a5 + alignment pad. */
    addq    $16, %rsp

    /* Drop the second pad we added for nr-stash alignment, then
     * discard the stashed nr (it was only needed by the old per-nr
     * %rdi branch; %rdi is now restored unconditionally). */
    addq    $8, %rsp                  /* drop the inner pad */
    addq    $8, %rsp                  /* drop the stashed nr */

    /* Restore the full caller-saved syscall-arg set to the user's
     * values. The x86_64 SYSCALL ABI guarantees %rdi/%rsi/%rdx/%r10/
     * %r8/%r9 survive `syscall`; %rax already holds do_syscall's
     * return value and is intentionally NOT restored. */
    popq    %rdi                      /* user a0 — restore (ABI) */
    popq    %rsi
    popq    %rdx
    popq    %r10
    popq    %r8
    popq    %r9

    /* Pop the four callee-saved registers spilled at entry (see the
     * fork-inheritance comment above). On the normal return-to-parent
     * path these restore the user's own %rbx/%rbp/%r14/%r15 unchanged;
     * the spill exists purely so do_clone can copy them into a forked
     * child's fresh frame. Pop order is the reverse of the push order
     * (r15 was pushed last / lowest, so it pops first). */
    popq    %r15                      /* user %r15  (callee-saved) */
    popq    %r14                      /* user %r14  (callee-saved) */
    popq    %rbp                      /* user %rbp  (callee-saved) */
    popq    %rbx                      /* user %rbx  (callee-saved) */

    /* Restore syscall-control regs and user RSP. We pop the
     * (per-task) stored user RSP straight into %rsp; the next pop
     * pulls user %r12 from the user stack and sysretq returns. */
    popq    %rcx                      /* user RIP    */
    popq    %r11                      /* user RFLAGS */
    popq    %rsp                      /* user rsp (= user_rsp - 16) */

    /* KPTI: swap CR3 kernel -> user before the trailing user-stack pops +
     * sysretq. %r12/%r13 are dead here (immediately re-popped to their
     * user values below), so use them as scratch. The user stack and
     * kpti_user_cr3_slots are both mapped in the user PML4, and these
     * instructions are in .kpti.text, so the pops + sysretq fetch cleanly
     * under the user table. When KPTI is disabled this slot holds the
     * full cr3, so the load is a no-op reload. */
    leaq    kpti_enabled(%rip), %r12
    movq    (%r12), %r12
    testq   %r12, %r12
    jz      7f
    movq    %gs:0, %r12               /* cpu_id (pinned per-CPU offset 0) */
    leaq    kpti_user_cr3_slots(%rip), %r13
    movq    (%r13, %r12, 8), %r12     /* user CR3 for this CPU's task     */
    movq    %r12, %cr3
7:

    /* SMAP v3b: the next two popq's read from the user stack at CPL=0,
     * so we re-arm AC just for that window. SYSRETQ then reloads RFLAGS
     * from %r11 (user's saved RFLAGS), which clears AC naturally — no
     * explicit CLAC needed before the sysretq. */
    stac                              /* SMAP: allow CPL=0 user-stack reads */
    popq    %r13                      /* user %r13 (parked 2nd, lowest) */
    popq    %r12                      /* user %r12 (parked 1st)     */

    sysretq                           /* CPL 0 -> 3, RIP=%rcx       */

/* Back to plain .text for the helpers below — they all run with the
 * kernel CR3 (called from kernel context), so they need not be in the
 * .kpti window. EXCEPTION: do_execve_finish / enter_user_mode end in a
 * CPL0->CPL3 transition and so carry their own user-CR3 swap below; the
 * swap instructions there are still fetched under the kernel CR3 (we are
 * in kernel context until the sysretq/iretq retires), so plain .text is
 * correct for them. */
    .section .text, "ax"

/* ---------- write_msr(index, value) ------------------------------ */

    .align 16
    .globl write_msr
write_msr:
    movl    %edi, %ecx                /* MSR index from %edi (zero-ext) */
    movq    %rsi, %rax                /* low 32 from value             */
    movq    %rsi, %rdx
    shrq    $32, %rdx                 /* high 32                       */
    wrmsr
    ret

/* ---------- read_msr(index) -> uint64 --------------------------- */

    .align 16
    .globl read_msr
read_msr:
    movl    %edi, %ecx
    rdmsr
    shlq    $32, %rdx
    orq     %rdx, %rax
    ret

/* ---------- read_tsc() -> uint64 -------------------------------- *
 * Read the 64-bit Time Stamp Counter. RDTSC writes the low 32 bits
 * to %eax and the high 32 bits to %edx (the high bits of %rax/%rdx
 * are zeroed by the instruction). Stitch them into a single 64-bit
 * value in %rax for the SysV return register.
 *
 * lfence first: RDTSC is not a serialising instruction, so without
 * a barrier the CPU may execute it out of order relative to the
 * surrounding code, skewing a delta measurement. LFENCE is the
 * lightweight ordering fence Linux uses on the rdtsc_ordered() path
 * (it waits for all prior loads to retire before RDTSC issues).
 */
    .align 16
    .globl read_tsc
read_tsc:
    lfence
    rdtsc
    shlq    $32, %rdx
    orq     %rdx, %rax
    ret

/* ---------- set_efer_sce: enable SYSCALL/SYSRET ------------------ */

    .align 16
    .globl set_efer_sce
set_efer_sce:
    movl    $0xC0000080, %ecx          /* IA32_EFER */
    rdmsr
    orl     $1, %eax                   /* bit 0 = SCE (Syscall Enable) */
    wrmsr
    ret

/* ---------- set_efer_nxe: enable No-Execute (NX) -------------------- *
 * W^X Stage 1a. IA32_EFER.NXE = bit 11 (0x800). MUST be set on a CPU
 * BEFORE any PTE with bit 63 (NX) is loaded on that CPU — with NXE off,
 * bit 63 is a RESERVED bit and a load faults (#PF, RSVD set). The BSP
 * flips this in syscall_init (Adder side); each AP flips it in the
 * realmode trampoline alongside EFER.LME, so it is on before the AP
 * ever runs a user task carrying an NX data page. */
    .align 16
    .globl set_efer_nxe
set_efer_nxe:
    movl    $0xC0000080, %ecx          /* IA32_EFER */
    rdmsr
    orl     $(1 << 11), %eax           /* bit 11 = NXE (No-Execute Enable) */
    wrmsr
    ret

/* do_execve_finish + enter_user_mode each END in a CPL0->CPL3 transition
 * preceded by a KPTI CR3 swap to the USER table. After that swap the CPU
 * still has to FETCH the following instructions (the sysretq / iretq)
 * which are NOT mapped in the user PML4 if they live in plain .text — so
 * both routines must reside in .kpti.text (mapped in BOTH tables). */
    .section .kpti.text, "ax"

/* ---------- do_execve_finish(new_rip, new_rsp, argc, argv) -------- *
 * Tail-call from the SYS_EXECVE handler when it has loaded a new ELF
 * and wants to "become" that program. We never return through the
 * normal syscall path — instead we set up the registers SYSRETQ
 * reads (%rcx = new RIP, %r11 = new RFLAGS with IF=1) and load the
 * new user RSP directly, then SYSRETQ ourselves out to CPL=3.
 *
 * As of M16.35 the kernel also stages argc / argv for user _start by
 * delivering them in %rdi / %rsi. SysV makes those the first two
 * arguments to main(), so user code that declares
 *     def main(argc: int32, argv: Ptr[uint64]) -> int32:
 * receives them naturally; programs whose main() takes no args
 * (the existing hello.ad / init.S) simply don't read them.
 *
 * SysV inputs: %rdi=new_rip, %rsi=new_rsp, %rdx=argc, %rcx=argv.
 * No return.
 */

    .align 16
    .globl do_execve_finish
do_execve_finish:
    /* Stash argv in a scratch reg before we clobber %rcx with the
     * SYSRETQ RIP. After this we don't need any SysV-input regs
     * besides the ones being installed for user. */
    movq    %rcx, %r10                 /* save argv                   */
    movq    %rsi, %rsp                 /* user stack                  */
    movq    %rdi, %rcx                 /* SYSRETQ pulls RIP from %rcx */
    movq    %rdx, %rdi                 /* user %rdi = argc            */
    movq    %r10, %rsi                 /* user %rsi = argv            */
    movq    $0x202, %r11               /* RFLAGS (IF=1, reserved bit) */
    /* KPTI: install the user PML4 before returning to CPL3. We are still
     * in kernel context (kernel CR3), so this swap's ifetch is from .text
     * fine; the sysretq lands in user code under the user table. The
     * Adder execve path updates kpti_user_cr3_slots[cpu] to this task's
     * (possibly just-rebuilt) user_cr3 before tail-calling here. r8/r9 are
     * dead at this point. */
    leaq    kpti_enabled(%rip), %r8
    movq    (%r8), %r8
    testq   %r8, %r8
    jz      6f
    movq    %gs:0, %r8
    leaq    kpti_user_cr3_slots(%rip), %r9
    movq    (%r9, %r8, 8), %r8
    movq    %r8, %cr3
6:  sysretq

/* ---------- enter_user_mode(entry, stack) ------------------------ *
 * Build an iretq frame on the kernel stack with CPL=3 selectors and
 * iretq into ring 3. The iret frame on x86_64 is always 5 quads in
 * long mode; we have to pop SS/RSP too because iretq with a CPL
 * change always pops them. RFLAGS = 0x002 = reserved bit only; IF=0
 * keeps preemption off in user mode (M16.17 doesn't yet handle a
 * timer IRQ landing on user context — that needs a TSS / RSP0 slot).
 *
 * SysV: %rdi = entry, %rsi = stack top
 */
    .align 16
    .globl enter_user_mode
enter_user_mode:
    /* Build a CPL-change iret frame:
     *   high: SS    (user data, RPL=3) = 0x18 | 3 = 0x1B
     *         RSP   (user stack top)
     *         RFLAGS (0x002 - IF clear)
     *         CS    (user code, RPL=3) = 0x20 | 3 = 0x23
     *   low:  RIP   (user entry)
     */
    pushq   $0x1B                      /* SS                          */
    pushq   %rsi                       /* RSP                         */
    pushq   $0x202                     /* RFLAGS (IF=1 - timer fires) */
    pushq   $0x23                      /* CS                          */
    pushq   %rdi                       /* RIP                         */
    /* KPTI: install the user PML4 before iretq to CPL3. iret frame is
     * already built on the kernel stack (PML4[0], mapped in both); after
     * the swap the iretq fetch is still kernel-CR3 (current insn) and the
     * landing pad is user. r8/r9 are dead here. */
    leaq    kpti_enabled(%rip), %r8
    movq    (%r8), %r8
    testq   %r8, %r8
    jz      5f
    movq    %gs:0, %r8
    leaq    kpti_user_cr3_slots(%rip), %r9
    movq    (%r9, %r8, 8), %r8
    movq    %r8, %cr3
5:  iretq

    /* Back to plain .text: the user-mode demo payloads below are copied
     * into US=1 user pages and executed there (position-independent), so
     * they need not be in the .kpti window. */
    .section .text, "ax"

/* ---------- user_demo_entry: ring-3 test payload ----------------- *
 * A tiny user program that issues a series of SYS_PUTC (nr=0) calls
 * to print "Hamnix user: HELLO\n" character-by-character, then a
 * SYS_EXIT (nr=1) which never returns. Demonstrates:
 *
 *   - User code actually executing at CPL 3 (the iretq landed).
 *   - SYSCALL transitions to CPL 0 with kernel CS/SS.
 *   - SYSRETQ returns to user, %rip = %rcx that the user provided.
 *   - The user can drive a loop and accumulate multiple syscalls.
 *
 * Each character is loaded into %rdi (syscall arg 0) and %rax holds
 * the syscall number. After SYS_EXIT we never return, but we still
 * emit a hang loop so a bug in the syscall path doesn't run off into
 * arbitrary memory. user-mode HLT is illegal (#GP), so the hang is
 * a plain `jmp .`.
 */
    .align 16
    .globl user_demo_entry
user_demo_entry:
    /* M16.26 demo: pre-opened stdout (fd 1) + stderr (fd 2) plus
     * SYS_WRITE to bulk-print; SYS_LSEEK to reposition; SYS_READ
     * still slurps the file. Exercises every fd-table-aware path
     * in fs/vfs.py end-to-end. */

    /* banner via stdout */
    movq    $1, %rdi
    leaq    user_banner(%rip), %rsi
    movq    $user_banner_end - user_banner, %rdx
    movq    $8, %rax                   /* SYS_WRITE                  */
    syscall

    /* fd = open("/motd") */
    leaq    fname_motd(%rip), %rdi
    movq    $5, %rax                   /* SYS_OPEN                   */
    syscall
    movq    %rax, %r13                 /* save fd                    */

    /* Stream the whole file: while ((n = read(fd, buf, 64)) > 0)
     *                              write(1, buf, n) */
.Lread_loop:
    movq    %r13, %rdi
    leaq    user_read_buf(%rip), %rsi
    movq    $64, %rdx
    movq    $6, %rax                   /* SYS_READ                   */
    syscall
    testq   %rax, %rax
    jle     .Lread_done

    movq    %rax, %rdx                 /* count = bytes read          */
    movq    $1, %rdi
    leaq    user_read_buf(%rip), %rsi
    movq    $8, %rax                   /* SYS_WRITE                  */
    syscall
    jmp     .Lread_loop

.Lread_done:
    /* lseek(fd, 9, SEEK_SET) + read 12 + write to stdout. Byte 9
     * of /motd is "Hamnix from a" — proves the seek repositions. */
    movq    %r13, %rdi
    movq    $9, %rsi
    movq    $0, %rdx                   /* SEEK_SET                   */
    movq    $9, %rax                   /* SYS_LSEEK                  */
    syscall

    /* "seeked: " label via stderr to mix the two streams */
    movq    $2, %rdi
    leaq    user_seek_label(%rip), %rsi
    movq    $user_seek_label_end - user_seek_label, %rdx
    movq    $8, %rax
    syscall

    movq    %r13, %rdi
    leaq    user_read_buf(%rip), %rsi
    movq    $12, %rdx
    movq    $6, %rax                   /* SYS_READ                   */
    syscall
    movq    %rax, %rdx
    movq    $1, %rdi
    leaq    user_read_buf(%rip), %rsi
    movq    $8, %rax                   /* SYS_WRITE                  */
    syscall

    /* End-of-output via stderr */
    movq    $2, %rdi
    leaq    user_eot(%rip), %rsi
    movq    $user_eot_end - user_eot, %rdx
    movq    $8, %rax
    syscall

    /* close + exit */
    movq    %r13, %rdi
    movq    $7, %rax                   /* SYS_CLOSE                  */
    syscall
    movq    $1, %rax                   /* SYS_EXIT                   */
    syscall

.user_demo_hang:
    jmp     .user_demo_hang

/* ---------- smp_user_probe_entry: ring-3 STAGE-A SMP proof -------- *
 * A minimal ring-3 payload used by smp_user_ap_selftest() to prove a
 * USER task can run on a NON-BSP CPU (AP) without faulting. It:
 *   1. busy-loops briefly (so it is observably "running" CPU-bound and
 *      the dispatch accounting records the CPU it ran on), then
 *   2. issues ONE SYS_WRITE banner — this is the load-bearing step: the
 *      SYSCALL from CPL3 on the AP reads the AP's OWN per_cpu_tss RSP0
 *      (the Stage-A fix); a missing/shared TSS would fault here, then
 *   3. SYS_EXIT, which self-reaps the task back to the AP idle loop.
 * Kept deliberately syscall-light (no open/read of files) so the proof
 * exercises exactly the ring3->ring0 transition the per-CPU TSS enables,
 * with no dependency on a per-task fd table.                            */
    /* This block is POSITION-INDEPENDENT and SELF-CONTAINED: the code,
     * its inline banner string, and the end marker all live contiguously
     * in .text. smp_user_ap_selftest() copies the whole
     * [smp_user_probe_entry, smp_user_probe_end) span into a fresh page
     * that it maps US=1 (CPL3-executable) at a low user VA, then starts
     * the task there. Kernel .text is US=0 (W^X / SMEP hardening restamps
     * every high-half leaf supervisor-only), so a CPL3 task can NOT fetch
     * from the kernel VA of this symbol — it must run from the US=1 copy.
     * Everything here is %rip-relative or immediate, so it executes
     * correctly from ANY load address. The banner ref uses leaq(%rip), so
     * once the block is relocated the banner address tracks the copy. */
    .align 16
    .globl smp_user_probe_entry
smp_user_probe_entry:
    /* brief CPU-bound spin so the task is unambiguously dispatched.
     * Kept small: under TCG a multi-million-iteration spin can outlast
     * the BSP self-test's poll budget, so the SYS_WRITE banner (the
     * ring3->ring0 proof) never lands. 50k is enough to be observably
     * scheduled while still reaching the syscall promptly. */
    movq    $50000, %rcx
.Lspin_probe:
    decq    %rcx
    jnz     .Lspin_probe

    /* SYS_WRITE(2, banner, len) — stderr, via the AP's per-CPU TSS RSP0.
     * leaq(%rip) keeps the banner pointer correct after the block is
     * relocated into the US=1 user copy. */
    movq    $2, %rdi
    leaq    smp_user_probe_banner(%rip), %rsi
    movq    $smp_user_probe_banner_end - smp_user_probe_banner, %rdx
    movq    $8, %rax                   /* SYS_WRITE                  */
    syscall

    /* SYS_EXIT(0) — never returns; task self-reaps to AP idle loop */
    movq    $0, %rdi
    movq    $1, %rax                   /* SYS_EXIT                   */
    syscall

.smp_user_probe_hang:
    jmp     .smp_user_probe_hang

    /* Inline banner — kept IN .text, contiguous with the code, so the
     * single-page copy in smp_user_ap_selftest captures it too. */
    .align 8
    .globl smp_user_probe_banner
smp_user_probe_banner:
    .ascii "[smp_user] ring3 task ran a syscall on its CPU\n"
    .globl smp_user_probe_banner_end
smp_user_probe_banner_end:
    .align 16
    .globl smp_user_probe_end
smp_user_probe_end:

/* ---------- user-mode .data / .rodata ----------------------------
 * fname_motd is a string literal we point SYS_OPEN at. user_read_buf
 * is the 64-byte chunk SYS_READ fills.  Both pages are U=1 because
 * the entire identity-mapped region is.                              */
    .section .rodata
fname_motd:
    .asciz "/motd"
user_banner:
    .ascii "[user] M16.26 fd-table / write / lseek demo:\n"
user_banner_end:
user_seek_label:
    .ascii "\n[user] (stderr) after lseek(fd, 9, SEEK_SET): "
user_seek_label_end:
user_eot:
    .ascii "\n[user] (stderr) done.\n"
user_eot_end:

    .section .data
    .align 8
user_read_buf:
    .skip 64
