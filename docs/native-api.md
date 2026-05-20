# Hamnix native syscall API (Layer 1)

Plan 9-shaped, file-and-namespace-centric. ~25 calls. Linux ELF
binaries and `.ko` modules don't see this — they see `linux_abi/`
(Layer 2), which translates their calls into the operations below.

## Conventions

- **Return shape.** Success returns a non-negative integer (fd,
  byte count, pid, 0). Failure returns -1; the per-process error
  string is read with `errstr(buf, n)`. **No `errno` globals.** This
  matches 9front `intro(2)`.
- **Paths.** Always interpreted in the **calling process's
  namespace**. Two siblings can have different views of `/dev/win`
  if one called `bind` and the other did not.
- **Encoding.** Paths are UTF-8 bytes, NUL-terminated. Lengths in
  ABI are bytes, not codepoints.
- **String parameters** are `Ptr[uint8]` to NUL-terminated bytes
  unless paired with an explicit length argument (`read`/`write`).
- **Numbers.** Existing numeric assignments 0..22 stay where they
  are during Phases A..D of the migration plan. New Plan 9
  primitives take numbers in 256..280 (well clear of the existing
  block and well clear of Linux ABI's high-number range used by
  `SYS_init_module=175`/`SYS_delete_module=176`).

## Open flags (canonical Plan 9 set)

```
OREAD    0    open for read
OWRITE   1    open for write
ORDWR    2    open for read+write
OEXEC    3    open exec (currently == OREAD)
OTRUNC   16   truncate on open
ORCLOSE  64   remove on close
OCEXEC   32   close on exec
OAPPEND  128  append-only writes
```

Linux's `O_NONBLOCK`, `O_CLOEXEC` and friends are translated by
Layer 2. They do NOT appear at Layer 1.

## Error strings

A per-process buffer (page-backed in the TaskStruct) holds the most
recent error text. Syscalls overwrite it on failure. `errstr` reads
it into the caller's buffer. There is no error number. Reference:
9front `/sys/src/9/port/error.c`.

## File operations

### `open(path: Ptr[uint8], flags: int32) -> int32`

**Number 5.** Open `path` in the calling process's namespace with
`flags` (combo of OREAD/OWRITE/ORDWR plus modifiers above). Returns
new fd or -1.

### `create(path: Ptr[uint8], flags: int32, mode: uint32) -> int32`

**New, number 260.** Atomically create-or-truncate `path` and open
for I/O. `mode` is Plan 9 permission bits: low 9 are rwxrwxrwx;
high bits include `DMDIR=0x80000000` (create as directory),
`DMAPPEND=0x40000000` (append-only), `DMEXCL=0x20000000` (exclusive
use). Returns fd or -1. **Plan 9 distinguishes create from open;
we follow.** Trying to `open` a non-existent path fails — Hamnix
does NOT honour Linux's `O_CREAT` at Layer 1; Layer 2 translates.
Reference: 9front `/sys/src/9/port/sysfile.c::syscreate`.

### `read(fd: int32, buf: Ptr[uint8], count: uint64) -> int64`

**Number 6.** Read up to `count` bytes from current offset. Returns
bytes read (0 = EOF on regular files) or -1. Directory fds yield
fixed-size `Dir` records — see "Directory format" below.

### `write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64`

**Number 8.** Write `count` bytes at current offset. Returns bytes
written or -1. Short writes are possible.

### `seek(fd: int32, off: int64, whence: int32) -> int64`

**Number 9.** Reposition the fd's offset. `whence` is 0=SET,
1=CUR, 2=END. Returns new absolute offset or -1.

### `close(fd: int32) -> int32`

**Number 7.** Drop the fd. Returns 0 or -1. Resources are released
when the last reference (across `dup`s and shared-fd-table
processes) goes away. Reference: 9front
`/sys/src/9/port/sysfile.c::sysclose`.

### `stat(path: Ptr[uint8], buf: Ptr[uint8], nbuf: uint64) -> int32`

**New, number 261.** Fill `buf` with a serialised `Dir` record
describing `path`. `nbuf` is the buffer size; if too small,
returns -1 and errstr says how much is needed. Reference: 9front
`/sys/src/9/port/sysfile.c::sysstat`.

