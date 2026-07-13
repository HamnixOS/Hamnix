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
    .section .text, "ax"

/* ---------- syscall_entry: the SYSCALL handoff ------------------- */

    .align 16
    .globl syscall_entry
syscall_entry:
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
     * KEYSTONE (weston-terminal / threaded clients): the entry MUST NOT
     * touch the user stack at all. Earlier revs did `stac; pushq %r12;
     * pushq %r13` onto the *user* stack to free up scratch. That #PFs the
     * instant a caller's user RSP points at an absent page — exactly the
     * case for a glibc/pthread worker thread whose demand-paged mmap stack
     * top has not been faulted in yet (cairo/pixman render threads). A
     * CPL=0 store to that absent user page #PFs while RSP is still the user
     * stack, so the CPU re-pushes the #PF frame onto the same bad stack:
     * double fault -> triple fault -> CPU reset. So we spill scratch into
     * PER-CPU slots (fixed %gs:72 / %gs:80, pinned by the codegen — see
     * setup_percpu.ad syscall_scratch_r12/_r13) and never write the user
     * stack. No STAC/CLAC needed: the whole prologue/epilogue stays on the
     * kernel stack, so SMAP protects it throughout.
     */
    movq    %r12, %gs:72              /* park user %r12 (per-CPU scratch) */
    movq    %r13, %gs:80              /* park user %r13 (per-CPU scratch) */

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

    /* Grab the user RSP (natural, unmodified) then switch RSP to the
     * kernel stack. user %r13 is safe in the per-CPU scratch slot. */
    movq    %rsp, %r13                /* r13 = user rsp (natural)        */
    movq    %r12, %rsp                /* RSP -> kernel stack (TSS.RSP0)  */

    /* Save the SYSCALL hardware-saved regs for sysretq later. These three
     * slots (kstack_top-8/-16/-24) are the LOAD-BEARING ones read by
     * saved_user_rsp/rflags/rip_ptr (signal delivery + ptrace) — keep them
     * fixed. Everything is pushed on the KERNEL stack now, so no fault. */
    pushq   %r13                      /* -8  user RSP (natural)     */
    pushq   %r11                      /* -16 user RFLAGS            */
    pushq   %rcx                      /* -24 user RIP               */

    /* fork(2) register inheritance: a forked child is a brand-new task
     * whose initial kstack frame zeroes the 6 callee-saved registers
     * (see _build_initial_kstack). For the child to resume the C/asm
     * caller correctly it must inherit the PARENT's callee-saved set.
     * do_clone reads them out of these fixed kernel-stack slots. %r12/%r13
     * used to be parked on the USER stack; now they are spilled here (from
     * the per-CPU scratch) just below the RIP slot. Layout (from kstack_top):
     *   -8  user RSP (natural)
     *   -16 user RFLAGS (r11)
     *   -24 user RIP (rcx)
     *   -32 user %r13
     *   -40 user %r12
     *   -48 user %rbx
     *   -56 user %rbp
     *   -64 user %r14
     *   -72 user %r15
     * Reloading %r12/%r13 from scratch here also leaves the user values in
     * those registers, which the SysV C ABI then preserves across
     * do_syscall for the returning parent. Popped symmetrically on the
     * sysret path so the parent's own registers are unperturbed. */
    movq    %gs:80, %r13              /* reload user %r13 from scratch */
    movq    %gs:72, %r12              /* reload user %r12 from scratch */
    pushq   %r13                      /* -32 user %r13              */
    pushq   %r12                      /* -40 user %r12              */
    pushq   %rbx                      /* -48 user %rbx (callee-saved) */
    pushq   %rbp                      /* -56 user %rbp              */
    pushq   %r14                      /* -64 user %r14              */
    pushq   %r15                      /* -72 user %r15              */

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

    /* Pop the spilled registers in reverse of the entry push order
     * (r15 was pushed last / lowest, so it pops first). On the normal
     * return-to-parent path these restore the user's own callee-saved
     * set unchanged; the spill exists purely so do_clone can copy the
     * parent's values into a forked child's fresh frame. */
    popq    %r15                      /* -72 user %r15 */
    popq    %r14                      /* -64 user %r14 */
    popq    %rbp                      /* -56 user %rbp */
    popq    %rbx                      /* -48 user %rbx */
    popq    %r12                      /* -40 user %r12 */
    popq    %r13                      /* -32 user %r13 */

    /* Restore syscall-control regs and the (natural) user RSP. Everything
     * here reads the KERNEL stack, so no user-stack access and no SMAP
     * window is needed — the last popq loads the user RSP straight into
     * %rsp and SYSRETQ returns to CPL=3. */
    popq    %rcx                      /* -24 user RIP    */
    popq    %r11                      /* -16 user RFLAGS */
    popq    %rsp                      /* -8  user RSP (natural) */

    /* MDS mitigation (task #87): CLEAR_CPU_BUFFERS. VERW against a valid
     * data-segment selector flushes the store buffer / fill buffers /
     * load ports when MD_CLEAR microcode is present, closing the
     * Microarchitectural Data Sampling side channel on the kernel->user
     * boundary. It MUST run after every GP register is restored and as
     * close to the ring transition as possible. VERW only writes
     * FLAGS.ZF + microarch state; SYSRETQ reloads RFLAGS from %r11 so the
     * ZF clobber is harmless. The selector word (mds_verw_sel = 0x10,
     * kernel data) lives in .rodata below and is read at CPL0 (US=0), so
     * this is SMAP-clean and touches no user memory. Unconditional:
     * VERW is architecturally a no-op-for-correctness without MD_CLEAR. */
    verw    mds_verw_sel(%rip)        /* CLEAR_CPU_BUFFERS (MDS) */
    sysretq                           /* CPL 0 -> 3, RIP=%rcx       */

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
    verw    mds_verw_sel(%rip)         /* CLEAR_CPU_BUFFERS (MDS, #87) */
    sysretq

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
    verw    mds_verw_sel(%rip)         /* CLEAR_CPU_BUFFERS (MDS, #87) */
    iretq

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

