# Hamnix architecture

A layered OS that **looks like Plan 9** to native apps, **looks like
Linux** to imported `.ko` modules and ELF binaries, and **looks like
Linux internally** because that's where the porting work is bounded.
Each layer has exactly one source of design influence. The
translations between layers are explicit.

## Layered model

```
                                                INFLUENCE
+---------------------------------------------+ ----------
| Layer 5: Applications                       | mixed
|   native apps (open /dev/win, /net/tcp)     |
|   linux ELFs (write/read/futex/clone)       |
|   .ko modules (request_irq, register_chrdev)|
+----------+----------------------+-----------+ ----------
           |                      |
           v                      v
+---------------------------+ +---------------+ ----------
| Layer 4: Wire protocols   | |   (kernel     |
|   VTNext-v2 (serial/TCP)  | |    delivers   | Hamnix +
|   9P-over-net (mounts)    | |    bytes)     | Plan 9
+-------------+-------------+ +-------+-------+ ----------
              |                       |
              v                       |
+---------------------------+         |          ----------
| Layer 3: User services    |         |
|   hamwd  → /dev/win/*     |         |
|   ipd    → /net/tcp,/udp  |         |
|   plumb  → /srv/plumber   |         |  Plan 9
|   timed  → /dev/time      |         |
|   srvfs  → /srv/<name>    |         |
+-------------+-------------+         |          ----------
              |                       |
              v                       v
+---------------------------+ +---------------+ ----------
| Layer 1: Native syscalls  | | Layer 2:      |
|   ~15 calls, Plan 9 shape | | Linux ABI     |
|   open/read/write/close   | | shims         |
|   rfork/exec/wait/exit    | | linux_abi/    |   Layer 1
|   bind/mount/chdir        | |   api_*  (.ko)|   = Plan 9
|   stat/fstat/create       | |   u_*    (ELF)|   Layer 2
|   errstr                  | |               |   = Linux
|                           | | linux numbers | (translates
|                           | | → file ops on |  L2→L1)
|                           | | Plan 9 paths  |
+-------------+-------------+ +-------+-------+ ----------
              |                       |
              v                       v
+---------------------------------------------+ ----------
| Layer 0: Kernel internals                   |
|   arch/, mm/, kernel/sched/, drivers/       | Linux
|   scheduler, page tables, IRQs, low-level   |
|   device drivers                            |
+---------------------------------------------+ ----------
```

**Influence column** is mandatory reading. Crossing the line is what
turns the OS into a Frankenstein. If you find yourself wanting Linux
shape at Layer 1, write a Layer 3 service instead. If you find
yourself wanting Plan 9 at Layer 2, you have a bug.

## What each layer is for

| Layer | Purpose | Source-tree home |
|------:|---------|------------------|
| 0 | Boot, scheduler, MM, IRQs, hardware drivers | `arch/`, `mm/`, `kernel/sched/`, `drivers/` |
| 1 | Native syscall surface (Plan 9-shaped) | `sys/src/9/port/` (new), `arch/x86/kernel/syscall.ad` (dispatch) |
| 2 | Linux compat layer for `.ko` + ELF | `linux_abi/` |
| 3 | User services (9P file servers) | `sys/src/cmd/` (new) |
| 4 | Wire protocols (VTNext, 9P-net) | docs only — protocols are spec, not source |
| 5 | Apps | `user/`, `mod/`, `tests/u-binary/`, plus stock Debian binaries at runtime |

## Boundary rules

1. **Layer 1 never exposes Linux concepts.** No `socket()`, `epoll`,
   `ioctl`. Linux callers go through Layer 2.
2. **Layer 2 never grows Plan 9 concepts.** Pure translation. Linux
   apps see Linux semantics. Nothing leaks back.
3. **Layer 3 services use only Layer 1.** A 9P server is a Hamnix
   app, full stop. No kernel reach-arounds, no Linux syscalls.
4. **Layer 0 doesn't know about personalities.** It exposes
   primitives (`task_clone`, `fd_table_dup`, `vm_map`). Layer 1 and
   Layer 2 compose those into user-visible behavior.
5. **Layer 4 protocols never enter the kernel.** VTNext parsing
   lives in `hamwd` (Layer 3); the kernel only ferries bytes
   to/from the device file. Exception: kernel may emit minimal
   VTNext to `wid=0` during early boot, before `hamwd` exists.