### `fstat(fd: int32, buf: Ptr[uint8], nbuf: uint64) -> int32`

**New, number 262.** Same as `stat` but on an open fd.

### `dup(oldfd: int32, newfd: int32) -> int32`

**Number 16 / 17.** Duplicate `oldfd`. If `newfd == -1`, allocate
the lowest free fd. Otherwise close `newfd` (if open) and reuse
that number. Returns the new fd or -1. Replaces both legacy
`SYS_DUP` and `SYS_DUP2` with one call. Reference: 9front
`/sys/src/9/port/sysfile.c::sysdup`.

### `pipe(fds: Ptr[int32]) -> int32`

**Number 14.** Create a bidirectional pipe. `fds[0]` and `fds[1]`
end up as both readable and writable (Plan 9 idiom). Returns 0 or
-1. Reference: 9front `/sys/src/9/port/sysfile.c::syspipe`.

### `remove(path: Ptr[uint8]) -> int32`

**New, number 263.** Remove `path`. Reference: 9front
`/sys/src/9/port/sysfile.c::sysremove`. Replaces `SYS_UNLINK`.

### `fd2path(fd: int32, buf: Ptr[uint8], nbuf: uint64) -> int32`

**New, number 264.** Write the path that `fd` was opened by into
`buf`. The result is namespace-relative — what the calling process
called the file. Reference: 9front `/sys/src/9/port/sysfile.c::sysfd2path`.

## Directory format

`read` on a directory returns a sequence of fixed-layout records
mirroring 9P's `stat` message:

```
size[2]                    record length minus the 2 size bytes
type[2]   dev[4]           device-specific identifiers
qid.type[1] qid.vers[4] qid.path[8]   unique inode identity
mode[4]    atime[4] mtime[4] length[8]
name[s]    uid[s] gid[s] muid[s]      counted strings: 2 length + UTF-8
```

`s` strings are `length[2]` followed by UTF-8 bytes (no NUL). A
listdir loop is `for each record in read(dirfd)`. Reference: 9front
`stat(5)`.

This replaces the existing `SYS_LISTDIR` (which returned a custom
flat format).

## Process control

### `rfork(flags: int32) -> int32`

**New, number 256.** Single primitive for both fork and thread
creation. Returns child pid in parent, 0 in child, -1 on error.

Flag bits (combine with `|`):

| Bit | Name | Meaning |
|----:|------|---------|
| 0x001 | `RFPROC` | Create a new process. Without this, only the rest of the flags' effects apply to the **current** process (e.g. `rfork(RFNAMEG)` privatises the namespace in place). |
| 0x002 | `RFMEM` | Share the parent's address space (POSIX thread). Default: copy on write. |
| 0x004 | `RFFDG` | Copy the fd table (default). Clear bit to share. |
| 0x008 | `RFNAMEG` | Copy the namespace (default). Clear bit to share. |
| 0x010 | `RFENVG` | Copy environment (default). Clear bit to share. |
| 0x020 | `RFNOTEG` | Start a new note group. |
| 0x040 | `RFCFDG` | Close all fds in the child (forbids carrying any). |
| 0x080 | `RFCNAMEG` | Start the child with an empty namespace. |
| 0x100 | `RFNOWAIT` | Detach the child — parent never reaps. |
| 0x200 | `RFREND` | Child has its own rendezvous group (Plan 9 IPC). Hamnix reserves; not implemented in Phase C. |

Reference: 9front `/sys/src/9/port/sysproc.c::sysrfork`, `rfork(2)`.

Idioms:
- **POSIX fork:** `rfork(RFPROC|RFFDG|RFNAMEG|RFENVG)`
- **POSIX thread:** `rfork(RFPROC|RFMEM)` (shares fd table, namespace, environment)
- **Just privatise namespace in current process:** `rfork(RFNAMEG)`

### `exec(path: Ptr[uint8], argv: Ptr[Ptr[uint8]], envp: Ptr[Ptr[uint8]]) -> int32`

**Number 10.** Replace the current image with the ELF at `path`.
`argv` and `envp` are NULL-terminated arrays of NUL-terminated
strings. On success does not return. On error returns -1.
Reference: 9front `/sys/src/9/port/sysproc.c::sysexec`.

