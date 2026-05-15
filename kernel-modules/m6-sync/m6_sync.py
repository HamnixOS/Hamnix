# Pynux M6.3: mutex + completion sync primitives.
#
# Spawns a Pynux kthread that:
#   1. mutex_lock()s the shared lock
#   2. increments a counter by 42
#   3. mutex_unlock()s
#   4. complete()s the one-shot completion
#
# init_module then waits on wait_for_completion_timeout(1 second) so the
# kthread's work is observably synchronized: by the time the wait
# returns, the counter has been updated. The whole thing returns
# cleanly via kthread auto-exit.

extern def __mutex_init(lock: Ptr[uint8], name: Ptr[char], key: Ptr[uint8])
extern def mutex_lock(lock: Ptr[uint8])
extern def mutex_unlock(lock: Ptr[uint8])
extern def __init_swait_queue_head(q: Ptr[uint8], name: Ptr[char],
                                   key: Ptr[uint8])
extern def complete(c: Ptr[uint8])
extern def wait_for_completion_timeout(c: Ptr[uint8], timeout: uint64) -> uint64
extern def kthread_create_on_node(threadfn: Ptr[uint8], data: Ptr[uint8],
                                  node: int32, name: Ptr[char]) -> Ptr[uint8]
extern def wake_up_process(task: Ptr[uint8]) -> int32
extern def _printk(fmt: str, val: int32) -> int32


# struct mutex (32 bytes) and struct completion (32 bytes) both zero-init
# safe for the lock + done fields. The swait_queue_head inside completion
# does need its task_list self-initialized — that's why we call
# __init_swait_queue_head separately at offset 8.
COMPL_WAIT_OFFSET: int32 = 8     # offsetof(struct completion, wait)
NUMA_NO_NODE_VAL:  int32 = -1
HZ_VAL:            uint64 = 1000  # CONFIG_HZ=1000; 1000 jiffies = 1 second


pynux_mutex:    Array[32, uint8]
pynux_compl:    Array[32, uint8]
pynux_mlk_key:  Array[32, uint8]
pynux_clk_key:  Array[32, uint8]
pynux_counter:  int32


def pynux_worker(data: Ptr[uint8]) -> int32:
    _printk("[SYNC] worker: locking\n", 0)
    mutex_lock(&pynux_mutex)
    pynux_counter = pynux_counter + 42
    mutex_unlock(&pynux_mutex)
    _printk("[SYNC] worker: signaling completion\n", 0)
    complete(&pynux_compl)
    return 0


def init_module() -> int32:
    __mutex_init(&pynux_mutex, "pynux-mtx", &pynux_mlk_key)
    # init_completion: done=0 already (.bss); init the embedded swait wait queue.
    __init_swait_queue_head(&pynux_compl + COMPL_WAIT_OFFSET,
                            "pynux-cmpl", &pynux_clk_key)

    kt: Ptr[uint8] = kthread_create_on_node(pynux_worker, 0,
                                            NUMA_NO_NODE_VAL, "pynux-sync")
    if kt == 0:
        _printk("[SYNC] kthread_create FAILED\n", 0)
        return -12
    wake_up_process(kt)

    remaining: uint64 = wait_for_completion_timeout(&pynux_compl, HZ_VAL)
    if remaining == 0:
        _printk("[SYNC] TIMED OUT waiting for worker\n", 0)
        return -110
    _printk("[SYNC] completion received\n", 0)
    _printk("[SYNC] counter under mutex = %d\n", pynux_counter)
    return 0


def cleanup_module():
    _printk("[SYNC] unregistered\n", 0)