/* ---------- pf_race_probe_entry: task #112 SMP demand-fault racer ----- *
 * A minimal, POSITION-INDEPENDENT, STACKLESS ring-3 payload used by
 * pf_smp_race_selftest() to reproduce the intermittent -smp 2 not-present
 * user #PF (#112). Two copies of this task SHARE ONE address space (one
 * PML4 + one VMA tree) and run CONCURRENTLY, one per CPU. Each sweeps the
 * SAME large demand-zero anon region [PF_RACE_REGION_BASE, +N*4K) reading
 * one byte per page, so both CPUs demand-fault the SAME not-present page in
 * the same interrupt-latency window — the exact cross-CPU shared-mm fault
 * collision the fault path must handle without a false SIGSEGV.
 *
 * Register-only + immediate (PIC): executes correctly from any load
 * address once copied into a US=1 user page. Uses NO stack (no push/call),
 * so the two tasks sharing one PML4 need no private user stack — the only
 * stack touch, the SYS_EXIT syscall, runs on the per-CPU kernel stack.
 * Base + page count are patched as immediates to match the kernel-side
 * PF_RACE_* constants in kernel/sched/core.ad.                          */
    .align 16
    .globl pf_race_probe_entry
pf_race_probe_entry:
    movabsq $0x10000000, %rsi          /* PF_RACE_REGION_BASE (cursor)   */
    movq    $0x100, %rcx               /* PF_RACE_REGION_PAGES (256)     */
.Lpf_race_sweep:
    movb    (%rsi), %al                /* read 1 byte -> demand-fault it */
    addq    $4096, %rsi
    decq    %rcx
    jnz     .Lpf_race_sweep
    /* SYS_EXIT(0) — self-reaps to the idle loop. */
    movq    $0, %rdi
    movq    $1, %rax
    syscall
.Lpf_race_hang:
    jmp     .Lpf_race_hang
    .align 16
    .globl pf_race_probe_end
pf_race_probe_end:

/* ---------- user-mode .data / .rodata ----------------------------
 * fname_motd is a string literal we point SYS_OPEN at. user_read_buf
 * is the 64-byte chunk SYS_READ fills.  Both pages are U=1 because
 * the entire identity-mapped region is.                              */
    .section .rodata
/* ---------- mds_verw_sel: CLEAR_CPU_BUFFERS operand (task #87) ------ *
 * A 16-bit word holding a valid, present, writable data-segment
 * selector (0x10 = kernel data, __KERNEL_DS in gdt64; see
 * arch/x86/boot/header.S). This is the memory operand for the VERW
 * instruction inserted before every kernel->user ring transition
 * (SYSRETQ / IRETQ-to-CPL3) across syscall_64.S, irq_asm.S,
 * trap_asm.S and sched_asm.S. VERW with MD_CLEAR microcode present
 * overwrites the store buffer / fill buffers / load ports as a side
 * effect of the descriptor load, closing the MDS side channel. The
 * word lives in kernel .rodata (US=0), read only at CPL0, so it never
 * touches user memory and is SMAP-clean. Defined ONCE here and
 * referenced %rip-relative from every exit site. Global so the other
 * .S objects can reach it after the static kernel link. */
    .align 2
    .globl mds_verw_sel
mds_verw_sel:
    .word 0x10
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