### `wait(status_ptr: Ptr[int32]) -> int32`

**Number 12.** Block until any child exits. Writes the exit code
(low 8 bits) and signal cause (next bits) into `*status_ptr`.
Returns reaped pid or -1. Plan 9's `await` returns a printable
string; we keep a simpler integer status to ease Layer 2
translation. Reference: 9front `/sys/src/9/port/sysproc.c::syswait`.

### `exits(msg: Ptr[uint8]) -> noreturn`

**Number 1.** Terminate the calling process. `msg` is a NUL-
terminated string (NULL = clean exit). Mapped from Linux's integer
exit code as `"" / NULL` for 0, `"signal: <num>"` for signal
deaths, `"<num>"` otherwise. The string is what the parent's
`wait` sees encoded into `status_ptr`. Reference: 9front
`/sys/src/9/port/sysproc.c::sys_exits`.

### `getpid() -> int32`

**Number 4.** Return the calling process's pid. Convenience
wrapper; equivalent to reading `/dev/pid`. Kept as a syscall so
Layer 2 doesn't have to open a file per Linux `getpid()`.

## Namespace operations

### `bind(new: Ptr[uint8], old: Ptr[uint8], flag: int32) -> int32`

**New, number 257.** Graft `new` onto `old` in the calling
process's namespace. After `bind("/proc/self/fd", "/fd", MREPL)`,
opens of `/fd/0` find `/proc/self/fd/0`.

`flag`:

| Bit | Name | Meaning |
|----:|------|---------|
| 0x000 | `MREPL` | Replace any binding at `old`. |
| 0x001 | `MBEFORE` | Union mount — search `new` first. |
| 0x002 | `MAFTER` | Union mount — search `new` last. |
| 0x004 | `MCREATE` | Allow create operations to land on this branch. |
| 0x008 | `MCACHE` | Cache reads (rarely used). |

`bind` does NOT cross process boundaries. Children inherit the
namespace by default (`rfork` without `RFNAMEG` shares; with
`RFNAMEG` copies). Reference: 9front `/sys/src/9/port/chan.c`,
`bind(2)`.

### `mount(srvfd: int32, afd: int32, old: Ptr[uint8], flag: int32, spec: Ptr[uint8]) -> int32`

**New, number 258.** Attach a 9P file server (speaking over
`srvfd`) at path `old`. `afd` is the auth channel from a prior
`fauth` call, or -1 to skip auth. `spec` is a server-specific
attach string (e.g. "main" for many servers). `flag` shares
MREPL/MBEFORE/MAFTER/MCREATE with `bind`. Reference: 9front
`/sys/src/9/port/chan.c`, `mount(2)`.

The canonical pattern for service consumers:

```
fd = open("/srv/rio", ORDWR)
mount(fd, -1, "/dev/win", MREPL, "")
close(fd)
# /dev/win/* is now backed by the rio daemon
```

### `unmount(new: Ptr[uint8], old: Ptr[uint8]) -> int32`

**New, number 259.** Remove a binding. `new == NULL` unbinds
everything at `old`; otherwise removes the specific `new->old`
edge from a union mount.

### `srv_post(name: Ptr[uint8], srvfd: int32) -> int32`

**New, number 275.** Publish `srvfd` into the kernel's `srv` table
under `name`. After a successful call, any task can `srv_open(name)`
to obtain its own fd referring to the same underlying file/pipe.

Rules for `name`:

- 1..32 bytes including the NUL terminator.
- Printable ASCII only (32 < byte < 127); no control chars.
- No `/` — `name` is a single leaf component, not a path.
- No leading `.` (reserved for future directory semantics).
- Must not collide with an existing entry; the 16-slot table must
  have room.

Failure modes (return -1, errstr set):

| errstr                              | meaning                                   |
|-------------------------------------|-------------------------------------------|
| `srv: bad name`                     | validation rule above failed              |
| `srv: bad fd`                       | `srvfd` is closed or out of range         |
| `srv: name in use or table full`    | collision OR all 16 slots posted          |

The caller retains ownership of `srvfd` — `srv_post` does NOT close
it on success and does NOT refcount the underlying file/pipe. If
the poster closes its `srvfd` before any consumer calls `srv_open`,
the entry stays in the name table but lookups fail with
`srv: not posted` because the kernel detects the now-closed source
slot. Phase D follow-up will refcount the underlying object so
`srv_post` survives the poster's `close`.

