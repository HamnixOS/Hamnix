# Linux ABI Shim (Layer 2)

> **Source of truth:** `linux_abi/` (all files), `arch/x86/kernel/syscall.ad`,
> `arch/x86/kernel/syscall_64.S`, `scripts/gen_linux_abi.py`,
> `scripts/gen_autostubs.py`
> **Last verified against source:** 2026-06-10

## Purpose

Layer 2 — the Linux-shape surface that lets **unmodified Linux binaries**
(glibc/musl static-PIE, CPython, busybox, real Debian apt/dpkg) run on
the same kernel. It translates Linux x86_64 syscalls onto the native
Layer-1 primitives and provides Linux-shape struct layouts for the `.ko`
module shim. CPython 3.11 and busybox 1.36 run; `apt`/`dpkg` install
packages inside `enter linux { ... }` against the `#distro` root.

## Key files

| Path | Role |
|--|--|
| `linux_abi/u_syscalls.ad` | the main userspace Linux-syscall dispatch: `linux_u_syscall_dispatch(nr, ...)` |
| `linux_abi/u_*.ad` | per-family syscall implementations (epoll, futex, io_uring, signalfd, termios, ptrace, pty, netlink, sysvipc, unixsock, memfd, pidfd, userfaultfd, ...) |
| `linux_abi/vdso.ad` | the AT_SYSINFO_EHDR shared-time vDSO page |
| `linux_abi/loader.ad` | Linux-ELF userspace loader (flips `is_linux_userspace`) |
| `linux_abi/exports.ad` | the symbol table exported to `.ko` modules |
| `linux_abi/api_*.ad` | the in-kernel API surface `.ko` modules link against (per-subsystem) |
| `linux_abi/api_autostubs.ad` | **generated** weak stubs for unresolved module symbols (see gotcha) |
| `linux_abi/structs/*.ad` | **generated** Linux struct layouts from a real 6.12 vmlinux BTF |
| `linux_abi/README.md` / `TARGET_ABI.md` | pinned Linux 6.12 ABI + regen instructions |

The `api_*.ad` set covers both core kernel subsystems (`api_kernel`,
`api_irq`, `api_dma`, `api_fs`, `api_chrdev`, `api_pci`, `api_kthread`,
`api_hrtimer`, `api_crypto`, `api_netdev`, `api_netlink`, ...) and
specific driver families (`api_e1000e`, `api_igb`, `api_r8169`,
`api_iwlwifi`, `api_cfg80211`, `api_ahci`, `api_libata`, `api_nvme`,
`api_xhci`, `api_ehci`, `api_usbcore`, `api_hid`, `api_drm`,
`api_snd_hda`, ...), plus the `api_lNN.ad` ladder (numbered L-track
batches).

## Architecture & data structures

- **Per-task ABI selector**: `TaskStruct.is_linux_userspace` (see
  [kernel-sched.md](kernel-sched.md)) picks the syscall numbering. The
  native `do_syscall()` (`arch/x86/kernel/syscall.ad`) handles ABI 0
  (Hamnix numbering); for ABI 1 it forwards to
  `linux_u_syscall_dispatch` (`linux_abi/u_syscalls.ad:13587`). The
  Linux-ELF loader (`linux_abi/loader.ad`) sets the flag before the
  child's first `iretq`.
- **No string rewriting in the syscall path.** Linux binaries see Linux
  paths because `enter linux { ... }` builds a Linux-shape namespace
  (`bind '#c' /dev`, `bind '#p' /proc`, `bind '#distro' /`) — the same
  kernel cdev file servers answer both worlds via different bindings
  (the cdev-family demonstration; see [../architecture.md](../architecture.md)).
- **Sockets live here, not natively.** The Linux `socket(2)` family is
  implemented in the ABI shim (`linux_abi/u_unixsock.ad` + the net
  glue); native Layer-1 has no sockets (see [networking.md](networking.md)).
- **BTF-extracted structs**: `linux_abi/structs/*.ad` are machine-
  extracted from a real Linux 6.12 vmlinux's BTF by
  `scripts/gen_linux_abi.py` so layouts don't drift. **Do not hand-edit.**

## Entry points

- `linux_u_syscall_dispatch(nr, a0..a5)` (`u_syscalls.ad:13587`) — the
  Linux userspace syscall router (`_linux_u_syscall_dispatch_inner` does
  the work).
- `vdso_init()` (`linux_abi/vdso.ad`) — set up the shared-time page at boot.
- the Linux-ELF load path in `linux_abi/loader.ad`.
- `linux_abi/exports.ad` — the symbol surface a `.ko` resolves against.

## Invariants & gotchas

- **`api_autostubs.ad` is generated AND committed AND module-set-
  dependent.** A build with a different module set regenerates it and may
  drop stubs (e.g. a non-DRM build drops DRM stubs). Don't commit
  stub-removing churn from a narrower build. (Documented trap — see
  project memory.)
- `structs/*.ad` and the autostubs are generated; edit the generator
  (`scripts/gen_linux_abi.py`, `scripts/gen_autostubs.py`), never the
  output.
- The ABI is pinned to Linux 6.12 (`TARGET_ABI.md`); the `.ko` modules
  must match (see [kernel-modules.md](kernel-modules.md)).

## Related docs

- [kernel-modules.md](kernel-modules.md) — loading stock Debian `.ko`s.
- [plan9-namespace.md](plan9-namespace.md) — the native Layer-1 it translates onto.
- [../distro-namespaces.md](../distro-namespaces.md) — the `#distro` namespace Linux binaries run in.
- [../architecture.md](../architecture.md), [../L_TRACK_HOWTO.md](../L_TRACK_HOWTO.md).
