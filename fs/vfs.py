# fs/vfs.py
#
# Mirrors fs/open.c + fs/read_write.c + fs/namei.c at minimum scope.
# As of M16.26 the fd table is PER-TASK (lives inline in task_struct's
# fd_idx[4] / fd_pos[4] arrays); reads come out of the baked-in
# initramfs (M16.21); writes route to the early-console UART for
# stdout/stderr, since the initramfs itself is read-only.
#
# Special fd_idx markers (from kernel/sched/core.py):
#   FD_CLOSED_MARK = 0xFFFFFFFF       slot is free
#   FD_STDIN_MARK  = 0xFFFFFFFC       reads return EOF (no input source yet)
#   FD_STDOUT_MARK = 0xFFFFFFFE       writes route to serial
#   FD_STDERR_MARK = 0xFFFFFFFD       writes route to serial
# Anything below 0xFFFFFFF0 is a real initramfs file index.
#
# Linux semantics we keep:
#   SEEK_SET / SEEK_CUR / SEEK_END
#   read/write/lseek return -errno on failure (we use small negative
#   ints; no real errno space yet)
#   close on an already-closed fd returns -EBADF (-9)

from drivers.tty.serial.early_8250 import early_putc
from kernel.printk.printk import printk0, printk1, printk2
from kernel.sched.core import (
    TaskStruct, current_task,
    FD_CLOSED_MARK, FD_STDIN_MARK, FD_STDOUT_MARK, FD_STDERR_MARK,
)
from fs.cpio import (
    cpio_init,
    initramfs_entry_count, initramfs_entry_name,
    initramfs_entry_data, initramfs_entry_size,
)

extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]

NR_FDS: uint32 = 4

# Errno constants (small negative; matches Linux's signs).
ENOENT: int32 = -2
EBADF:  int32 = -9
EINVAL: int32 = -22
EMFILE: int32 = -24
EROFS:  int32 = -30

# lseek whence
SEEK_SET: int32 = 0
SEEK_CUR: int32 = 1
SEEK_END: int32 = 2


def vfs_init():
    # Per-task fd tables are initialised in create_user_task /
    # kthread_create. The only filesystem-side work is parsing the
    # embedded cpio archive into the in-memory file_table that the
    # initramfs_entry_* accessors consult.
    cpio_init()


def _strcmp_cstr(a: Ptr[char], b: Ptr[char]) -> int32:
    i: int32 = 0
    while True:
        ca: int32 = a[i]
        cb: int32 = b[i]
        if ca != cb:
            return 1
        if ca == 0:
            return 0
        i = i + 1


def _lookup_name(name: Ptr[char]) -> int32:
    count: uint64 = initramfs_entry_count()
    i: uint64 = 0
    while i < count:
        candidate: Ptr[char] = initramfs_entry_name(i)
        if _strcmp_cstr(name, candidate) == 0:
            return cast[int32](i)
        i = i + 1
    return -1


def _alloc_fd(task: Ptr[TaskStruct]) -> int32:
    i: uint64 = 0
    while i < cast[uint64](NR_FDS):
        if task[0].fd_idx[i] == FD_CLOSED_MARK:
            return cast[int32](i)
        i = i + 1
    return -1


def vfs_open(name: Ptr[char]) -> int32:
    file_idx: int32 = _lookup_name(name)
    if file_idx < 0:
        return ENOENT
    task: Ptr[TaskStruct] = current_task()
    fd: int32 = _alloc_fd(task)
    if fd < 0:
        return EMFILE
    fdu: uint64 = cast[uint64](fd)
    task[0].fd_idx[fdu] = cast[uint32](file_idx)
    task[0].fd_pos[fdu] = 0
    return fd


def _check_fd(fd: int32) -> int32:
    if fd < 0 or cast[uint32](fd) >= NR_FDS:
        return EBADF
    return 0