### `srv_open(name: Ptr[uint8]) -> int32`

**New, number 276.** Look up `name` in the kernel `srv` table and
dup the poster's underlying file/pipe into the calling task's fd
table. Returns the new fd or -1.

Implementation detail (for those debugging cross-task fd flow): the
kernel records the poster's task-table slot index at `srv_post`
time, and `srv_open` calls `copy_fd_entry` from the poster's
TaskStruct into the caller's. Pipe refcounts are bumped — the
opener's fd survives the poster's `close`.

Failure modes (return -1, errstr set):

| errstr                | meaning                                                |
|-----------------------|--------------------------------------------------------|
| `srv: bad name`       | validation rule above failed                            |
| `srv: not posted`     | no entry under `name`, or poster's fd has been closed  |
| `srv: kernel-only`    | entry was posted from kernel space (no source task)    |
| `srv: poster gone`    | poster's task slot is invalid                          |
| `srv: dup failed`     | caller is out of fd slots, or copy_fd_entry failed     |

Canonical service-consumer pattern (mirrors the `mount` example
above; the `open("/srv/<name>")` form also works once `init` has
done its `bind '#s' /srv` recipe, but `srv_open` is direct):

```
fd = srv_open("rio")
mount(fd, -1, "/dev/win", MREPL, "")
close(fd)
# /dev/win/* is now backed by rio
```

### `chdir(path: Ptr[uint8]) -> int32`

**Number 19.** Change working directory.

## Errors and signals

### `errstr(buf: Ptr[uint8], nbuf: uint64) -> int32`

**New, number 265.** Read the per-process most-recent error
string into `buf` (truncated to `nbuf` bytes, NUL-padded). Returns
0 on success. Writing the buffer back (with a non-zero first
byte) installs that string as the current error — useful for
libraries that want to layer their own message.

### Notes (Plan 9 signals)

Plan 9 calls signals "notes". Each process has a per-process
note-handler registered via `notify(handler_ptr)` (sysnumber 270,
not in Phase C scope). Other processes post notes by writing to
`/proc/<pid>/note`:

```
fd = open("/proc/42/note", OWRITE)
write(fd, "interrupt", 9)   # equivalent to Linux SIGINT
close(fd)
```

Layer 2 maps Linux signal numbers to Plan 9 note strings.

## Reserved well-known paths

The native API expects these paths to mean specific things. A 9P
server posting at one of them MUST honour the documented file
shape.

| Path | Operation | Contents |
|------|-----------|----------|
| `/dev/cons` | r/w | Controlling console. Writes go to printk + serial + framebuffer; reads return keyboard input. |
| `/dev/null` | r/w | Discards writes; returns EOF on read. |
| `/dev/zero` | r/w | Discards writes; returns NUL bytes on read. |
| `/dev/time` | r | ASCII decimal: nanoseconds since boot, newline-terminated. |
| `/dev/random` | r | CSPRNG bytes. |
| `/dev/pid` | r | ASCII decimal: calling process's pid. |
| `/dev/eth<n>` | r/w | Raw ethernet frames for NIC `n`. Owned by `ipd`. |
| `/dev/mouse` | r/w | Per-window mouse events; write repositions cursor. Served by `rio` (see `rio.md`). |
| `/dev/draw/new` | r/w | Allocate a draw context; read lists open ids. Served by `rio`. |
| `/dev/draw/<id>/{data,ctl,refresh}` | r/w | Per-context draw protocol, control, and repaint wait. Served by `rio`. |
| `/dev/wctl` | r/w | Per-window control (resize/move/raise). Served by `rio`. |
| `/dev/wsys` | r/w | System-wide window control; write spawns a window. Served by `rio`. |
| `/net/tcp/clone` | r/w | Open then read to get a new TCP connection number; further I/O on the per-conn `/net/tcp/<n>/{ctl,data,local,remote,status}`. Plan 9 idiom. |
| `/net/udp/*` | r/w | Same shape, UDP. |
| `/proc/<pid>/cwd` | r | Read returns the process's current working directory string. |
| `/proc/<pid>/note` | w | Write a note string to deliver a signal. |
| `/proc/<pid>/ns` | r | Read returns the process's namespace as text. |
| `/proc/<pid>/status` | r | Read returns one-line status (pid name state). |
| `/srv/<name>` | r/w | Named 9P channel. A server `posts` a `srvfd` here; consumers `open` and pass to `mount`. |

