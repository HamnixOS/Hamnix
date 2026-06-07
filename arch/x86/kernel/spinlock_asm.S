/*
 * arch/x86/kernel/spinlock_asm.S — minimal ticket-free test-and-set spinlock.
 *
 * Uses a single uint32 word as the lock state:
 *   0 = unlocked
 *   1 = locked
 *
 * spinlock_lock(ptr)   — spin until the lock is free, then acquire.
 *                        Uses LOCK XCHG which is atomic and has an
 *                        implicit LOCK prefix (xchg with memory is
 *                        always locked on x86). The PAUSE hint inside
 *                        the spin loop reduces power and pipeline
 *                        pressure on hyperthreaded cores.
 *
 * spinlock_unlock(ptr) — release the lock via a plain store (which is
 *                        sufficient on x86's TSO memory model: stores
 *                        are sequentially consistent with respect to
 *                        prior loads/stores in program order).
 *
 * Both functions follow the SysV AMD64 ABI:
 *   %rdi = ptr (Ptr[uint32], the lock word address)
 *   no return value (void)
 *   caller-saved regs: %rax, %rcx, %rdx, %rsi, %rdi, %r8..%r11
 *   callee-saved regs: %rbp, %rbx, %r12..%r15 (not touched here)
 */

    .code64
    .section .text, "ax"

/* ---------- spinlock_lock(ptr: Ptr[uint32]) ----------------------- */
    .align 16
    .globl spinlock_lock
spinlock_lock:
    /* %rdi = lock word address (uint32 *) */
    movl    $1, %eax                    /* value to swap in (1 = locked) */
.Lspin_loop:
    /* XCHG with memory: atomically swaps %eax with [%rdi].
     * Returns the OLD value in %eax. If old value was 0, we won
     * the lock. If old value was 1, someone else held it — retry. */
    xchgl   %eax, (%rdi)
    testl   %eax, %eax
    jz      .Lspin_done                 /* was 0 → we got the lock */
    /* Lock was held. Spin with PAUSE to reduce pipeline pressure.
     * Read the lock word first (without LOCK) so we stay in the
     * cache coherence "shared" state; only attempt the atomic XCHG
     * when the word LOOKS free. This is the classic "test, test-and-set"
     * optimisation that avoids hammering the memory bus. */
.Lspin_wait:
    pause
    movl    (%rdi), %eax
    testl   %eax, %eax
    jnz     .Lspin_wait                 /* still held; keep waiting */
    movl    $1, %eax
    jmp     .Lspin_loop                 /* try to acquire again */
.Lspin_done:
    ret

/* ---------- spinlock_trylock(ptr: Ptr[uint32]) -> uint32 ----------
 * Single atomic attempt to acquire. Returns 1 (in %eax) if the lock was
 * free and is now held by the caller, 0 if it was already held (no spin).
 * Used by the scheduler's cross-CPU work-steal / migration paths to take
 * a SECOND runqueue lock without risking deadlock: if the trylock fails
 * the caller backs off and retries with a strict lock ordering, so two
 * CPUs can never wedge holding each other's rq lock.
 */
    .align 16
    .globl spinlock_trylock
spinlock_trylock:
    /* %rdi = lock word address (uint32 *) */
    movl    $1, %eax                    /* value to swap in (1 = locked) */
    xchgl   %eax, (%rdi)                /* %eax <- old value, [rdi] <- 1 */
    /* old==0 => we acquired it => return 1; old==1 => held => return 0. */
    testl   %eax, %eax
    setz    %al                         /* %al = (old == 0) ? 1 : 0 */
    movzbl  %al, %eax
    ret

/* ---------- spinlock_unlock(ptr: Ptr[uint32]) --------------------- */
    .align 16
    .globl spinlock_unlock
spinlock_unlock:
    /* %rdi = lock word address (uint32 *) */
    /* On x86 TSO: a plain store with SFENCE is sufficient for release.
     * The SFENCE ensures all prior writes are globally visible before
     * the unlock word is written. Without SFENCE an out-of-order store
     * buffer could let the critical-section writes appear after the
     * unlock to another CPU, violating the lock contract.
     *
     * Note: LOCK XCHG or LOCK XADD would also work (stronger), but the
     * plain store + SFENCE is the canonical x86 release pattern and
     * avoids unnecessary bus traffic. */
    sfence
    movl    $0, (%rdi)
    ret