## Layer-of-record for each existing subsystem

| Subsystem | Current location | Layer | Notes |
|-----------|------------------|------:|-------|
| Scheduler | `kernel/sched/core.ad` | 0 | TaskStruct, schedule(), context switch |
| Memory mgmt | `mm/memblock.ad`, `mm/page_alloc.ad`, `mm/slab.ad` | 0 | memblock → page_alloc → slab → kmalloc |
| Page tables, IDT, GDT, TSS | `arch/x86/{boot,kernel,realmode}/` | 0 | Long-mode entry, traps, IRQs, syscall MSRs |
| LAPIC, PIT, IRQ routing | `arch/x86/kernel/{apic,i8259,time,irq}.ad` | 0 | Timing + delivery |
| PCI enum | `drivers/pci/pci.ad` | 0 | Used by every driver |
| Block: virtio-blk | `drivers/block/virtio_blk.ad` (via Linux shim today) | 0 | Native bare-metal driver |
| Block: AHCI | `drivers/ata/ahci.ad` | 0 | M16.89 native |
| Block: NVMe | `drivers/nvme/nvme.ad` (in flight) | 0 | Native bare-metal driver |
| NIC: virtio-net | `drivers/net/virtio_net.ad` | 0 | M16.88 native |
| Net stack (eth/arp/ip/udp/tcp/icmp/dhcp) | `drivers/net/*.ad` | **3 (eventually)** | Today in-kernel for bring-up; **target home is a `/net` 9P server under Layer 3** |
| Serial UART | `drivers/tty/serial/early_8250.ad` | 0 | Bytes |
| Console: VGA text, EFI GOP framebuffer | `drivers/video/console/{vga_text,fb_text}.ad` + `fb_font_8x16.S` | 0 | Bytes |
| PS/2 keyboard | `drivers/input/atkbd.ad` | 0 | Bytes |
| VFS | `fs/vfs.ad`, `fs/cpio.ad`, `fs/elf.ad` | 0/1 | Today the VFS *is* the Layer-1 file API; on migration, Layer 1 keeps these names and Layer 0 exposes a smaller primitive |
| ext4, FAT, ramfs | `fs/{ext4,fat,initramfs}.ad` | 0 | Underlying media drivers |
| Native syscall table | `arch/x86/kernel/syscall.ad`, `syscall_64.S` | **1** | Currently Linux-shaped; migrates to Plan 9 shape under `sys/src/9/port/` |
| Linux kernel ABI shims | `linux_abi/api_*.ad` (~1300 exports) | **2** | Loads stock Debian `.ko` |
| Linux userspace ABI shims | `linux_abi/u_syscalls.ad`, `u_libc.ad`, `u_ldso.ad` | **2** | Runs glibc/musl ELFs |
| Userland coreutils, hamsh | `user/*.ad` (~60 binaries) | **5** | Today calls Linux-shape native; migrates to Plan 9 calls |
| Kernel modules in Adder | `kernel-modules/*` (M1..M15) | 5 (running) → loaded by Linux .ko path → uses Layer 2 | Stays as regression baseline |
| Linux modules (stock .ko) | `tests/linux-modules/*.ko` | 5 (running) → Layer 2 | Stays |
| Linux ELF userland | `tests/u-binary/u_*` | 5 (running) → Layer 2 | Stays |
| hamwd display server | not yet built | 3 | New Layer 3 service for VTNext |
| ipd net daemon | not yet built | 3 | Owns the IP stack as a /net 9P server |
| Compiler | `compiler/*.py` | host tool | Not part of the OS — runs on the build host |

## Migration plan

The L-series and U-series compat suites must keep passing through
every step. The strategy is **introduce the Plan 9 shape alongside
the Linux-shape syscalls, then move callers, then retire the
Linux-shape natives**. Linux ABI shims are untouched until the very
end (and even then, only their internals).

### Phase A — Specs land (this pass)

Three docs (`architecture.md`, `native-api.md`, `vtnext-v2.md`) plus
a `sys/src/9/port/README.md` placeholder stake out the new
directory. No code moves. **All L+U tests keep passing trivially.**

### Phase B — Reserve the Plan 9 syscall numbers (additive)