## Filesystem-service shape

Every service exposes a directory:

```
/<service>/ctl        # write commands, read recent log
/<service>/data       # bulk stream
/<service>/status     # read-only state
/<service>/<id>/ctl   # per-instance control
/<service>/<id>/data  # per-instance data
```

`ctl` files take **text commands**, one per `write`. The protocol
is the service's, not the kernel's. Discovery is **read the
service's man page**, not **call ioctl with a magic number**.

## The ctl-file discovery dance

The canonical pattern for any newly-allocated resource. Example:
allocating a `rio` draw context.

```
fd = open("/dev/draw/new", ORDWR)
write(fd, "", 0)             # the act of writing allocates
read(fd, buf, 16)            # → "3\n"
                             # /dev/draw/3/* now exists
data = open("/dev/draw/3/data", ORDWR)
write(data, draw_cmds, n)    # binary draw-protocol commands
close(data); close(fd)
```

Three properties of this pattern that matter:

1. **Allocation is a write+read.** The `ctl` (or `new`) file echoes
   back the id of the newly-created resource.
2. **No special opcode for "give me a draw context".** It's just
   bytes on a file.
3. **The kernel doesn't know about windows.** `rio` runs in
   userspace, served the read, allocated the id, set up
   `/dev/draw/3/*` in its mount. The kernel only delivered the
   bytes.

Network connection setup (`/net/tcp/clone` → `/net/tcp/<n>/{ctl,
data}`), process spawning via `/proc/clone`, and any future Layer
3 service follows this same shape.

## Migration table

Every current `SYS_*` mapped to its Plan 9 home. **None of these
moves break Linux ABI** (Layer 2 has its own dispatch table).

