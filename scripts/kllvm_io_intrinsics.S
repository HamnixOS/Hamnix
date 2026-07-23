/*
 * scripts/kllvm_io_intrinsics.S — port-I/O intrinsics as real ABI functions,
 * for the LLVM kernel lane ONLY (scripts/build_kernel_llvm.sh).
 *
 * WHY: the native Adder backend (codegen.ad io_intrinsic_id / gen_io_intrinsic)
 * lowers inb/outb/inl/inw/outl/outw INLINE at each call site — no call, no
 * symbol. The LLVM backend instead emits a real `call i64 @inb(i64 %port)` etc.
 * (declared in the whole-kernel .ll), which has no definition. This TU supplies
 * those definitions with the exact SysV ABI the emitted calls use:
 *
 *   i64 inb(i64 port)          port in %rdi           -> value in %rax
 *   i64 inw(i64 port)          port in %rdi           -> value in %rax
 *   i64 inl(i64 port)          port in %rdi           -> value in %rax
 *   i64 outb(i64 val, i64 port)  val %rdi, port %rsi  -> (ignored)
 *   i64 outw(i64 val, i64 port)  val %rdi, port %rsi  -> (ignored)
 *   i64 outl(i64 val, i64 port)  val %rdi, port %rsi  -> (ignored)
 *
 * The port is truncated to 16 bits in %dx; the value to 8/16/32 in %al/%ax/%eax,
 * matching the native inline sequences byte-for-byte in effect.
 */
    .text
    .code64

    .globl inb
inb:
    movw %di, %dx
    xorl %eax, %eax
    inb  %dx, %al
    ret

    .globl inw
inw:
    movw %di, %dx
    xorl %eax, %eax
    inw  %dx, %ax
    ret

    .globl inl
inl:
    movw %di, %dx
    xorl %eax, %eax
    inl  %dx, %eax
    ret

    .globl outb
outb:
    movl %edi, %eax
    movw %si, %dx
    outb %al, %dx
    ret

    .globl outw
outw:
    movl %edi, %eax
    movw %si, %dx
    outw %ax, %dx
    ret

    .globl outl
outl:
    movl %edi, %eax
    movw %si, %dx
    outl %eax, %dx
    ret

/*
 * Atomic intrinsics — also inlined by the native backend (io_intrinsic_id
 * ids 7..10), emitted as real calls by the LLVM backend. Same effect as the
 * native `lock cmpxchg` / `lock xadd` sequences.
 *
 *   i64 atomic_cas32(i64 addr, i64 expected, i64 desired) -> old   (addr %rdi, exp %rsi, des %rdx)
 *   i64 atomic_cas64(i64 addr, i64 expected, i64 desired) -> old
 *   i64 atomic_add32(i64 addr, i64 delta) -> old                    (addr %rdi, delta %rsi)
 *   i64 atomic_add64(i64 addr, i64 delta) -> old
 */
    .globl atomic_cas32
atomic_cas32:
    movl %esi, %eax            /* expected -> %eax */
    movl %edx, %ecx            /* desired  -> %ecx */
    lock cmpxchgl %ecx, (%rdi)
    movl %eax, %eax            /* zero-extend old */
    ret

    .globl atomic_cas64
atomic_cas64:
    movq %rsi, %rax            /* expected -> %rax */
    movq %rdx, %rcx            /* desired  -> %rcx */
    lock cmpxchgq %rcx, (%rdi)
    ret

    .globl atomic_add32
atomic_add32:
    movl %esi, %eax            /* delta -> %eax */
    lock xaddl %eax, (%rdi)    /* old -> %eax */
    movl %eax, %eax            /* zero-extend */
    ret

    .globl atomic_add64
atomic_add64:
    movq %rsi, %rax            /* delta -> %rax */
    lock xaddq %rax, (%rdi)    /* old -> %rax */
    ret

    .section .note.GNU-stack,"",@progbits
