# Pynux M8.2: atomic_t via inline asm.
#
# `atomic_inc()` / `atomic_dec()` etc. are macros in C that expand to
# `lock`-prefixed instructions. Pynux's zero-operand inline asm
# (asm_volatile("...")) plus the SysV-AMD64 calling convention is
# enough to express them as small Pynux functions: the first pointer
# arg arrives in %rdi, so the asm just references (%rdi).
#
# Two kthreads each call pynux_atomic_inc 1000 times on a shared
# counter. Without `lock`, races would lose increments; with `lock`,
# the final count is exactly 2000.

extern def kthread_create_on_node(threadfn: Ptr[uint8], data: Ptr[uint8],
                                  node: int32, name: Ptr[char]) -> Ptr[uint8]
extern def wake_up_process(task: Ptr[uint8]) -> int32
extern def kthread_stop(task: Ptr[uint8]) -> int32
extern def __init_swait_queue_head(q: Ptr[uint8], name: Ptr[char],
                                   key: Ptr[uint8])
extern def complete(c: Ptr[uint8])
extern def wait_for_completion_timeout(c: Ptr[uint8], timeout: uint64) -> uint64
extern def _printk(fmt: str, val: int32) -> int32


NUMA_NO_NODE_VAL: int32 = -1
HZ_VAL: uint64 = 1000

# Shared counter (4 bytes, 32-bit atomic).
pynux_atomic: int32

# Two completions so cleanup_module knows both threads finished.
pynux_done_a: Array[32, uint8]
pynux_done_b: Array[32, uint8]
pynux_dk_a: Array[32, uint8]
pynux_dk_b: Array[32, uint8]


def pynux_atomic_inc(addr: Ptr[uint8]):
    # addr in %rdi per SysV-AMD64. `lock incl` atomically increments the
    # 32-bit value at [addr] — interlocked across CPUs.
    asm_volatile("lock incl (%rdi)")


def pynux_worker_a(data: Ptr[uint8]) -> int32:
    i: int32 = 0
    while i < 1000:
        pynux_atomic_inc(&pynux_atomic)
        i = i + 1
    complete(&pynux_done_a)
    # Idle until kthread_stop arrives (avoids the auto-exit / kthread_stop
    # race seen in M4.3a).
    return 0


def pynux_worker_b(data: Ptr[uint8]) -> int32:
    i: int32 = 0
    while i < 1000:
        pynux_atomic_inc(&pynux_atomic)
        i = i + 1
    complete(&pynux_done_b)
    return 0


def init_module() -> int32:
    __init_swait_queue_head(&pynux_done_a + 8, "pynux-a", &pynux_dk_a)
    __init_swait_queue_head(&pynux_done_b + 8, "pynux-b", &pynux_dk_b)

    kt_a: Ptr[uint8] = kthread_create_on_node(pynux_worker_a, 0,
                                              NUMA_NO_NODE_VAL, "pynux-atom-a")
    kt_b: Ptr[uint8] = kthread_create_on_node(pynux_worker_b, 0,
                                              NUMA_NO_NODE_VAL, "pynux-atom-b")
    if kt_a == 0:
        return -12
    if kt_b == 0:
        return -12
    wake_up_process(kt_a)
    wake_up_process(kt_b)

    # Wait up to a second for each.
    wait_for_completion_timeout(&pynux_done_a, HZ_VAL)
    wait_for_completion_timeout(&pynux_done_b, HZ_VAL)
    _printk("[ATOM] counter = %d\n", pynux_atomic)
    return 0


def cleanup_module():
    _printk("[ATOM] unregistered\n", 0)
