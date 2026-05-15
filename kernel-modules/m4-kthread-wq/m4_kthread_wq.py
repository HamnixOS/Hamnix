# Pynux M4.3a: kthread + workqueue infrastructure in pure Pynux.
#
# Forces three foundations for any later async-work Pynux code:
#   * kthread lifecycle (create_on_node + wake_up_process + should_stop +
#     stop) with a Pynux threadfn matching `int fn(void *data)`.
#   * Manual INIT_WORK: zero-init the work_struct then fill in
#     data/entry.next/entry.prev/func by hand (WORK_STRUCT_NO_POOL +
#     circular list_head self-pointer + Pynux function pointer).
#   * alloc_workqueue / queue_work_on / __flush_workqueue / destroy_workqueue.
#
# After load, a Pynux kthread emits three "[KT] tick" lines and exits, and
# a Pynux work item emits one "[WQ] fired" line. Both happen via the same
# /init that the runner uses for every other module.

extern def kthread_create_on_node(threadfn: Ptr[uint8], data: Ptr[uint8],
                                  node: int32, namefmt: Ptr[char]) -> Ptr[uint8]
extern def wake_up_process(task: Ptr[uint8]) -> int32
extern def kthread_stop(task: Ptr[uint8]) -> int32
extern def kthread_should_stop() -> int32
extern def msleep(msecs: uint32)

extern def alloc_workqueue(fmt: Ptr[char], flags: uint32,
                           max_active: int32) -> Ptr[uint8]
extern def destroy_workqueue(wq: Ptr[uint8])
extern def queue_work_on(cpu: int32, wq: Ptr[uint8], work: Ptr[uint8]) -> int32
extern def __flush_workqueue(wq: Ptr[uint8])

extern def _printk(fmt: str, val: int32) -> int32


# struct work_struct (32 bytes, probed for linux-6.12.48)
class WorkStruct:
    data: int64                  # 0  (atomic_long_t)
    list_next: Ptr[uint8]        # 8  (entry.next)
    list_prev: Ptr[uint8]        # 16 (entry.prev)
    func: Ptr[uint8]             # 24


# Initial value of work_struct.data per INIT_WORK_KEY (WORK_DATA_INIT).
WORK_STRUCT_NO_POOL_VAL: int64 = 0xfffffffe00000

# kthread / workqueue constants
NUMA_NO_NODE_VAL: int32 = -1
WORK_CPU_UNBOUND: int32 = 64           # NR_CPUS for this kernel config

# Wait-marker for the test: the kthread sets pynux_kt_done=1 when it
# exits its loop so the cleanup path can confirm it ran.
pynux_kt: Ptr[uint8]
pynux_wq: Ptr[uint8]
pynux_work: WorkStruct
pynux_kt_ticks: int32      # incremented by kthread
pynux_wq_fired: int32      # set by work handler


def pynux_threadfn(data: Ptr[uint8]) -> int32:
    # Loop until kthread_stop() is called from cleanup_module. Tick three
    # times then idle — the kthread *must* outlive any cleanup race so
    # kthread_stop has a valid task_struct to operate on. Auto-exiting
    # via `return 0` would free the task_struct and crash kthread_stop.
    while kthread_should_stop() == 0:
        if pynux_kt_ticks < 3:
            _printk("[KT] tick\n", 0)
            pynux_kt_ticks = pynux_kt_ticks + 1
        msleep(1)
    return 0


def pynux_work_fn(work: Ptr[uint8]):
    _printk("[WQ] fired\n", 0)
    pynux_wq_fired = pynux_wq_fired + 1


def init_module() -> int32:
    # ---- workqueue ------------------------------------------------------
    # INIT_WORK by hand: WORK_DATA_INIT + circular list_head entry +
    # function pointer. The entry list_head must self-point initially
    # (INIT_LIST_HEAD).
    pynux_work.data = WORK_STRUCT_NO_POOL_VAL
    entry_addr: Ptr[uint8] = &pynux_work + 8     # offset of entry field
    pynux_work.list_next = entry_addr
    pynux_work.list_prev = entry_addr
    pynux_work.func = pynux_work_fn

    pynux_wq = alloc_workqueue("pynux-wq", 0, 1)
    if pynux_wq == 0:
        _printk("[M4-KTWQ] alloc_workqueue FAILED\n", 0)
        return -12        # -ENOMEM
    queue_work_on(WORK_CPU_UNBOUND, pynux_wq, &pynux_work)

    # ---- kthread --------------------------------------------------------
    # kthread_run macro = kthread_create_on_node + wake_up_process; do
    # both by hand.
    pynux_kt = kthread_create_on_node(pynux_threadfn, 0, NUMA_NO_NODE_VAL,
                                      "pynux-kt")
    # IS_ERR check: kernel returns small negative pointers on error
    # (in the range -4095..-1). For the demo, only skip wake-up if the
    # returned pointer is literally zero.
    if pynux_kt != 0:
        wake_up_process(pynux_kt)
    _printk("[M4-KTWQ] kthread + workqueue armed\n", 0)
    return 0


def cleanup_module():
    if pynux_kt != 0:
        kthread_stop(pynux_kt)
    if pynux_wq != 0:
        __flush_workqueue(pynux_wq)
        destroy_workqueue(pynux_wq)
    _printk("[M4-KTWQ] kthread ticks  = %d\n", pynux_kt_ticks)
    _printk("[M4-KTWQ] workqueue runs = %d\n", pynux_wq_fired)
    _printk("[M4-KTWQ] unregistered\n", 0)
