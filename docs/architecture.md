# Hamnix architecture

A layered OS that **looks like Plan 9** to native apps, **looks like
Linux** to imported `.ko` modules and ELF binaries, and **looks like
Linux internally** because that's where the porting work is bounded.
Each layer has exactly one source of design influence. The
translations between layers are explicit.

> **Note: the window system is the Plan 9 `rio` model.** Hamnix's
> display layer is a userspace 9P file server — see [`rio.md`](rio.md).
> Each window is a per-process namespace; programs draw and read input
> by opening files under `/dev`. An earlier serial/TCP byte-stream
> design ("VTNext") was considered and retired before any of it
> shipped; references to it in older docs are stale.

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
|   rio draw protocol       | |    delivers   | Hamnix +
|   9P (mounts, /srv, net)  | |    bytes)     | Plan 9
+-------------+-------------+ +-------+-------+ ----------
              |                       |
              v                       |
+---------------------------+         |          ----------
| Layer 3: User services    |         |
|   rio    → /dev/win/*     |         |
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

## What runs where: native tools vs distro tools

This distinction is load-bearing. Get it wrong and you reimplement
Linux userland in Adder.

| Category | Where it runs | Examples |
|----------|---------------|----------|
| **Distro userland** (apt, dpkg, bash, coreutils, postgresql, nginx, python3, ...) | **Inside a Linux namespace** — `enter linux { /usr/bin/apt install … }`. Real Debian binaries served from the distro backing store. | `apt`, `dpkg`, `dpkg-deb`, `bash`, `apt-get`, `dpkg-query` |
| **Native Hamnix tools** (the shell, the editor, the init system, the system service supervisor) | **In init's default namespace.** Adder binaries. They speak the Layer-1 Plan-9 syscall surface, never wrap distro binaries. | `hamsh`, `ed`, `motd`, `sshd` (currently — see [`HAMSH_SPEC.md`](HAMSH_SPEC.md)) |

### Anti-pattern: don't reimplement Linux userland in Adder

If a tool's job is "manage Debian packages" or "extract a .deb" or
"run apt-get update," it is a **Linux userland tool**. Run real
Debian inside the Linux namespace. **Do not write an Adder
implementation of it.**

The reflex to add `user/apt.ad`, `user/dpkg.ad`, `user/wget.ad`,
`user/curl.ad`, `user/tar.ad` is the Frankenstein mistake. We did it
once with `user/apt.ad` + `user/dpkg.ad` + `user/dpkg_deb.ad`, spent
months on it, then deleted all three (commits `0de1c63`..`3ff5bfc`,
2026-05-26) and replaced them with `enter linux { /usr/bin/apt … }`
plus real Debian binaries staged at `/var/lib/distros/default`. Don't
make that mistake twice.

Heuristic: if the tool exists in Debian, run it from Debian. If you
need it to interoperate with Hamnix-native concepts (Plan 9 file
servers at `/srv`, `/net`, `/proc`), shim THAT layer — not the tool
itself.

### Aspirational: native Hamnix package manager (default-namespace tool)

A future native package manager — call it `hpm` — would manage
**Hamnix-side** state: native services, kernel modules, the rootfs
ext4 image's contents, the L-shim shape, framework `.ko` registry.
It is NOT a replacement for apt; it does not install Debian packages.
It runs in init's default namespace alongside hamsh, configures
Hamnix itself, and never enters a Linux namespace.

The contract:
- `apt` (Linux ns) manages `/var/lib/distros/<distro>/` content
- `hpm` (default ns, future) manages Hamnix's own services and
  kernel-side state — `etc/rc.boot`, the framework module set,
  the rootfs image layout

If both ever need to coordinate (e.g. "user wants a service that's
in Debian, install via apt, then register with init"), that's
a Layer 5 application-level workflow — not a `hpm`-calls-apt
shim. The two managers stay in their own namespaces.

## What each layer is for

| Layer | Purpose | Source-tree home |
|------:|---------|------------------|
| 0 | Boot, scheduler, MM, IRQs, hardware drivers | `arch/`, `mm/`, `kernel/sched/`, `drivers/` |
| 1 | Native syscall surface (Plan 9-shaped) | `sys/src/9/port/` (new), `arch/x86/kernel/syscall.ad` (dispatch) |
| 2 | Linux compat layer for `.ko` + ELF | `linux_abi/` |
| 3 | User services (9P file servers) | `sys/src/cmd/` (new) |
| 4 | Wire protocols (rio draw protocol, 9P) | docs only — protocols are spec, not source |
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
5. **Layer 4 protocols never enter the kernel.** The rio draw
   protocol is parsed in `rio` (Layer 3); the kernel only ferries
   bytes to/from the device file and owns the raw framebuffer +
   input devices.

## Filesystem layout and discovery

Per Plan 9 there is **no global rootfs**. Block devices found by the
kernel become **file servers** that namespaces bind at their chosen
paths. Bind freezes the source Chan at bind time (plain Plan 9 chan.c
behavior); already-bound paths cannot be yanked away by hot-plug.

**Two allocation models, explicit, no case-as-marker**:

| Model | Trigger | Naming | Stack |
|-------|---------|--------|-------|
| **Anonymous** | no `.hamnix-roots` sentinel | `#part0`, `#part1`, … (sequential by discovery) | none — sequential names never collide |
| **Named** | sentinel present | `#<word>` per sentinel entry (`#home`, `#distro`, `#apt-cache`) | LIFO on collision between partitions; depth cap 9 |

Sentinel format (`.hamnix-roots` at partition root):

```
home      home/
distro    debian-bookworm/
apt-cache var/cache/apt/
```

→ kernel posts `#home`, `#distro`, `#apt-cache` as separate file
servers (FULL word, not first char). The `#` parser accepts both
single-char built-ins (`#c`, `#p`, `#s`, `#/`) and multi-char role
names. Reserved words = the built-in device-letter set today (`c p
s /`; source of truth in `sys/src/9/port/dev.ad`); sentinel entries
naming a reserved word are rejected at parse time.

**Stack only matters for true duplicates**: two physical disks both
shipping `home` in their sentinels. After step 2 (full-word names),
this is the only ambiguity that survives. Push on mount, pop on
unmount. Positional names `#home`, `#home2`, …, `#home9` are
LIFO-unstable; use them for inspection / interactive picking, not for
persistent references.

**Stable instance identity** for persistent references: every
partition is addressable as `#by-id/<GPT-partition-UUID>`. NEVER
moves. Scripts and configs that must always reference a specific
disk use the by-id alias:

```
bind '#by-id/12345-abcdef' /n/mydisk
```

**Inspection**: `/proc/fs/by-name/<word>` dumps the stack for a
named slot; `/proc/fs/by-id/<partuuid>` dumps the partition identity;
`/proc/fs/anonymous` lists `#partN` → partuuid mappings. Load-bearing
for "what does `#home` actually resolve to right now" debugging.

See [`rootfs_partition.md`](rootfs_partition.md) for the full semantics
(bind freeze, stack rules, sentinel format, hamsh-bind safety warning,
migration impact).

**Bind syntax is source-first, target-second**: `bind SRC DST`. The
underlying `SYS_BIND(src, dst, flag)` syscall (see
[`native-api.md`](native-api.md#bind)) matches both Linux's `mount
source target` AND Plan 9's `bind new old` — they're both already
source→target. Earlier hamsh recipes like `bind /srv '#s'` were just a
plain bug in the wrapper's arg order; not a "Plan 9 style" choice.

```
bind '#s' /srv          # built-in device, single char
bind '#home' /n/home    # sentinel-derived, full word
```

See [`distro-namespaces.md`](distro-namespaces.md) for how the linux
namespace recipe uses these primitives.

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
| `/net` file tree (TCP/UDP as files) | `drivers/net/devnet.ad` | **1** | ARCH §10: the Plan-9-shaped networking surface — `/net/tcp/clone`, `/net/<proto>/<N>/{ctl,data,status,local,remote}`. A kernel-side device backed by the in-kernel TCP/UDP stack. Replaces the retired native socket syscalls; the Linux-ABI `socket()` is a Layer-2 consumer of it. |
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
| rio display server | not yet built | 3 | New Layer 3 service — file-based window system (see `rio.md`) |
| ipd net daemon | not yet built | 3 | Owns the IP stack as a /net 9P server |
| Compiler | `adder/compiler/*.py` (submodule; top-level `compiler/` is a symlink) | host tool | Not part of the OS — runs on the build host. Lives in its own repo, [HamnixOS/adder](https://github.com/HamnixOS/adder); Hamnix consumes it as a git submodule pinned to a specific commit (`scripts/test_adder_pin.sh` enforces the pin in CI). |

## Migration plan

The L-series and U-series compat suites must keep passing through
every step. The strategy is **introduce the Plan 9 shape alongside
the Linux-shape syscalls, then move callers, then retire the
Linux-shape natives**. Linux ABI shims are untouched until the very
end (and even then, only their internals).

### Phase A — Specs land (this pass)

Three docs (`architecture.md`, `native-api.md`, `rio.md`) plus
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

### Phase C.5 — Distro-shape namespaces (shipped)

A *convention* on top of Phase C's primitives — no new kernel work.
`etc/rc.boot` defines `linux = ns clean { bind '#distro' / ; bind
/home /home; bind '#c' /dev ; … }` (and `debian` as a duplicate-body
alias). `enter linux { /usr/bin/apt … }` then runs real Debian
binaries inside that namespace; the rootfs partition's file server
(`#distro`) is what `/` resolves to. Init's namespace is unaffected
because the linux ns is `ns clean` — a fresh empty Pgrp with only
the binds the recipe declares.

This is the architectural answer to "how do we run Linux binaries
without polluting the OS identity." Linux compat is a namespace
shape a process opts into, not a property of the kernel or of a
privileged global FS.

See [`docs/distro-namespaces.md`](distro-namespaces.md) for the
full spec — including the layout comparison between init's
namespace and a Debian-shape namespace, boundary rules, why this
is NOT schroot (the kernel has no global /), and backing store
choices.

### Phase D — Stand up `rio` (Layer 3), one-window skeleton

`rio` posts a srvfd via `srv_post`, serves a one-window file tree
(`/dev/cons`, `/dev/mouse`, `/dev/text`, …) via 9P-in-process, and
runs `hamsh` inside it. No drawing yet — text only. **All L+U tests
keep passing** because they're console-only.

### Phase E — Multi-window via `/dev/wsys`

`rio` implements `wsys new`: each new window gets its own
namespace, its own per-window FIFOs, its own srvfd. This proves the
load-bearing invariant — events route to exactly one window's
`/dev/mouse` at a time. **L+U tests keep passing** because they're
console-only. See [`rio.md`](rio.md) for the full phase breakdown.

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

### Phase H — Framebuffer-backed `/dev/draw`

Optional. `rio` lights up `/dev/draw/new` against the EFI GOP
framebuffer and implements the Plan 9 draw protocol subset. **L+U
tests keep passing** — orthogonal to syscall ABI.

### Test discipline

Every phase must end with green `bash scripts/test_l_track.sh` (the
.ko regression suite) and the U-series tests under `scripts/test_u*.sh`
(the individual ELF tests; no single aggregator script). A phase that
breaks either reverts before merge.

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
- `sys/src/cmd/rio/` — display server (Phase D; see `rio.md`).
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
- **Layer 3 is where the OS personality lives** — rio, ipd,
  plumb. Adding a feature usually means adding a Layer 3 service,
  not a Layer 1 syscall.
- **Layer 4 protocols are external by design.** The rio draw
  protocol is bytes on a file; the kernel only owns the raw
  framebuffer and input devices, not a graphics stack.

## What this design does NOT include

- **No DRM / Mesa / Vulkan / Wayland / X11.** Graphics is the rio
  file-based draw protocol end-to-end. If we ever need 3D, an app
  software-rasterises and writes pixels via `draw` ops; the OS
  doesn't ship a GPU stack.
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
3. `rio.md` — the file-based window system and its draw protocol.
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