In `arch/x86/kernel/syscall.ad`, allocate a new native-syscall range
for the Plan 9 primitives (numbers TBD in `native-api.md`'s
migration table — proposed 256..275 to leave 0..22 alone). Each new
number is a stub that returns `-ENOSYS` so the dispatch table is
declared but the calls are not yet usable. **All L+U tests keep
passing.**

### Phase C — Land `rfork`, `bind`, `mount`, `errstr` next to the existing calls

Implement the new primitives behind their new numbers. `SYS_CLONE`
stays. New: `SYS_RFORK`, `SYS_BIND`, `SYS_MOUNT`, `SYS_ERRSTR`.
Linux ABI uses `do_clone` directly; native code can start using
`rfork`. **All L+U tests keep passing.**

### Phase C.5 — Distro-shape namespaces

A *convention* on top of Phase C's primitives — no new kernel work.
A userland `distrorun` binary calls `rfork(RFNAMEG)` + `mount` of a
per-distro file server at the namespace's `/` + `bind` of shared
servers (/home, /net, /srv, /dev, /proc) back in, then `exec`. From
inside the namespace, paths resolve to a Debian / Ubuntu / SUSE file
server (the distro backing store). Init's namespace is unaffected
because nothing in the new namespace binds anything to it — there
is no "the real /" at the kernel level for either namespace to be
a view of.

This is the architectural answer to "how do we run Linux binaries
without polluting the OS identity." Linux compat is a namespace
shape a process opts into, not a property of the kernel or of a
privileged global FS.

See [`docs/distro-namespaces.md`](distro-namespaces.md) for the
full spec — including the layout comparison between init's
namespace and a Debian-shape namespace, boundary rules, why this
is NOT schroot (the kernel has no global /), backing store choices
(disk-backed via debootstrap first; `debfs` 9P server later), and
the `distrorun` entry point.

### Phase D — Stand up `hamwd` (Layer 3) using v1 single-window mode

`hamwd` opens `/dev/vtnext` (the serial multiplex), implements the
v1 protocol, exposes a single `/dev/win/0/{ctl,draw,present}` tree
via 9P-in-process (mount via `srv` channel). Existing v1 callers
keep working. **All L+U tests keep passing.**

### Phase E — Roll out v2: multi-window, wid prefix, reverse channel

`hamwd` flips to v2 wire format (probe handshake → V2 capability
line). v1 apps are recompiled against the new client lib (still
sees a window-shaped surface, just one). **L+U tests keep passing**
because they're console-only.

### Phase F — Move the network stack to `/net/`

A new `ipd` daemon owns `drivers/net/{arp,ip,tcp,udp,icmp,dhcp}.ad`.
It mounts at `/net/`. `drivers/net/virtio_net.ad` stays in-kernel
as a NIC driver — it exposes a /dev/eth0 raw-frames device file.
`ipd` opens that, runs the L3+L4 stack in userspace. **L+U tests
keep passing** — Linux ABI's `socket()` translates to opening
`/net/tcp/clone` (Plan 9 idiom).

### Phase G — Retire the Linux-shape native syscalls

