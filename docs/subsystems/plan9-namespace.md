# Plan 9 Namespace & Native Syscalls (Layer 1)

> **Source of truth:** `sys/src/9/port/` (all files), `lib/9p/9p.ad`,
> `arch/x86/kernel/syscall.ad`
> **Last verified against source:** 2026-06-10

## Purpose

Layer 1 — the **Plan-9-shape** surface of Hamnix. This is the project's
defining layer: per-process namespaces, file servers, `#x` device
binding, and a small native syscall set (`rfork`, `bind`, `mount`,
`open`/`read`/`write`, `errstr`, ...). **There is NO global filesystem
route**: a process sees a path only because something was bound or
mounted into *its own* namespace. The directory path mirrors 9front's
`/sys/src/9/port/` so a Plan-9 reader finds the analogue at a glance.

## Key files

| Path | Role |
|--|--|
| `chan.ad` | `Chan`, `MountEntry`, `Pgrp`, `NameEntry`; namespace + mount-table primitives; named file-server stack; `#by-id/<partuuid>` aliases + bind-freeze |
| `namec.ad` | `ChanT` + `namec()` — the universal open path; resolves a path through the process mount table to a Chan + `devtab` dispatch |
| `dev.ad` | the device-letter directory (`#c`, `#p`, `#s`, `#/`, `#d`, ...) + `is_reserved_word()` sentinel validation |
| `sysproc.ad` | `do_rfork` / exec / wait / exits; namespace + fd-table + note-group setup at fork |
| `syschan.ad` | `do_bind` / `do_mount` / `do_unmount` / `do_nslabel` / `do_fdbind` / `do_pipechan` / `do_openchan` |
| `sysfile.ad` | `open` / `read` / `write` / `close` / `seek` / `create` / `stat` / `fstat` / `dup` / `pipe` |
| `sysnote.ad` | Plan-9 notes (`/proc/<pid>/note`) |
| `error.ad` | per-process `errstr` machinery |
| `9p_client.ad` | kernel-side 9P client (Tversion/Tattach/Twalk/Topen/Tread/Twrite/Tclunk) over a posted srvfd |
| `devmountrpc.ad` | mount-RPC plumbing to userspace file servers |
| `dev*.ad` (many) | per-device cdev bodies (see below) |

### Device cdevs (the `#X` letter namespace)

`devcons.ad` (console), `devtime.ad`, `devrandom.ad` (ChaCha20 CSPRNG),
`devpid.ad`, `devproc.ad`, `devmouse.ad`, `devsrv.ad` (`#s` srv posting),
`devfd.ad`, `devmeminfo.ad`, `devcpuinfo.ad`, `devuptime.ad`,
`devloadavg.ad`, `devstat.ad`, `devhostname.ad`, `devversion.ad`,
`devdiskstats.ad`, `devmounts.ad`, `devmountrpc.ad`, `devauth.ad`
(see [../security.md](../security.md)), `devkeymap.ad`, `devnscap.ad`,
`devvt.ad` (virtual terminals), `devwsys.ad` (window system, see
[../hamUI.md](../hamUI.md)), `devblk.ad` (block-device file server),
`devfirewall.ad`, `devnet.ad` lives under `drivers/net/` (see
[networking.md](networking.md)).

## Architecture & data structures

- **`Pgrp`** (`chan.ad:160`) — the per-process namespace: a refcounted
  mount table. `rfork(RFNAMEG)` gives a child its own `Pgrp`.
- **`Chan`** (`chan.ad:114`) — an open channel to a file/server (the
  Plan-9 `Chan`). **`MountEntry`** (`chan.ad:136`) / **`NameEntry`**
  (`chan.ad:258`) back the mount table.
- **`ChanT`** (`namec.ad:373`) — the kernel-side open-channel table that
  `namec()` allocates from.
- **bind-freeze**: a `#<word>` resolves to a concrete
  `#by-id/<partuuid>` at bind time, so hot-plug cannot yank a running
  namespace's backing device.
- **`devtab` dispatch**: `namec()` routes by device letter into the
  matching `dev*.ad` cdev. The same kernel file server answers both the
  native and the Linux-shaped namespace via different bindings — no
  string rewriting in the syscall path (the cdev-family demonstration in
  [../architecture.md](../architecture.md)).

## Entry points

- `namec(path, mode)` (`namec.ad:1413`) — resolve a path to a Chan id;
  `namec_create` / `namec_mkdir` / `namec_read` / `namec_write` /
  `namec_close` operate on it.
- `do_rfork(flags, child_stack, tls, ...)` (`sysproc.ad:411`) — fork with
  selective resource sharing (`RFNAMEG`, `RFFDG`, `RFPROC`, ...).
- `do_bind` / `do_mount` / `do_unmount` (`syschan.ad`) — namespace edits.
- `do_openchan` / `do_pipechan` / `do_fdbind` (`syschan.ad`) — channel +
  fd plumbing.
- `do_nslabel` (`syschan.ad`) — namespace labelling.
- 9P client: `9p_client.ad` drives a userspace file server over an fd
  posted to `#s` (`devsrv.ad`).

The native syscall numbers are dispatched in `arch/x86/kernel/syscall.ad`
(`do_syscall`); see [native-api.md](../native-api.md) for the per-call
contracts and [linux-abi.md](linux-abi.md) for how the per-task ABI
selector routes Linux binaries elsewhere.

## Invariants & gotchas

- **No global root.** Any doc/code that writes to a "global" `/var`,
  `/usr`, `/etc` is mis-shaped — those paths only exist inside a
  namespace something bound them into. Linux-binary/distro state lives in
  the `distrofs` namespace (see [../distro-namespaces.md](../distro-namespaces.md)).
- **No native sockets.** There is no `socket()`/`sendto()`/`recv()` at
  Layer 1. Net I/O is kernel ops or the `/net` Plan-9 file tree
  (see [networking.md](networking.md)).
- **Sentinel words** (`is_reserved_word` in `dev.ad`) gate which `#X`
  letters are valid; the multi-root `.hamnix-roots` invariant depends on
  these (see [../rootfs_partition.md](../rootfs_partition.md)) — don't
  break them in Chan/mount reworks.
- Permission/access enforcement is at the namespace/file-server boundary,
  not POSIX mode bits; no hard links across file servers.

## Related docs

- [../architecture.md](../architecture.md) — the layered model + cdev demonstration.
- [../native-api.md](../native-api.md) — Layer-1 syscall reference.
- [../9p.md](../9p.md) — 9P2000 wire format; `lib/9p/9p.ad` is the codec.
- [../rootfs_partition.md](../rootfs_partition.md), [../distro-namespaces.md](../distro-namespaces.md).
- [filesystems.md](filesystems.md) — what backs the channels.