| Old name | Old # | Disposition | New name / path | Note |
|----------|------:|-------------|-----------------|------|
| `SYS_PUTC` | 0 | **→ path** | `write("/dev/cons", c, 1)` | Single-byte writer; delete the syscall after callers migrate. Phase G. |
| `SYS_EXIT` | 1 | Renumber → keep | `exits` (1) | Argument widens from int to string ptr; `exits(NULL)` ≡ `_exit(0)`. Layer 2 translates int↔string. |
| `SYS_GET_JIFFIES` | 2 | **→ path** | `read("/dev/time")` | Returns ns text. Convert in userspace lib. Delete syscall in Phase G. |
| `SYS_CLONE` | 3 | **→ new** | `rfork` (256) | Old syscall stays during Phases B..F for Linux ABI `do_clone` to keep working; deleted from native dispatch in Phase G. |
| `SYS_GETPID` | 4 | Keep | `getpid` (4) | Convenience wrapper kept alongside `read("/dev/pid")`. |
| `SYS_OPEN` | 5 | Keep | `open` (5) | Flag bits renamed to `OREAD`/`OWRITE`/`ORDWR`/`OTRUNC`/`ORCLOSE`/`OCEXEC`/`OAPPEND` — same wire values. |
| `SYS_READ` | 6 | Keep | `read` (6) | Directory reads change shape — Dir record stream. Layer 2 reformats. |
| `SYS_CLOSE` | 7 | Keep | `close` (7) | |
| `SYS_WRITE` | 8 | Keep | `write` (8) | |
| `SYS_LSEEK` | 9 | Keep | `seek` (9) | Renamed; same wire. |
| `SYS_EXECVE` | 10 | Keep | `exec` (10) | |
| `SYS_SPAWN` | 11 | **Deprecate** | `rfork(RFPROC|RFFDG|RFNAMEG|RFENVG)` + `exec` | Plan 9 has no spawn. Native callers (hamsh) rewrite as rfork+exec in Phase G. Linux ELFs never used this — they call `linux_abi/u_syscalls.ad`. |
| `SYS_WAITPID` | 12 | Renumber → keep | `wait` (12) | One-arg `wait(status_ptr)` — pid arg dropped (Plan 9 waits for **any** child; libc helper reimplements pid-specific wait by looping). |
| `SYS_OPEN_WRITE` | 13 | **Deprecate** | `open(path, OWRITE\|OTRUNC)` | Delete in Phase G. |
| `SYS_PIPE` | 14 | Keep | `pipe` (14) | Wire identical. Both ends are bidirectional in Plan 9; we honour that. |
| `SYS_SOCKETPAIR` | 53 | Keep (V5 shipped) | `socketpair` (53) | Linux number 53. `int socketpair(int domain, int type, int protocol, int sv[2])` returns two BIDIRECTIONAL fds. `domain` ignored; `type` must be `SOCK_STREAM` (1) or `SOCK_DGRAM` (2); `protocol` ignored. Each fd is full-duplex — writes on one appear as reads on the other. Backed by `fs/socketpair.ad`; 32-pair pool, 1 KiB rings per direction. Use this (not `SYS_PIPE`) for bidirectional transports (rio, in-kernel 9P client). |
| `SYS_KILL` | 15 | **→ path** | `write("/proc/<pid>/note", msg)` | Layer 2 translates Linux signo to Plan 9 note string. Delete syscall in Phase G. |
| `SYS_DUP` | 16 | Keep | `dup(fd, -1)` (16) | |
| `SYS_DUP2` | 17 | **Merge** | `dup(fd, newfd)` (16) | One call covers both. Phase G removes the 17 entry. |
| `SYS_LISTDIR` | 18 | **→ Dir reads** | `read(dirfd, buf, n)` | Returns Dir records (see "Directory format"). Existing custom format dies in Phase G. |
| `SYS_CHDIR` | 19 | Keep | `chdir` (19) | |
| `SYS_GETCWD` | 20 | **Flag** | Two options: (a) keep as syscall (pragmatic); (b) `fd2path(cwdfd, buf, n)` where `cwdfd` is always-open at fd 0 of `/proc/self`. Phase G picks. Plan 9 itself does not have getcwd. |
| `SYS_UNLINK` | 21 | Rename | `remove` (263) | Wire identical. |
| `SYS_MKDIR` | 22 | **→ new** | `create(path, OWRITE, DMDIR\|0755)` | Phase G replaces. |
| `SYS_INIT_MODULE` | 175 | Keep (Layer 0 helper) | `init_module` (175) | This is a Linux concept; native callers (insmod) use it. Plan 9 has no analog. **Document as Layer-0 helper, not a Plan 9 primitive.** Stays. |
| `SYS_DELETE_MODULE` | 176 | Keep (Layer 0 helper) | `delete_module` (176) | Same. |

### Numbers reserved for new Plan 9 primitives