Once every native userland binary has been recompiled against the
Plan 9 surface, the Linux-shape native numbers (`SYS_OPEN_WRITE`,
`SYS_SPAWN`, `SYS_LISTDIR`, `SYS_KILL`, `SYS_MKDIR`) get marked
deprecated, then deleted. Linux ELF callers were never using these
(they call `linux_abi/u_syscalls.ad`'s implementations); native
callers are migrated wholesale. **L+U tests keep passing.**

### Phase H — VTNext-v3 in-kernel framebuffer renderer

Optional. A kernel-side VTNext sink that draws to the EFI GOP
framebuffer using the same wire protocol. `hamwd` doesn't know
whether it's talking to pygame over serial or to a kernel sink. **L+U
tests keep passing** — orthogonal to syscall ABI.

### Test discipline

Every phase must end with green `bash scripts/test_l_track.sh` and
green `bash scripts/test_u_track.sh` (the U-track aggregator). A
phase that breaks either reverts before merge.

## File/directory retention vs re-homing

**Stays put (everyone's home is correct already):**

- `arch/*` (Layer 0)
- `mm/*` (Layer 0)
- `kernel/sched/*` (Layer 0)
- `kernel/printk/*` (Layer 0)
- `drivers/{pci,ata,nvme,input,tty,video}` (Layer 0)
- `drivers/block/*` (Layer 0)
- `fs/{vfs,cpio,elf,ext4,fat,initramfs_blob}.ad` (Layer 0 with a Layer-1 surface)
- `linux_abi/*` (Layer 2 — both kernel and user ABI)
- `compiler/*` (host tool, not in OS layering)
- `kernel-modules/*` (Layer 5 — regression baseline)
- `tests/{u-binary,linux-modules}/*` (Layer 5 — regression baseline)
- `user/*` for now (Layer 5; some files will be rewritten to use Plan 9 surface during Phase G)

**Re-homes during migration:**

- `arch/x86/kernel/syscall.ad` keeps the dispatch role; the **bodies**
  for new syscalls move to `sys/src/9/port/sysproc.ad` (rfork/exec/
  wait/exit), `sys/src/9/port/syscall.ad` (open/read/write/close/
  seek/stat/fstat/create), `sys/src/9/port/chan.ad` (bind/mount/
  unmount), `sys/src/9/port/error.ad` (errstr).
- `drivers/net/{arp,ip,tcp,udp,icmp,dhcp}.ad` move to `sys/src/cmd/
  ipd/` once kernel-side bring-up stabilises and a daemon scaffold
  exists. Until then they stay in `drivers/net/`.

**New directories created during migration:**

- `sys/src/9/port/` — Plan 9-shape syscall bodies.
- `sys/src/9/cdev/` — Plan 9-shape device-file backends (`devcons`,
  `devtime`, `devpid`, `devrandom`).
- `sys/src/cmd/hamwd/` — display server (Phase D).
- `sys/src/cmd/ipd/` — network daemon (Phase F).
- `sys/src/cmd/plumb/` — plumber (deferred).
- `sys/src/cmd/srvfs/` — `/srv/` registry server (Phase D/E
  prerequisite — `mount` needs `srvfd` to come from somewhere).

## Why this shape

- **Layer 0 stays Linux-shaped** because the porting unit is
  bounded: read `mm/page_alloc.c`, port to `mm/page_alloc.ad`. We
  already have receipts (M1..M16.91) that this works.
- **Layer 1 is Plan 9-shaped** because Plan 9's syscall API is
  smaller (~40 calls vs Linux's 350+) and is the only surface that
  has ever made "everything is a file" actually useful instead of
  cosmetic.
- **Layer 2 absorbs all Linux compat** so Linux apps can't infect
  the native API by demanding their concepts upstream.
- **Layer 3 is where the OS personality lives** — hamwd, ipd,
  plumb. Adding a feature usually means adding a Layer 3 service,
  not a Layer 1 syscall.
- **Layer 4 protocols are external by design.** VTNext over serial
  to a pygame on a laptop is the same protocol as VTNext to a local
  framebuffer — the kernel doesn't need a graphics stack.

## What this design does NOT include

- **No DRM / Mesa / Vulkan / Wayland / X11.** Graphics is VTNext
  end-to-end. If we ever need 3D, the renderer (laptop pygame OR
  local framebuffer process) handles it; the OS doesn't.
- **No epoll/kqueue.** Plan 9 doesn't have them; Layer 2 implements
  them on top of `read` blocking semantics when Linux callers need.
- **No ioctl.** Control surfaces are `ctl` files. Layer 2 translates
  Linux `ioctl()` into `open(.../ctl)` + `write()` patterns.
- **No /proc/sys.** Use `/proc/<pid>/*` and per-service `/srv/*`
  paths instead.
- **No systemd-shape init.** init is a hamsh script reading `/etc/rc`
  (already shipped). New services come up as Layer 3 daemons
  launched from there.

## Reading order for a new contributor

1. This document.
2. `native-api.md` — the syscall surface and the migration table.
3. `vtnext-v2.md` — the graphical wire protocol.
4. `README.md` — current state of the implementation against this
   architecture.
5. `linux_abi/TARGET_ABI.md` — the pinned Linux ABI we translate
   into.

## References

Plan 9 sources cited throughout `native-api.md`:

- `/sys/src/9/port/sysproc.c` — rfork, exec, wait, exit
- `/sys/src/9/port/chan.c` — namespace, bind, mount
- `/sys/src/9/port/sysfile.c` — open, read, write, close, seek, stat
- `/sys/src/9/port/dev.c` — the device driver pattern
- `intro(2)`, `bind(2)`, `mount(2)`, `rfork(2)` (Plan 9 4th ed.
  Programmer's Manual, Vol. 1)
