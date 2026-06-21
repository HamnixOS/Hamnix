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

**Status (Phase G — #450 F6, 2026-06-11).** `SYS_LISTDIR` (number 18)
is RETIRED from the native dispatch table; the number stays reserved
per the F2 #447 pattern. Native callers use the `p9_listdir(path,
buf, count)` wrapper in `lib/p9.ad` — it opens the directory with
`OREAD`, reads the dir fd's bytes into the caller's buffer, and
closes. The dir-fd's `DEV_DIR_FILE` backing
(`sys/src/9/port/namec.ad::_dirfile_read`) still emits the same
`"NAME\n"`-packed bytes the old syscall returned, so every existing
glob parser keeps working byte-for-byte. Migrating that backing to
emit Plan-9 Dir records (the full 9P `stat` shape described above)
is a separate kernel-side milestone — the `do_stat`/`do_fstat`
syscalls already build Dir records; the dir-read path still emits
`NAME\n` until that switchover lands.

Namespace mount-table children synthesis (the thing that makes `bind
'#c' /dev` show up as `dev` in `ls /`) now lives on the open-dir
path: `fs/vfs.ad::_open_dir_with` calls `chan_dir_mount_children`
after the backing FS fills the listing, keyed on the conventional
pre-`ns_walk` path stashed by the `SYS_OPEN` arm. The retired
`SYS_LISTDIR` arm used to do this in `_sysarm_listdir`; the
synthesis behaviour is preserved.

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

### `bind(src: Ptr[uint8], dst: Ptr[uint8], flag: int32) -> int32`

**New, number 257.** Graft `src` (the source file server / path)
at `dst` (the lookup path in the calling process's namespace).
After `bind("/proc/self/fd", "/fd", MREPL)`, opens of `/fd/0` find
`/proc/self/fd/0`.

**Argument order is source-first, target-second** — same as Linux
`mount(source, target)`. The hamsh wrapper `bind SRC DST` matches:

```
bind '#s' /srv      # graft the srv device-letter at /srv
bind '#p' /proc     # graft the proc device-letter at /proc
bind '#h' /n/home   # graft an auto-discovered home server at /n/home
```

Plan 9's `bind(2)` uses confusing argument names (`new`/`old`); the
Hamnix syscall uses `src`/`dst` to avoid the ambiguity. The
semantics are identical to Plan 9's bind: same NEW=source,
OLD=target/lookup-path meaning, just clearer names.

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
note-handler registered via `notify(handler_ptr)` (sysnumber 270;
body in `sys/src/9/port/sysnote.ad`). Other processes post notes by
writing to `/proc/<pid>/note`:

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
| `/dev/mouse` | r/w | Per-window mouse events; write repositions cursor. Served by the DE compositor (see `de_scene_file_arch.md`). |
| `/dev/wsys/ctl` | r/w | `newwindow` allocates a window; read lists open windows + stats. Served by the DE compositor. |
| `/dev/wsys/<wid>/{scene,ctl,event}` | r/w | Per-window display-list file, control (geometry/z/decorate/commit), and focus-routed input. See `de_scene_file_arch.md`. |
| `/dev/wctl` | r/w | Per-window control (resize/move/raise). Served by `rio`. |
| `/dev/wsys` | r/w | System-wide window control; write spawns a window. Served by `rio`. |
| `/net/tcp/clone` | r/w | Open then read to get a new TCP connection number N; further I/O on the per-conn `/net/tcp/<N>/{ctl,data,local,remote,status}`. Plan 9 idiom. Implemented by `drivers/net/devnet.ad`. |
| `/net/tcp/<N>/ctl` | w | Write one text command: `connect <a.b.c.d>!<port>`, `announce <port>`, `accept`, `tls <hostname>`, `hangup`. After `accept`, read the ctl file to get the accepted connection number. The `tls` command runs the in-kernel TLS 1.3 handshake (X25519 + cert-chain validation + CertificateVerify) over a connected conn — afterwards reads/writes on the conn's data file are transparently TLS-decrypted/encrypted. |
| `/net/tcp/<N>/data` | r/w | The connection's byte stream. |
| `/net/tcp/<N>/{status,local,remote}` | r | Readable connection info. |
| `/net/udp/*` | r/w | Same shape, UDP (datagram). |
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

### F2 #447 — drift syscall retirements (2026-06-11)

The 2026-06-11 audit (#444 F2 / task #447) called out a set of native
syscall arms that duplicated work already file-shaped or that should
have been file-shaped. The retirement set landed as Plan-9-shape ctl
files alongside the existing surface:

| Drift syscall | Reserved # | Replacement ctl file | Verbs |
|----------|------:|-----------------|------|
| `SYS_NICE` | 311 | `/proc/<pid>/ctl` | `pri <n>` |
| `SYS_SVC_CTL` | 296 | `/proc/svc/ctl` | `start <name>` / `stop <name>` / `restart <name>` / `enable <name>` / `disable <name>` / `runlevel <digit>` / `unpublish <name>` |
| `SYS_RESOLVE` | 269 | `/net/dns/lookup` (R/W) | write `<hostname>\n` then read for `<a.b.c.d>\n` or `fail\n` |
| `SYS_RESOLVE_PTR` | 301 | `/net/dns/rlookup` (R/W) | write `<a.b.c.d>\n` then read for `<name>\n` or `fail\n` |
| `SYS_NETCFG` SET_ADDR | 286 op 1 | `/net/ipifc/ctl` | `add addr <a.b.c.d> mask <a.b.c.d>` |
| `SYS_NETCFG` SET_GW | 286 op 2 | `/net/ipifc/ctl` | `add gw <a.b.c.d>` |
| `SYS_NETCFG` SET_DNS | 286 op 3 | `/net/dns` (R/W) | write `server <a.b.c.d>` ; read renders `<a.b.c.d> <source>\n` |
| `SYS_NETCFG` ROUTE_ADD | 286 op 4 | `/net/ipifc/ctl` | `route add <net> <mask> <gw> [onlink]` |
| `SYS_NETCFG` ROUTE_DEL | 286 op 6 | `/net/ipifc/ctl` | `route del <net> <mask> <gw>` |
| `SYS_NETCFG` GET addr | 286 op 0 | `/net/addr` (existing) | host-level read |
| `SYS_NETCFG` ROUTE_GET | 286 op 5 | (still syscall) | a future `/net/ipifc/route` directory would close the loop |
| `SYS_WSYS_ALLOC` | 293 | `/dev/wsys/ctl` | write `alloc <pid>\n` then read same fd for assigned wid as decimal |
| `SYS_WSYS_FREE` | 294 | `/dev/wsys/ctl` | `free <wid>\n` |
| `SYS_VK_WINDOW_FRAME` | 312 | `/dev/wsys/ctl` | `frame <wid> <frame>\n` |

All ctl files are hostowner-gated wherever the original syscall was
(SYS_WSYS_*, SYS_VK_WINDOW_FRAME); the gate is enforced inside the
write handler so a non-hostowner write returns -EPERM with errstr,
matching the syscall semantics.

**The syscall numbers stay reserved — do not reuse.** The syscall
arms remain in place as deprecated thin shims around the same kernel
helpers the new ctl files call (`sched_set_nice`, `svc_ctl_enqueue`,
`dns_set_static_server`, `wsys_alloc_wid` etc.). Callers SHOULD
migrate to the ctl-file form.

**Not retired in F2 (legitimate "kernel-of-resource" shape, NOT drift):**

- `SYS_TIMERFD_CREATE` (314) / `SYS_TIMERFD_SETTIME` (315). A timerfd
  IS already a file — the syscall creates the resource (returns an
  fd) and configures it. Re-shaping `timerfd_create` to `open("/dev/
  timer/ctl")` + `write "create monotonic\n"` + read the resulting
  fd is just adding ASCII bouncing for no architecture win. The
  `settime` body itself is a write of a binary itimerspec to the fd
  — that IS the Plan 9-shape ioctl-as-write. Kept.
- `SYS_SETPGID` (273-ish) / `SYS_TCSETPGRP` / `SYS_WAITPID_JC`
  (job-control family). These are POSIX shell-job-control primitives
  (SIGTSTP / SIGCONT model). Plan 9 has no equivalent — the
  equivalent Plan 9 surface would be `/proc/<pid>/ctl` for process-
  group ops plus `/dev/cons/ctl` for the terminal-foreground-group
  bit, and native hamsh has its own job-control model that bypasses
  them anyway. They survive in the dispatch table because the
  Linux-ABI shell (busybox / bash) calls them. **Tracked as
  follow-up drift** — not in scope for F2's "Plan-9-shape
  replacement" because the right home is a substantial design rather
  than a thin ctl-file. Noted here for the next audit pass.
- `SYS_MMAP` family (`mmap`/`mprotect`/`munmap`/`msync`). Plan 9
  uses `segattach` / `segdetach` (273/274 are RESERVED — not built).
  Native code today calls `SYS_MMAP` directly for anonymous regions
  (the libc `malloc` path, big buffers, hamUI per-frame fb mapping).
  **Honest deviation, documented:** `mmap` (file-backed) is NOT
  built natively at all — Linux ABI's `mmap` is Layer 2; Layer 1
  native code uses `kmalloc`-shape large reads/writes instead. For
  anonymous regions, native code SHOULD eventually move to
  `segattach`, but that's a multi-week build that depends on a
  per-process segment table that doesn't exist yet (the L-shim has
  one, native doesn't). For now `SYS_MMAP` stays native-ABI. The
  reservation of `segattach`=273 stands; the migration is scheduled
  but not gated on F2.

### Pre-F2 retirements (Phase G / pre-2026-06-11)

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
| `SYS_SPAWN` | 11 | **RETIRED (#450 F6, Phase G)** | `lib/p9.ad::spawn(path, argv, sin, sout, envp)` → `rfork(RFPROC\|RFFDG\|RFNAMEG)` + child `exec` (+ `dup2` for legacy integer-fd sin/sout, + `open("/fd/N") + dup2` for `SPAWN_STDIO_NS` sentinel routing). Number 11 RESERVED — do not reuse. 200+ line stdio/Pgrp inheritance block deleted from `arch/x86/kernel/syscall.ad`; the inheritance story is rfork's flag set, NOT kernel-side magic. |
| `SYS_WAITPID` | 12 | Renumber → keep | `wait` (12) | One-arg `wait(status_ptr)` — pid arg dropped (Plan 9 waits for **any** child; libc helper reimplements pid-specific wait by looping). |
| `SYS_OPEN_WRITE` | 13 | **Deprecate** | `open(path, OWRITE\|OTRUNC)` | Delete in Phase G. |
| `SYS_PIPE` | 14 | Keep | `pipe` (14) | Wire identical. Both ends are bidirectional in Plan 9; we honour that. |
| `SYS_SOCKETPAIR` | 53 | Keep (V5 shipped) | `socketpair` (53) | Linux number 53. `int socketpair(int domain, int type, int protocol, int sv[2])` returns two BIDIRECTIONAL fds. `domain` ignored; `type` must be `SOCK_STREAM` (1) or `SOCK_DGRAM` (2); `protocol` ignored. Each fd is full-duplex — writes on one appear as reads on the other. Backed by `fs/socketpair.ad`; 32-pair pool, 1 KiB rings per direction. Use this (not `SYS_PIPE`) for bidirectional transports (rio, in-kernel 9P client). |
| `SYS_KILL` | 15 | **RETIRED for positive pid (#450 F6, Phase G)** | `lib/p9.ad::p9_note(pid, msg)` → `open("/proc/<pid>/note", OWRITE) + write(fd, msg) + close(fd)`. Layer 2 maps Linux signo to Plan 9 note string. **Negative-pid path SURVIVES** as the Unix process-group broadcast `kill(-pgid, sig)` — F2 #447 left the POSIX job-control family (SETPGID / TCSETPGRP / WAITPID_JC) in place as follow-up scope; this is part of that surface. Userland reaches it via `user/runtime.S::sys_pgrp_kill(pgid, sig)`. A positive-pid `SYS_KILL` call returns -ENOSYS with errstr "kill: positive-pid retired; use /proc/<pid>/note". Number 15 stays. |
| `SYS_DUP` | 16 | Keep | `dup(fd, -1)` (16) | |
| `SYS_DUP2` | 17 | **Merge** | `dup(fd, newfd)` (16) | One call covers both. Phase G removes the 17 entry. |
| `SYS_LISTDIR` | 18 | **RETIRED (#450 F6, Phase G)** | `lib/p9.ad::p9_listdir(path, buf, count)` → `open(path, OREAD) + read(fd, buf, count) + close(fd)`. The dir-fd's `DEV_DIR_FILE` backing still emits the SAME `"NAME\n"`-packed bytes the syscall used to return, so userland glob parsing stays byte-identical. Number 18 RESERVED — do not reuse. `_sysarm_listdir` and the SYS_LISTDIR dispatch arm are gone from `arch/x86/kernel/syscall.ad`. Migrating the dir-read backing to native 9P Dir records is a SEPARATE kernel-side milestone. |
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
| 270 | `notify` (shipped — note handler in `sys/src/9/port/sysnote.ad`) |
| 271 | `noted` (shipped — return from note handler) |
| 272 | `awake` (reserved) |
| 273 | `segattach` (reserved) |
| 274 | `segdetach` (reserved) |
| 275 | `srv_post` (shipped: V4 — userspace publishes srvfd at `/srv/<name>`) |
| 276 | `srv_open` (shipped: V4 — opener dups poster's srvfd into its own fd table) |
| 287 | `fdslot_kind` (shipped: hamsh /fd-binding kernel-vs-userland coordination) |
| 288 | `getuid` (shipped: Plan-9-shape uid accessor per `docs/security.md`) |
| 324 | `fdslot_arg` (shipped: sibling of `fdslot_kind` — reads the pipe/file/dup slot arg so hamsh's `enter NS { }` re-applies the parent's stdio into a clean-namespace child) |
| 289 | `getgid` (shipped: Plan-9-shape gid accessor per `docs/security.md`) |
| 290 | `setuid` (shipped: hostowner-only — uid==1 caller may set its uid+gid to argument; used by `newshell` post-`/dev/auth` and by `svc` to drop privs before exec) |
| 291 | `svc_publish` (shipped: hostowner-only — supervisor mirrors svc registry into `/proc/svc/<name>` for shell-grep inspection) |

## Things deliberately left out

- **`socket`/`bind` (Linux)/`listen`/`accept`/`connect`/`send`/`recv`.**
  Layer 2 translates these by opening `/net/tcp/clone` or
  `/net/udp/clone` and writing the appropriate `ctl` commands.

  **Status (ARCH §10 — landed).** The `/net` file tree is implemented
  (`drivers/net/devnet.ad`): `/net/tcp/clone`, `/net/udp/clone`, and
  the per-connection `/net/<proto>/<N>/{ctl,data,status,local,remote}`
  files, backed by the in-kernel TCP/UDP stack. Native code does
  networking by `open`/`read`/`write` on these files
  (`user/net9.ad`'s `net_dial` / `net_announce` / `net_accept`). The
  native server-side socket syscalls `SYS_BIND_SOCK` (49) /
  every native BSD socket syscall is now **retired** —
  `SYS_SOCKET` (41), `SYS_CONNECT` (42), `SYS_ACCEPT_SOCK` (43),
  `SYS_BIND_SOCK` (49), `SYS_LISTEN_SOCK` (50) and `SYS_TLS_CONNECT`
  (277) are unassigned in the native dispatch table. The Linux-ABI
  `socket()`/`connect()`/`bind()`/`listen()`/`accept()`/`tls_connect`
  shims (`linux_abi/u_syscalls.ad`) are now Layer-2 *consumers* of
  `/net` — they drive `devnet_clone` + the `connect`/`announce`/
  `accept`/`tls` ctl protocol, not `tcp_connect` directly. TLS is a
  Plan-9-shaped upgrade of a `/net/tcp` conn: a `tls <hostname>` ctl
  command on a connected conn runs the in-kernel TLS 1.3 handshake
  (drivers/net/tls.ad's record layer rides the conn's `data` file)
  and flags the conn TLS-active; vfs routes the conn's data file
  through `tls_recv`/`tls_send`/`tls_close_notify`. Native clients
  reach all of this via `user/net9.ad`'s `net_dial` / `net_dial_tls`
  / `net_announce` / `net_accept`.

  **F2 #447 (2026-06-11):** DNS and netcfg ARE now `/net`-shaped.
  Forward lookups go to `/net/dns/lookup` (write hostname, read
  IPv4); reverse lookups to `/net/dns/rlookup`; DNS server pin to
  `/net/dns` (`server X.Y.Z.W`); IP config to `/net/ipifc/ctl`
  (`add addr ... mask ...`, `add gw ...`, `route add ...`, `route
  del ...`). `SYS_RESOLVE` (269), `SYS_RESOLVE_PTR` (301), and
  `SYS_NETCFG` (286) survive as deprecated thin-shim syscalls
  around the same kernel helpers the new ctl files call; new code
  should use the file form.
- **`epoll`, `select`, `poll`.** Plan 9 blocks on a single fd at
  a time; concurrency comes from rfork-shared-fd-table workers
  per blocked fd. Layer 2 emulates `select` with helper threads
  and rendezvous.
- **`ioctl`.** Every control surface is a `ctl` file.
- **`mmap` (anonymous).** Plan 9 uses `segattach` / `segdetach`
  (273/274 are reserved here). **F2 #447 (2026-06-11): honest
  deviation.** Native code today calls `SYS_MMAP` directly for
  anonymous regions (libc `malloc`, big buffers, hamUI per-frame fb
  mapping). The replacement `segattach` is scheduled but not built —
  it needs a per-process segment table the native side doesn't have
  yet. So `SYS_MMAP`/`SYS_MPROTECT`/`SYS_MUNMAP`/`SYS_MSYNC` survive
  in the native dispatch table even though they are not Plan-9-shape
  — the alternative (rewrite every native big-buffer caller to
  large-kmalloc plus a userspace allocator) is a multi-week build
  with no boundary win today. The honest-deviation tag is here so a
  later audit doesn't re-flag it as "drift" — it is a SCHEDULED
  build, not undocumented sprawl.
- **`mmap` (file).** Plan 9 does not have it. Memory-mapped I/O
  patterns are translated to read/write by Layer 2 when needed.
  Native code does NOT have a file-backed mmap at all.
- **`setuid`/`setgid` family (Linux shape).** Plan 9 has no
  privilege levels in the Unix sense; security is namespace-based
  (`bind` what the process can see). Hamnix's own
  `SYS_GETUID`/`SYS_GETGID`/`SYS_SETUID` (288/289/290) **exist**
  but are deliberately **hostowner-only** — the `newshell` builtin
  is the one legitimate userland path that calls `SYS_SETUID`,
  after `/dev/auth` has authenticated the target user. There is
  no setuid bit, no setgid bit, no setresuid family. The
  Plan-9-shape model is documented in `docs/security.md`.
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
3. **`SYS_SPAWN` — LANDED #450 F6, 2026-06-11.** Userland wrapper
   `lib/p9.ad::spawn(path, argv, sin, sout, envp)` rforks with
   `RFPROC|RFFDG|RFNAMEG` (private fd-table copy + private COW Pgrp),
   the child handles stdin/stdout for the legacy integer-fd cases
   (`sys_dup2(sin, 0)` / `sys_dup2(sout, 1)` for sin/sout in [0, 16))
   and the `SPAWN_STDIO_NS` sentinel case (open `/fd/0,1,2` and dup2
   onto the integer slot — routes integer reads/writes through the
   /fd-name table so the parent's `sys_fdbind(child_pid, ...)` for
   pipes and redirects takes effect on the child's I/O). Then
   `sys_execve_env`. The kernel's 200+ line stdio/Pgrp inheritance
   block in `arch/x86/kernel/syscall.ad` is gone. Number 11 stays
   reserved.
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

#450 F6 (2026-06-11): the migration LANDED. Native callers use the
thin `lib/p9.ad::spawn(path, argv, sin, sout, envp)` userland
wrapper, which is exactly the rfork+exec body Plan 9 idiom:

```
# In lib/p9.ad:
def spawn(path, argv, sin, sout, envp) -> int32:
    pid = sys_rfork(RFPROC | RFFDG | RFNAMEG)
    if pid != 0:
        return pid                             # parent gets child pid
    # Child: route stdio through /fd/N for the SPAWN_STDIO_NS
    # sentinel (-2), or dup2 a legacy integer fd for sin/sout in
    # [0, 16); -1 means "inherit", which RFFDG already copied.
    if sin == SPAWN_STDIO_NS:
        fd = sys_open("/fd/0"); sys_dup2(fd, 0); sys_close(fd)
    if sout == SPAWN_STDIO_NS:
        fd = sys_open("/fd/1"); sys_dup2(fd, 1); sys_close(fd)
        fd = sys_open("/fd/2"); sys_dup2(fd, 2); sys_close(fd)
    if sin >= 0:  sys_dup2(sin, 0)
    if sout >= 0: sys_dup2(sout, 1)
    sys_execve_env(path, argv, envp)
    sys_exit(127)                              # "command not found"
```

Callers see the SAME 5-arg signature the retired SYS_SPAWN used —
hamsh's `spawn_resolved`, `_wire_redirects`, the svc supervisor's
uid-switch wrapper, every coreutils call site (`/bin/man`,
`/bin/distrofs`, `/bin/httpd_worker`, ...) — all migrate by symbol
rename only. The 200+ line kernel-side stdio/Pgrp inheritance block
is GONE; the inheritance story is rfork's flag set plus the child's
own dup2 / `open("/fd/N")` calls.

Concrete hamsh wiring (`user/hamsh.ad::spawn_resolved` after migration):

```
pid = spawn("/bin/ls", argv, SPAWN_STDIO_NS, SPAWN_STDIO_NS, envp)
# Cooperative scheduler: child is STATE_READY until we yield, so
# pipe / redirect / dup binds land before it runs.
sys_fdbind(pid, 1, DEVFD_PIPE_W, slot)
status = sys_waitpid(pid)
```

`sys_fdbind` rewrites the bind under the child's `/fd/1` name in its
COW-cloned Pgrp; the child's integer fd 1 (now backed by a
FD_CHAN_MARK + DEV_DEVFD inline-chan opened on `/fd/1`) resolves
through that bind every time the child writes.

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