def vfs_read(fd: int32, buf: Ptr[uint8], count: uint64) -> int64:
    rc: int32 = _check_fd(fd)
    if rc != 0:
        return cast[int64](rc)
    task: Ptr[TaskStruct] = current_task()
    fdu: uint64 = cast[uint64](fd)
    file_idx: uint32 = task[0].fd_idx[fdu]

    if file_idx == FD_CLOSED_MARK:
        return cast[int64](EBADF)
    if file_idx == FD_STDIN_MARK:
        return 0                            # always EOF for now
    if file_idx == FD_STDOUT_MARK or file_idx == FD_STDERR_MARK:
        return cast[int64](EBADF)           # can't read these

    # initramfs file
    size: uint64 = initramfs_entry_size(cast[uint64](file_idx))
    pos:  uint64 = task[0].fd_pos[fdu]
    if pos >= size:
        return 0
    remaining: uint64 = size - pos
    take: uint64 = count
    if take > remaining:
        take = remaining
    src: Ptr[uint8] = initramfs_entry_data(cast[uint64](file_idx))
    memcpy(buf, cast[Ptr[uint8]](cast[uint64](src) + pos), take)
    task[0].fd_pos[fdu] = pos + take
    return cast[int64](take)


def vfs_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64:
    rc: int32 = _check_fd(fd)
    if rc != 0:
        return cast[int64](rc)
    task: Ptr[TaskStruct] = current_task()
    fdu: uint64 = cast[uint64](fd)
    file_idx: uint32 = task[0].fd_idx[fdu]

    if file_idx == FD_CLOSED_MARK:
        return cast[int64](EBADF)
    if file_idx == FD_STDOUT_MARK or file_idx == FD_STDERR_MARK:
        # Route every byte to the early UART. No buffering, no
        # newline translation. Matches Linux's writeable terminal
        # in raw mode well enough for the smoke test.
        i: uint64 = 0
        while i < count:
            early_putc(cast[int32](buf[i]))
            i = i + 1
        return cast[int64](count)
    if file_idx == FD_STDIN_MARK:
        return cast[int64](EBADF)

    # initramfs is read-only.
    return cast[int64](EROFS)


def vfs_close(fd: int32) -> int32:
    rc: int32 = _check_fd(fd)
    if rc != 0:
        return rc
    task: Ptr[TaskStruct] = current_task()
    fdu: uint64 = cast[uint64](fd)
    if task[0].fd_idx[fdu] == FD_CLOSED_MARK:
        return EBADF
    # Standard streams are normally closable; we permit it but it
    # doesn't actually shut the serial port down.
    task[0].fd_idx[fdu] = FD_CLOSED_MARK
    task[0].fd_pos[fdu] = 0
    return 0


def vfs_lseek(fd: int32, offset: int64, whence: int32) -> int64:
    rc: int32 = _check_fd(fd)
    if rc != 0:
        return cast[int64](rc)
    task: Ptr[TaskStruct] = current_task()
    fdu: uint64 = cast[uint64](fd)
    file_idx: uint32 = task[0].fd_idx[fdu]
    if file_idx == FD_CLOSED_MARK:
        return cast[int64](EBADF)
    if file_idx == FD_STDIN_MARK or file_idx == FD_STDOUT_MARK \
            or file_idx == FD_STDERR_MARK:
        # Linux returns ESPIPE for seek on a pipe / tty; we don't
        # distinguish that errno yet, just say EINVAL.
        return cast[int64](EINVAL)

    size: uint64 = initramfs_entry_size(cast[uint64](file_idx))
    new_pos: int64 = 0
    if whence == SEEK_SET:
        new_pos = offset
    elif whence == SEEK_CUR:
        new_pos = cast[int64](task[0].fd_pos[fdu]) + offset
    elif whence == SEEK_END:
        new_pos = cast[int64](size) + offset
    else:
        return cast[int64](EINVAL)

    if new_pos < 0:
        return cast[int64](EINVAL)
    task[0].fd_pos[fdu] = cast[uint64](new_pos)
    return new_pos
