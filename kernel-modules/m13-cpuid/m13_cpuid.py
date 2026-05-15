# Pynux M13.2: read the current CPU number from `%gs:pcpu_hot+12`.
#
# In x86-64 Linux, struct pcpu_hot starts with:
#   struct task_struct *current_task;   // bytes 0..8
#   int preempt_count;                  // bytes 8..12
#   int cpu_number;                     // bytes 12..16
# The per-CPU area is addressed via %gs, so reading the CPU id is a
# single 32-bit segment-prefixed load.

extern def _printk(fmt: str, val: int32) -> int32


def get_cpu_id() -> int32:
    # movl is 32-bit; the implicit zero-extend to %rax makes the
    # function's return value clean.
    asm_volatile("movl %gs:pcpu_hot+12, %eax")


def init_module() -> int32:
    cpu: int32 = get_cpu_id()
    _printk("[CPUID] running on CPU %d\n", cpu)
    return 0


def cleanup_module():
    _printk("[CPUID] unregistered\n", 0)