| # | Name |
|--:|------|
| 256 | `rfork` |
| 257 | `bind` |
| 258 | `mount` |
| 259 | `unmount` |
| 260 | `create` |
| 261 | `stat` |
| 262 | `fstat` |
| 263 | `remove` |
| 264 | `fd2path` |
| 265 | `errstr` |
| 266 | `wstat` (shipped: name + mode honoured; length/mtime/gid/muid sentinel-only) |
| 267 | `fwstat` (shipped: tmpfs fds only; other backends report `errstr("fwstat: backend not supported")`) |
| 268 | `fauth` (reserved; Phase G — needed for `mount` with auth) |
| 270 | `notify` (reserved; Phase G — note handler) |
| 271 | `noted` (reserved; Phase G — return from note handler) |
| 272 | `awake` (reserved) |
| 273 | `segattach` (reserved) |
| 274 | `segdetach` (reserved) |
| 275 | `srv_post` (shipped: V4 — userspace publishes srvfd at `/srv/<name>`) |
| 276 | `srv_open` (shipped: V4 — opener dups poster's srvfd into its own fd table) |

## Things deliberately left out

- **`socket`/`bind` (Linux)/`listen`/`accept`/`connect`/`send`/`recv`.**
  Layer 2 translates these by opening `/net/tcp/clone` or
  `/net/udp/clone` and writing the appropriate `ctl` commands.
- **`epoll`, `select`, `poll`.** Plan 9 blocks on a single fd at
  a time; concurrency comes from rfork-shared-fd-table workers
  per blocked fd. Layer 2 emulates `select` with helper threads
  and rendezvous.
- **`ioctl`.** Every control surface is a `ctl` file.
- **`mmap` (anonymous).** Use `segattach` (when implemented) or
  large `kmalloc`-backed reads/writes. Linux ABI's `mmap` is
  Layer 2; Layer 1 has no mmap.
- **`mmap` (file).** Plan 9 does not have it. Memory-mapped I/O
  patterns are translated to read/write by Layer 2 when needed.
- **`setuid`/`setgid` family.** Plan 9 has no privilege levels in
  the Unix sense; security is namespace-based (`bind` what the
  process can see). Phase deferred.
- **Threading primitives** (`futex`, condition variables). Layer 2
  implements `futex` on top of `rendezvous` (`SYS_RENDEZVOUS`,
  9front `/sys/src/9/port/sysproc.c::sysrendezvous`) once that
  primitive lands.

## Discussion needed (flag-for-discussion items)

1. **`getcwd`.** Pragmatic to keep as syscall, but Plan 9 purists
   would prefer `fd2path` on the cwd channel. **Proposal:** keep
   `getcwd` as syscall in Phase G; reconsider when fd2path lands.
2. **`pipe` shape.** Plan 9 pipes are bidirectional and bytewise.
   Current Hamnix pipes are unidirectional (parent of M16.37+).
   **Proposal:** in Phase D, widen `pipe()` to return two bidi
   endpoints; Layer 2 `pipe()` keeps the Linux unidi semantics
   by half-shutting each end on creation.
3. **`SYS_SPAWN`.** No clean Plan 9 mapping (Plan 9 *always*
   rfork+exec). All native callers are `user/hamsh.ad` and
   coreutils. **Proposal:** add a tiny userspace wrapper
   `spawn(path, argv) = { pid = rfork(...); if pid==0 exec(...);
   return pid; }` in the native libc, retire the syscall.
4. **Module load/unload.** `init_module`/`delete_module` aren't
   Plan 9 primitives. **Proposal:** keep as Layer 0 helpers
   surfaced through native syscalls 175/176 for now, **and**
   expose a Layer 3 `/dev/mod/ctl` (write `load <path>` /
   `unload <name>`) once a module-manager daemon exists, so
   namespace-restricted callers can still drive modules without
   the raw syscall.
5. **`dup(fd, -1)` semantics.** 9front's `dup(2)` takes either
   one arg (lowest free) or two (specific newfd). Hamnix has
   discrete `SYS_DUP`/`SYS_DUP2`. **Proposal:** Phase G merges
   into one `dup` syscall; the lowest-free case maps to a -1
   newfd marker.

## Worked example: hamsh internals after migration

Today (Linux-shape native):

```
pid = SYS_SPAWN("/bin/ls", argv, stdin_fd, stdout_fd, envp)
status = SYS_WAITPID(pid)
```

Phase G (Plan 9-shape native):

```
pid = rfork(RFPROC|RFFDG|RFNAMEG|RFENVG)
if pid == 0:
    # child: redirect stdio via dup, then exec
    dup(stdout_fd, 1)
    exec("/bin/ls", argv, envp)
    exits("exec failed")
status = wait(&exit_word)
```

The `dup(stdout_fd, 1)` is namespace-local to the child because
`rfork` was called with `RFFDG` (copy the fd table). The parent's
fd 1 is untouched.

## References

- Plan 9 4th edition, Programmer's Manual Volume 1: `intro(2)`,
  `open(2)`, `bind(2)`, `mount(2)`, `rfork(2)`, `read(2)`,
  `stat(2)`, `errstr(2)`, `notify(2)`.
- 9front sources:
  - `/sys/src/9/port/sysproc.c` — rfork, exec, exits, wait, sleep
  - `/sys/src/9/port/sysfile.c` — open, create, read, write, close, seek, dup, pipe, remove, stat, fd2path
  - `/sys/src/9/port/chan.c` — namespace, bind, mount, walk
  - `/sys/src/9/port/error.c` — errstr machinery
  - `/sys/src/9/port/portfns.h` — full syscall table
- Hamnix-specific: `docs/architecture.md` (this directory),
  `linux_abi/TARGET_ABI.md`.
