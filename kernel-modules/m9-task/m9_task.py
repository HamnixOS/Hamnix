# Pynux M9.1: task introspection via `current`.
#
# Reads the per-CPU current_task pointer through `%gs:current_task`,
# then prints the running task's pid (offset 1352) and comm (offset
# 1840, 16-byte char array). Demonstrates Pynux can introspect arbitrary
# kernel data structures via x86 segment-register addressing.

extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def _printk(fmt: str, val: int32) -> int32


# task_struct offsets, probed for 6.12.48 (full task_struct is ~7500
# bytes; we only need pid and comm).
TASK_PID_OFF:  int32 = 1352
TASK_COMM_OFF: int32 = 1840


def get_current() -> Ptr[uint8]:
    # current is read as `%gs:pcpu_hot` — pcpu_hot is the exported
    # per-CPU struct whose first field is current_task. The kernel's
    # `current` macro expands to this_cpu_read_stable(pcpu_hot.current_task)
    # which is exactly this single instruction. Result in %rax;
    # function epilogue preserves it as the return value.
    asm_volatile("movq %gs:pcpu_hot, %rax")


def init_module() -> int32:
    cur: Ptr[uint8] = get_current()
    pid: int32 = 0
    memcpy(&pid, cur + TASK_PID_OFF, 4)

    comm: Array[20, uint8]
    memcpy(&comm, cur + TASK_COMM_OFF, 16)

    _printk("[TASK] init_module pid = %d\n", pid)
    # Print first 5 bytes of comm as integers (will spell out the chars
    # of "insmod" for the loading process).
    b0: int32 = 0
    memcpy(&b0, &comm, 1)
    b1: int32 = 0
    memcpy(&b1, &comm + 1, 1)
    b2: int32 = 0
    memcpy(&b2, &comm + 2, 1)
    b3: int32 = 0
    memcpy(&b3, &comm + 3, 1)
    b4: int32 = 0
    memcpy(&b4, &comm + 4, 1)
    b5: int32 = 0
    memcpy(&b5, &comm + 5, 1)
    _printk("[TASK] comm[0] = %d\n", b0)   # 'i' = 105
    _printk("[TASK] comm[1] = %d\n", b1)   # 'n' = 110
    _printk("[TASK] comm[2] = %d\n", b2)   # 's' = 115
    _printk("[TASK] comm[3] = %d\n", b3)   # 'm' = 109
    _printk("[TASK] comm[4] = %d\n", b4)   # 'o' = 111
    _printk("[TASK] comm[5] = %d\n", b5)   # 'd' = 100
    return 0


def cleanup_module():
    _printk("[TASK] unregistered\n", 0)
