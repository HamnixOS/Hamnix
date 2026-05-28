# Hamnix TODO

Open work, not yet milestone-scheduled. The **Kernel Roadmap** below is
the priority spine — it is dependency-ordered and **Phase D is the
prerequisite gate**. Sections after it are areas the roadmap
deliberately excludes (metal bring-up, userspace polish, storage-driver
maturity).

> **Check [`STATUS.md`](STATUS.md) before picking an item** — it is the
> source of truth for what shipped. Large chunks already closed: real
> hardware boot (Intel Skull Canyon NUC end-to-end on 2026-05-25,
> default ISO, USB keyboard works via the L-shim USB-HC bridge,
> hamsh prompt, `enter linux { /bin/sh }`), `kernel_cond_resched`
> for preemptive syscall-context polls (`b08853e`), EFI memory-map
> walker (>240 MiB RAM on UEFI), per-task ELF mapping (closed
> silent-execve on bare metal), the Plan 9 native-syscall surface,
> per-process namespaces, named file-server stacks + `#by-id`
> aliases + bind-freeze, separate ext4 rootfs partition with
> `.hamnix-roots` sentinel (`#distro`), TLS 1.3 + X.509 chain
> validation, **real Debian apt/dpkg running inside `enter linux`**
> (the hand-rolled `user/apt.ad`/`user/dpkg.ad`/`user/dpkg_deb.ad`
> were retired 2026-05-26), CPython + busybox as musl static-PIE,
> fork → copy-on-write (incl. mmap VMAs), the higher-half ELF64
> kernel, preemptive scheduling, the SSH-2.0 server (now wired into
> `/etc/rc.boot` as a detached service), `§5` Layer-2 async
> (epoll/eventfd/timerfd/signalfd/O_NONBLOCK), the `/net` 9P file
> tree + TLS-over-`/net` (Layer 1 is now Plan-9-shaped end-to-end,
> zero BSD socket syscalls), native `/net/icmp` + native `ping`
> (incl. loopback shortcut), the hamsh clean-sheet rewrite with
> init/rc + line editor + Tab completion, the clean linux/debian
> namespace recipe (`bind '#distro' /`), the L-shim USB-HC bridge
> (`f426aee`) that carries `xhci_pci_probe` end-to-end,
> **`hpm` v1** (binary-only package manager with BFS dep solver +
> conflicts, 5 packages at `https://255.one/`, uid==1 gate),
> **the `hpm install`-driven installer** (`etc/install.hamsh`;
> `scripts/test_installer_full.sh` 4-stage PASS — build ISO →
> install → reboot from disk → first-boot ext4 grow-to-fit),
> the **Plan-9-shape security model** end-to-end (hostowner uid 1,
> `/dev/auth` cdev, SHA-512-crypt, VFS perm check, `newshell` +
> `read` hamsh builtins, no setuid bits — see `docs/security.md`),
> the **in-init service supervisor + `/proc/svc` mirror**
> (`svc start/status/restart`, `SYS_SVC_PUBLISH=291`), and the
> Adder compiler **split out to its own
> [HamnixOS/adder](https://github.com/HamnixOS/adder) repo**
> consumed here as a submodule (pin at `8e0e420` — methods +
> `Ptr[T]+N` scaling + `Percpu` aggregate fixes).

**Project-direction docs:** [`docs/architecture.md`](docs/architecture.md)
(layered model, boundary rules, migration phases),
[`docs/native-api.md`](docs/native-api.md) (Layer 1 Plan 9 syscalls),
[`docs/hamUI.md`](docs/hamUI.md) (window system; renamed from rio.md
2026-05-27), [`README.md`](README.md)
(current snapshot).

---

> ## ⚠ Namespace law — read before touching any shim / distro / package work
>
> Hamnix is a **Plan 9-shaped system. There is NO global filesystem
> route.** A process sees a path only because something was *bound or
> mounted into its own namespace*. **No work may write to a global
> `/var`, `/usr`, `/etc`, `/var/lib/dpkg`, `/var/cache/apt`, `/var/www`.**
> All Linux-binary-shim and distro/package state lives inside a
> distro-shaped namespace exported by the userland **`distrofs`** 9P
> daemon; a shim is launched `rfork(RFNAMEG)` → mount/bind `distrofs`
> → exec. A TODO item is mis-shaped if it says "write X to `/var/...`"
> without "...in the shim's distrofs namespace" — fix the wording.
> See `memory/feedback_distro_namespace.md`, `docs/distro-namespaces.md`.

---

# Kernel Roadmap — Plan 9-central (dependency-ordered)

**Direction:** Plan 9 is the *core architecture*, not a layer retrofitted
onto a Linux-shape kernel. 9P + per-process namespaces are the spine; the
Linux VFS, the fd table, and the Linux ABI are *consumers* of that spine,
never the substrate beneath it.

This roadmap is dependency-ordered. **Phase D is the prerequisite gate** —
most resource-model work is mis-shaped (bolted on as a VFS special) until
the chan/9P layer is the primary resource path. Honor the order rather
than dispatching every section in parallel.

Markers: `[x]` done · `[~]` in flight · `[ ]` open · `(ARCH)`
architectural inversion · `(NEW)` not previously tracked.

## ⚠ Boundary-discipline law — defend in every review

**Layer 1 (native) stays pure 9P / namespace. No exceptions.** The
non-file modern mechanisms — `io_uring`, `epoll`, `futex`,
signalfd/eventfd/timerfd — are the antithesis of "everything is a file."
They are permitted **only inside Layer 2** as confined kernel objects
that exist to satisfy Linux guests. The moment one becomes a dependency
of native code or of the resource model below Layer 1, the architecture
has been retrofitted backwards. The Linux ABI is a guest allowed its
warts; the warts must not leak downward.

## PHASE D — Plan 9-central core  ⟵ PREREQUISITE GATE, front of the line

The inversion: `namec` + a `devtab`-style dispatch + a real `Mnt` becomes
the one true resource path. A local-device Chan and a mounted-9P Chan are
the *same type* with the *same operation interface* — the consumer never
knows which it holds.

- [x] **(ARCH) Real `chan_attach` over a stored srvfd** — Tversion /
  Tattach / Twalk / Topen / Tread / Twrite / Tclunk; install a real
  `Mnt` so Chan ops on a mounted server marshal into 9P T-messages.
  (landed pre-Phase-D as 9P V1–V4.1; confirmed by `4964a6b`)
- [x] **(ARCH) `/srv/<name>` srvfd channel posting** — so `mount` has a
  real conversation to consume. (`sys_srv_post`/`sys_srv_open` + `devsrv.ad`)
- [x] **(ARCH) `namec()` + `devtab` dispatch as the universal open
  path** — *all* opens (native AND Linux-ABI) resolve through the
  process's mount table to a `Chan`; replaced the `FD_*_MARK`
  special-casing in `fs/vfs.ad`. (`4964a6b` — `sys/src/9/port/namec.ad`)
- [x] **(ARCH) Per-Pgrp mount-table deep-copy on `rfork(RFNAMEG)`** —
  `pgrp_clone` does a real field-by-field deep copy into a fresh Pgrp.
- [x] **(ARCH) Convert the 12 `FD_*_MARK` cdevs into served Chans** —
  all 14 cdevs are now `devtab` Chans (`4964a6b`); the `FD_P9_MARK`
  opener was deleted, dispatch arms kept as a non-regressing net.
- [ ] **(ARCH) Layer-2 `/proc → /dev` translation becomes a namespace
  bind** — retire the `_u_translate_proc_to_dev` string-rewrite; the
  Linux-ABI process gets `bind '#c' /proc`-shape entries instead.
- [x] **(ARCH) Route the Linux ABI through the chan layer** —
  `linux_abi/u_syscalls.ad` open/read/write resolve through `namec` →
  devtab/mountrpc; the Linux ABI is a consumer of the chan spine
  (`4964a6b`). Deferred: `#c` console alias still uses `FD_CONS_MARK`.
- [ ] Union mounts MBEFORE / MAFTER (flag recorded; longest-prefix only).
- [x] ~~Collapse per-subdir binds in `distrorun.ad`~~ — `distrorun.ad`
  retired (`1cdc34f`); the linux ns recipe in `etc/rc.boot` is now
  declarative hamsh: `linux = ns clean { bind '#distro' / ; ... }`.
- [ ] `create(260)` DMDIR → real directory create (needs tmpfs/ext4 mkdir).
- [ ] `stat`/`fstat` per-backend hooks (tmpfs/fat/ext4/socket).
- [ ] `fd2path` exact open()-time path (per-fd path slot in `TaskStruct`).
- [ ] `wstat`/`fwstat` fields: `length` (truncate), `mtime`, `gid`/`muid`,
  `mode` storage.
- [~] **distrofs migration capstone:** `dpkg -i` (`463c3e8`) and
  `apt install` (`d886f17`) of a real `.deb` both land all files into
  the distrofs namespace under `nsrun`, verified with Debian `hello`.
  Remaining: delete the global `/var` tmpfs (the last Namespace-law
  debt) once nothing else depends on it.
- [x] distrofs persistent backing — `ea22407`: RAM-cache-over-ext4,
  state serialized to an ext4-backed image, snapshot on dirty-clunk/
  remove/EOF. An installed file survives a full reboot (verified).

## §1 Process model & address space  (gates threads, the loader, all real software)
- [x] VMA deep-copy on fork; copy-on-write pages (COW fault handler +
  refcounted shared frames) — landed, whole address space incl. mmap.
- [x] VMA share on RFMEM / thread address-space sharing — pthreads run.
- [x] `rfork` RFMEM thread path — caller `child_stack` + CLONE_SETTLS
  TLS, Layer-1 primitives only (`e32ec28`).
- [x] `rfork` RFNOWAIT detach — `detached` flag severs `parent_pid`,
  `task_exit_current` self-reaps, `wait4` gets -ECHILD (`e32ec28`).
- [x] MAP_SHARED with cross-process coherence — anon MAP_SHARED maps
  the same refcounted frames across fork (`e32ec28`).
- [x] `mprotect` / `madvise` / MAP_FIXED maturity — range-walk PTEs +
  VMA split, MAP_FIXED replaces, MADV_DONTNEED zeroes (`e32ec28`).

## §2 Concurrency primitives → threads  (needed by glibc)
- [x] `futex(2)` + `%fs`-base TLS (`arch_prctl`) — **Layer 2 only**;
  glibc + musl pthreads programs verified.

## §3 Signals
- [x] Full Linux-ABI signals — `rt_sigaction`/`rt_sigprocmask` + masks,
  `rt_sigframe` (siginfo + ucontext) setup, `rt_sigreturn`, `tkill`
  (`abc5e73`).
- [x] SIGCHLD + reaping (`wait4` pid==-1/WNOHANG, WIFSIGNALED), SIGPIPE
  on broken pipe/socket, SIGTERM/SIGKILL (SIGKILL uncatchable)
  (`abc5e73`).
- [~] Plan 9 note follow-ups: `NDFLT` default action done (`abc5e73`);
  `note_group`-wide + cross-task `/proc/<pid>/note` deferred — need a
  deferred note-delivery hook in the native trap-return path.

## §4 Dynamic linking / loader
- [x] `dlopen`/libdl + DT_NEEDED resolution — handled by the stock
  glibc ld.so the loader maps; `dlopen()`+`dlsym()` verified
  (`6d9898e`, test_u44). Enabling kernel fixes: `MAP_FIXED` BSS-overlay
  zero-fill (`mm/vma.ad`) and a stable `fstat` `st_ino` (`fs/vfs.ad`).
- [x] Interpreter + library lookup routed through the chan/namespace
  layer — `ns_blob_ptr` runs paths through `resolve_path()` (`6d9898e`).
- [x] AT_BASE/AT_ENTRY/AT_PHDR auxv — anchored to load addresses;
  namespace-routing does not perturb them (`6d9898e`).
- [x] **Capstone:** a stock dynamically-linked binary runs end-to-end
  inside a Linux-shape namespace — PT_INTERP + DT_NEEDED both resolved
  through the namespace bind (`6d9898e`, test_u43). (Historically
  framed as "distrorun namespace"; that binary was later retired in
  favour of `enter linux { ... }` per `1cdc34f`.)

## §5 Modern async I/O  (**Layer 2 only**, depends on §2/§3)
- [x] `epoll` (`epoll_create1`/`ctl`/`wait`), `eventfd`, `timerfd`,
  `signalfd`, real `poll`/`select` — `39b4001`, Layer-2 leaf module
  `linux_abi/u_epoll.ad`. epoll-based Linux daemons can now run.
- [x] O_NONBLOCK end-to-end — `SOCK_NONBLOCK`/`O_NONBLOCK`/`fcntl`,
  EAGAIN on would-block across socket + pipe fds (`39b4001`).
- [ ] `io_uring` SQ/CQ rings — deferred (separate, much larger; epoll
  covers the overwhelming majority of real Linux daemons).

## §6 Timekeeping (vDSO)
- [x] `clock_gettime` CLOCK_MONOTONIC/REALTIME; TSC high-res monotonic
  clock; LAPIC timer calibration fix — `96032e8`.
- [ ] vDSO: map `gettimeofday`/`clock_gettime` without syscall overhead.

## §7 Entropy / RNG  (served Chans post Phase D)
- [ ] ChaCha20 CSPRNG (replacing xorshift64) + RDRAND/RDSEED seeding;
  `getrandom(2)` repointed at the random Chan; distinct non-blocking
  `/dev/urandom` + blocking `/dev/random`.

## §8 SMP & scheduler
- [x] Preemptive scheduling — the timer preempts a CPU-bound userland
  task (per-task quantum, ring-3 preemption points).
- [ ] Per-CPU runqueues + real SMP scheduling (AP bringup works;
  single-rq today); load balancing / work stealing; CPU affinity.

## §9 Interrupts & PCI
- [x] MSI-X: PCI cap-walk (0x11), table mapping, per-vector LAPIC
  programming — virtio-net routes one vector per virtqueue
  (RX/TX/config), verified delivery (`b15ffc4`).
- [x] virtio-blk INTx wiring (vector 0x43) — `b15ffc4`.
- [x] Multi-IOAPIC: `acpi_parse_ioapics()` caches the MADT type-1
  list; redirects select the owning IOAPIC by GSI range (`b15ffc4`).

## §10 Networking  (off critical path — parallelizable)
- [x] **(ARCH) `/net` 9P file tree** (`8e70852`) — TCP/UDP exposed as
  `/net/tcp/clone` + `/net/<proto>/N/{ctl,data,status}` (`devnet.ad`);
  native code uses `/net` files via `user/net9.ad`; Linux `socket(2)`
  is a Layer-2 consumer of `/net`. Native `BIND`/`LISTEN`/`ACCEPT`
  syscalls retired; `httpd`/`sshd`/`u_server`/apt-HTTP migrated.
- [x] **(ARCH) TLS over `/net`** (`9402fc7`..`747844d`) — TLS 1.3
  record layer runs over a `/net` connection via `_tls_wire_send`/
  `_tls_wire_recv`; a `tls <hostname>` ctl on a `/net/tcp` conn
  upgrades it. `apt-HTTPS`, in-kernel `http_get`, and `u_tlstest`
  migrated. `SYS_SOCKET`/`SYS_CONNECT`/`SYS_TLS_CONNECT` retired:
  **Layer 1 exposes zero BSD socket syscalls.**
- [ ] Congestion control: slow-start + congestion-avoidance (RFC 5681),
  NewReno or CUBIC.
- [ ] Multi-listener accept queue / wider TCB table; window scaling +
  SACK + timestamps.
- [x] UDP sockets (`socket`/`bind`/`connect`/`sendto`/`recvfrom`),
  `getsockopt`/`setsockopt`, ICMP dest-/port-unreachable + received
  ICMP-error latching, socket-fd slot release at task exit — `5a499f3`.
- [ ] Still open: generic unicast ARP helper; ICMP time-exceeded/
  redirect.

## §11 DNS resolver  (off critical path — parallelizable)
- [x] Multiple A-records (return all + round-robin), PTR/MX/SRV record
  types, TCP/53 fallback for > 512 B — `461a134` (`drivers/net/dns.ad`,
  6/6 offline self-tests + live multi-A resolve).
- [ ] AAAA records — deferred; gated on an IPv6 header (IP layer is
  IPv4-only today).

## §12 Filesystem write maturity & persistence
- [x] ext4 `rename`, `truncate`/`ftruncate`, per-inode mtime, `fsync`
  + `blk_flush` barrier, and the FAT32 write path — `63198b2`,
  write-then-reboot persistence verified.
- [ ] Documented follow-ups: ext4 truncate on index-node (eh_depth>0)
  files; growing a full ext4 directory block; multi-cluster FAT
  directories.

## §13 cdev / proc field completions
- [x] `/dev/uptime` idle column, `/dev/loadavg` real EWMA, `/dev/stat`
  real columns, `/dev/diskstats` counters (`ad3e5ad`); `/dev/hostname`
  already persisted.
- [x] Layer-2 `/proc` extensions: `/proc/{stat,mounts,diskstats}`,
  `/proc/self`, per-pid `/proc/<pid>/{stat,cmdline,comm,maps}`,
  `/proc/cmdline` (`ad3e5ad`).
- [x] Real `KmallocLive` per-cache slab walker (`ad3e5ad`).
- [ ] Still open: `/proc/net/*`; per-backend errstr (ext4/fat/blk) +
  user-mode `perror` helper (deferred).

## §14 Resource control & security  (stretch)
- [ ] Per-namespace CPU/memory caps (ride the namespace model, not Linux
  cgroups); `seccomp-bpf`; POSIX capabilities (drop-root daemons).

## §15 Compiler / language infra  (off critical path — parallelizable)
- [x] Unsigned shift/divide codegen (`shrq`/`divq` honoring signedness).
- [x] First-class function pointers `Fn[R, A...]` with SysV indirect-call
  codegen — `d321f53`; removed the `asm_volatile("call *%rax")` dispatch
  hacks (IRQ table, block vtable, netfilter, module init, timers).
- [ ] `match`/`case` tokenization → implement.

## §16 Build / initramfs
- [x] cpio `NR_FILES` 192 → 8192 so a real debootstrap tree (~5000
  files) fits — `40ebdc0` (prereq for the §4 capstone).

## §17 L-track stock-Linux `.ko`  (lowest priority)
- [ ] `MAX_EXPORTS` bump; `usbcore`+`xhci_hcd`, `libphy`, `8021q`,
  `nf_conntrack` core. Weigh against native drivers before spending.

## Critical path & parallelization
The dependency-ordered critical path is **COMPLETE**: Phase D
(`4964a6b`) → §1 (`e32ec28`) → §2 (futex/TLS) → §4 (dynamic loader,
`6d9898e`) are all landed — a stock dynamically-linked binary now runs
inside a namespace. Also landed: §3 (signals, `abc5e73`), §9, §11,
§12 (fs write, `63198b2`), §13 (cdev/proc, `ad3e5ad`), §15, §16.
Remaining, all off the critical path and parallelizable: §5 (Layer-2
async), §6 (vDSO only), §7 (entropy), §10 (networking), §14, §17.
Everything in §5 is Layer-2-only per the boundary law.

---

# Metal bring-up  (human-in-the-loop lane — excluded from the roadmap)
- **[x] EFI memory-map walker** in `arch/x86/kernel/e820.ad`
  (`83f8de8` + `2fb1eb6`): UEFI path now consumes the firmware
  `EFI_MEMORY_DESCRIPTOR` array (64 KiB buffer, `7365746` for real
  laptop firmware that returns 100–300 descriptors at 96/128 B stride),
  unlocking RAM > 240 MiB. 935 MiB free at `-m 1G` under OVMF.
- **[x] `kernel_cond_resched`** (`b08853e`): SYSCALL entry clears
  EFLAGS.IF; a kernel-side `while jiffies < deadline:` poll then
  pins the CPU forever because the LAPIC timer can't fire. The fix
  opens an IRQ window inside every busy-poll via `sti + hlt + cli`,
  unblocking the scheduler. Was the real root cause of the historical
  "NUC freeze after sshd" misdiagnosis.
- **[x] L-shim USB-HC bridge** (`f426aee`): `xhci_pci_probe` runs
  end-to-end via the `struct usb_hcd` / `struct hc_driver` shim layer
  in `linux_abi/api_usb_hcd.ad`, with force-shim for the .ko entry
  path. USB keyboard input on the NUC works through this path.
- **[~] xHCI hand-rolled v1 bare-metal sub-skip** (`71961b3` + later):
  The hand-rolled `drivers/usb/xhci.ad::_xhci_v1_bringup`'s HCH-clear
  MMIO poll still wedges on real Intel NUC silicon; CPUID
  0x40000000 hypervisor-leaf detection skips that sub-path on metal
  (`ENABLE_XHCI_FORCE_INIT=1` overrides). The earlier global xhci.ko
  load-chain skip (`c444044`) was **reverted in `2888b7c`** because
  the wedge it protected against didn't exist in the .ko load path;
  the only thing that touches USBSTS is `_xhci_v1_bringup`.
- **[x] Per-task ELF mapping** (`61e2b24`): ET_DYN PIE + ELF32 + user
  stack + brk heap now get explicit per-task 4 KiB PTE chains in the
  task PML4 instead of relying on the kernel's 1 GiB identity stamp
  (which silently failed when the allocator gave hamsh's phys bytes
  outside the identity-mapped range on bare metal).
- Asus i5-4210U: currently crashes during boot. Booted to hamsh in
  M16.156 (Legacy/BIOS); regressed in a subsequent wave (root cause
  not yet identified). Preserved for regression observation, not a
  current bring-up target.
- Asus built-in keyboard: never responded under Legacy/BIOS even
  when the box booted; leading hypothesis is EHCI-routed. Native
  EHCI driver (`drivers/usb/ehci.ad`) is QEMU-verified but not yet
  exercised on metal. Moot until the box stops crashing earlier in
  boot.
- Other drivers vulnerable to the same MMIO-stall class — flagged by
  the bare-metal auto-skip agent's audit:
  - `drivers/usb/ehci.ad` — BIOS→OS handoff (line ~593), HCRESET clear
    (~647), port-reset (~750/~760) — same spin-counter shape that
    doesn't help if the load itself doesn't retire.
  - `drivers/ata/ahci.ad::_ahci_port_start` (CR/FR polls, CI polls).
  - `drivers/nvme/nvme.ad` (not yet audited, same architectural
    pattern).
- Real NIC silicon: e1000e EEPROM-walk, r8169 RX on a physical
  RTL8168, Broadcom tg3, Intel igb — verify against metal.
- EFI Runtime Services (`GetTime`, `GetVariable`); PE `.reloc` table
  (Secure Boot prereq); drop the FAT12 32 MiB ESP cap via the GPT-ESP
  path.

# Storage driver maturity
- AHCI NCQ (serialises on slot 0 today); hot-plug / COMRESET retry;
  multi-port naming (`sd1`...). NVMe multi-queue + multi-namespace.
- Partition: extended-CHS chains, BSD disklabel, APM; GPT UTF-16 names
  into the block tag; `mount /dev/sd0p1 /mnt` path-to-slot resolver.
- ext4 mkfs: multi-block-group layout, journal (jbd2). Installer
  plumbing (ext4-write + GRUB-install + MBR-write).

# Input
- International keyboard layouts (`kbd_set_layout` + compiled-in tables);
  dead-key / compose / IME; PS/2 mouse 4-byte scroll-wheel protocol;
  blocking read on `/dev/mouse`; MADT IRQ-override consumption.

# Userspace polish
- **[x] Real Debian apt/dpkg via `enter linux { ... }`** — the
  hand-rolled `user/apt.ad`/`user/dpkg.ad`/`user/dpkg_deb.ad` Adder
  reimplementations were RETIRED 2026-05-26 (`0de1c63`..`3ff5bfc`).
  Real Debian apt 3.0.3 + dpkg 1.22.22 now ship on the rootfs ext4
  partition (`scripts/build_rootfs_img.py`,
  `HAMNIX_DEFAULT_REAL_DEBIAN=1`); the linux ns recipe binds
  `'#distro'` at `/`, so `enter linux { /usr/bin/apt install hello }`
  runs the real binaries. Verified by `scripts/test_linux_apt_install.sh`.
  The old "user/apt.ad" cache-cap and post-inflate-leak items are
  moot — the Adder reimpl is gone.
- **[x] vanilla-ISO install-over-SSH demo** (`0f30263`): `/etc/rc.boot`
  spawns sshd as a detached service; `PIPE_MAX` raised 8→32 so nsrun's
  distrofs daemons + the SSH session bridge can coexist; `sshd::_bridge_session`
  closes its pipes cleanly on every exit path (no more leak after 4
  sessions); `tcp_smoke_test` gated on `/etc/tcp-smoke-test` so default
  boots don't ARP-stall in net_smoke pre-`time_init`.
- Remaining demo gap to "ssh in → apt install nginx → curl from host":
  the `enter linux { /usr/bin/<pkg> }` step today re-enters a fresh
  copy of the linux ns each time and apt installs persist on the
  rootfs partition, so the second `enter linux` does see them; but a
  full end-to-end SSH-driven validation has not been re-run since the
  apt retirement.
- **[x] hamsh maturation** — line editor (`df27310`), Tab completion
  (`c2a062d`), distrorun retired in favor of `enter linux { … }`
  (`1cdc34f`), boot-time per-PID-1 `/etc/rc.boot` (`341af32`), clean
  isolation by default (`07c3063`), `[hamsh-alive]` heartbeat
  (TEMP_DEBUG, to be ripped later).
- **[x] Native ping over `/net/icmp`** (`0782728`, `d97c3aa`,
  `7dc8450`) — Plan-9-shape ICMP as the third proto under `/net`. Plus
  IP loopback shortcut (`62fbac3`) so `ping 127.0.0.1` works without a
  NIC.
- Known follow-up: nested `` `{ } `` command-substitution clobbers
  (hamsh).
- CPython: trim the frozen stdlib set; PGO/LTO; C extensions (`_ssl`,
  `_socket`, ...) once a U-track `ld.so` exists.
- busybox `ls` enumeration XFAIL (musl DIR-fd round-trip) — re-confirm
  after the `%rdi` fix; busybox `sh -c "a|b"` internal-pipeline `#GP`.
- `/bin` tool audit for cwd-relative defaults.
- [x] SSH follow-ups — publickey auth, generated+persisted host key,
  RFC 6979 deterministic ECDSA nonce — `5cd02bb`.

- `enter linux { /bin/sh }` interactive stdin: opens but typing doesn't
  reach the Linux process. The clean linux ns doesn't currently wire
  stdin through to the entered process; sshd-driven sessions are not
  affected (they get their own pty from the SSH protocol).
- TEMP_DEBUG cleanup pass when bring-up stabilizes: the `[hamsh-alive]`
  heartbeat, `[execve-sysret]` register dump, `[execve-pml4]` walk,
  trap-EMERG-level bumps, `[I TOLD YOU SO]` sentinel, the hamsh
  `_dbg_stage` markers (`[hamsh:_start hit]`, `[hamsh:stage-NN]`),
  per-binary `[runtime:NAME] _start` markers — all tagged with
  `TEMP_DEBUG_*` comments for grep-and-remove.
- hamsh clean-sheet rewrite (`docs/HAMSH_SPEC.md`) — **§18 stages
  1–11 all LANDED** (`183fc4a`, `dcabf01`, `72853f4`): single
  Python-flavored language; `/fd` (`#d`) + `/env` devices;
  pipe/redirect/dup as the one `sys_fdbind` primitive; `ns`/`enter`/
  `spawn`; mount handles + union mounts; view-vs-state over a posted
  distrofs daemon; errstr `try`/`except`. Maturation done: lexer fixes,
  old-test triage, recursion/nesting guards, robustness pass. The
  shell is matured.
  - [x] **init/rc in hamsh** (`341af32`): `/init` execs hamsh with
    `/etc/rc.boot`; hamsh is PID 1, the boot namespace recipe + service
    launch are declarative hamsh rc. Hard-coded `user/init.S`/`init2.ad`
    deleted.
  - [x] Full interactive line editor (`df27310`) — Left/Right/Home/
    End/Delete cursor editing, cursor-aware backspace, Up/Down history
    (48-entry ring), Ctrl-A/E/C, ANSI-escape state machine; Tab
    completion (command + path, `c2a062d`).
  - [x] `distrorun` retired (`1cdc34f`) — the Linux runtime is a
    captured `ns {}` value in `/etc/rc.boot`; running a Linux binary is
    `enter linux { … }`. `&&`/`||` now chains `ns`/`enter`/`spawn`.
  - Known follow-up: nested `` `{ } `` command-substitution clobbers.
- CPython: trim the frozen stdlib set; PGO/LTO; C extensions (`_ssl`,
  `_socket`, ...) once a U-track `ld.so` exists.
- busybox `ls` enumeration XFAIL (musl DIR-fd round-trip) — re-confirm
  after the `%rdi` fix; busybox `sh -c "a|b"` internal-pipeline `#GP`.
- `/bin` tool audit for cwd-relative defaults.
- [x] SSH follow-ups — publickey auth, generated+persisted host key,
  RFC 6979 deterministic ECDSA nonce — `5cd02bb`.
## Userland polish queue — post-installer-loop (2026-05-27/28) ✅ DONE

**Serial-dispatch sweep** per user direction *"don't do it in parallel,
too wide on each issue. Take them one at a time."* All landed and
pushed; see git log between `4964a6b` and `df962fe`.

- [x] **A** — hpm-from-network: dropped unconditional static IP in
  `etc/rc.boot`; DHCP wins; `hpm refresh` reaches
  `https://255.one/`. `user/ping.ad` already existed. (`94f57ea`,
  `ea14914`, `0bdb550`)
- [x] **A1** — `ext4_alloc_block` + `ext4_free_block` now scan ALL
  block groups (was group 0 only — the long-standing M16.61 followup).
  Unblocks every multi-group write. (`3448ce0`)
- [x] **B** — `ext4_install_file_to_slot` primitive + userland helper
  that writes a single file into an UN-mounted ext4 partition with
  save/restore of the singleton mount state. (`a2b84c5`, `3df8013`,
  `b046cb6`, `1a1b97b`)
- [x] **B2** — converted `etc/install.hamsh` step 6 from `dd_blk` to
  `install_rootfs_from_manifest` (manifest-driven per-file install).
  Added `ext4_mkdir_at_slot`, `ext4_blob_save_at_path`,
  `_ext4_walk_path_mkdir_p`. ESP/FAT12 still uses dd_blk (separate
  followup). (`e643062`, `aecb48e`, `56335a2`, `5e61106`)
- [x] **C** — `hamnix-base` split into 17 component packages
  (kernel/init/hamsh/coreutils/net/sshd/hpm/fs-ext4/fs-fat/
  drivers-{e1000e,ahci,nvme,xhci,snd-hda}/installer-tools/bootloader
  + `hamnix-base` metapackage + `linux-debian-12`). hpm metapackage
  solver re-used (no new code). Bumped `TMPFS_MAX_FILES` 256→1024
  to fit the install closure. (`70ed290`)
- [x] **E1** *(side quest)* — subdirectory channels at `255.one/`.
  `hpm channels` / `enable` / `disable` subcommands; per-pkg
  `channel` field routes installs. Default subscription `main` only.
  Live: `https://255.one/main/index.json` (17 pkgs),
  `non-free/index.json` + `non-free-firmware/index.json`
  placeholders. HamnixOS/packages commit `38f2c33` + `0a640ea` (the
  latter strips `\u`-escapes from descriptions via
  `ensure_ascii=False`; build_packages.py mirror at `db00cb3`).
  (`fcc1641`, `cff568a`, `bf6179a`, `7f25aac`, `b06c8e7`)

### Small-commands batch ✅ done

- [x] `dmesg`, `ps`, `df`, `du`, `top` — already existed as
  `user/{ps,df,du,dmesg,top}.ad` (audit at 2026-05-27).
- [x] **D1** — persistent svc logs at `/var/log/svc/<name>.log`.
  New `DEVFD_FILE_APPEND` cdev kind + `OPENCHAN_APPEND` mode +
  `tmpfs_open_for_append`. Plan-9-shape `/fd/1`+`/fd/2` namespace
  bind, NOT Linux dup2. Append across `svc restart`. (`2264e92`,
  `4f8b794`)
- [x] First-login MOTD — already wired via `etc/rc.boot` spawning
  `motd` at boot (audit at 2026-05-27).
- [x] **D2** — `man` + `help` discovery system. ~20 markdown pages
  at `/usr/share/man/`; `user/man.ad` reads
  `/usr/share/man/<topic>.<N>.md`; `user/help.ad` walks the directory
  + extracts H1 summaries. In-shell `help` builtin deleted in favour
  of `/bin/help` (so it can take args). (`8503b1e`, `1cf57b8`,
  `cb44aa5`, `0f3fbe8`, `5f1a7ff`, `eb73777`, `0d53243`, `0ca6a9f`,
  `cef5b15`)
- [x] **D3** — RTC + real-time `date`. RTC driver already existed
  in `drivers/rtc/cmos.ad`; added `/proc/realtime` procfs endpoint
  (ISO-8601 + epoch + monotonic uptime) and rewrote `user/date.ad`
  to print real UTC. (`e5eb459`, `ebd8c24`, `10cc8f1`, `a54c03c`)
- [x] **D4** — `cp -r` recursive mode + ext4 live mkdir wire.
  `vfs_mkdir` for `/ext/*` now goes to `ext4_mkdir_live` (was
  EROFS). Bonus: `ext4_open_create_or_trunc` rewritten subdir-aware
  (was hardcoded `parent_inum=2`). (`b358cb1`, `674c248`, `69d08df`,
  `f42c9d3`, `85678dd`)
- [x] **D5** — kernel ext4 multi-block writer. Removed the
  M16.64 single-block cap on `vfs_open_write`. Streaming-extent
  strategy; files now up to **512 MiB** (was `ext4_block_size`,
  i.e. 4 KiB). Bonus: fixed extent-leak in `ext4_open_create_or_trunc`
  O_TRUNC + `ext4_unlink` (only block 0 was being freed). `cp`/`mv`
  stream through 4 KiB buffers. (`a9b74dd`, `a7bd236`, `11d4b06`,
  `d2ed204`, `4f2def0`, `2abaf4b`)
- [x] **D6** — hamsh builtin redirects. `echo "foo" > /tmp/x`
  works now (was silently dropping the redirect). Option B chosen
  (in-process `sys_dup2` save/restore, no fork). 10 builtins
  covered. Bonus: fixed latent external `>>` bug (was
  `OPENCHAN_TRUNC` silently truncating). (`18d0f51`, `bdb23ec`,
  `c8d1b72`, `34457b6`, `abd9107`)

### Still pending from the original batch

- [ ] `tar` + `gzip`/`gunzip`
- [ ] Audio playback (`snd_hda_intel.ko` loads; need `aplay`-shape
  userland)

## `hamUI` window system — Phase 1 ✅ LANDED 2026-05-27/28

(Was rio.md; renamed to avoid Plan 9 name collision. Full spec at
[`docs/hamUI.md`](docs/hamUI.md).) Same per-window-namespace invariant
as Plan 9 rio; same file-server-per-window shape; departs in three
areas.

### AI-debuggable file tree per window (`/dev/wsys/<wid>/`)

The killer feature. Every window's text content + namespace state +
I/O are file-readable from outside. AI agents debug Hamnix the same
way human SREs do — but more thoroughly, because state is exposed
directly, not through pixels.

| File | What |
|------|------|
| `text` | UTF-8 scrollback (no screenshot needed) |
| `output` | Live tail of current command's stdout/stderr |
| `kbdin` | Write-only keystroke injection |
| `cmd` | Write a command line, runs in window's shell (one-shot) |
| `ns` | Plain-text mtab dump |
| `pid` | Root pid of window's shell |
| `proc/` | Symlinked tree of `/proc/<pid>/*` |
| `kind` | `text` / `x11` / `framebuffer` |
| `uid` | Effective uid (changes after `newshell`) |
| `geometry` | minx miny maxx maxy |
| `framebuffer` | Mmap pixel buffer (kind=x11 / framebuffer) |

### Per-window admin elevation

- Inside an existing window: `newshell hostowner` swaps the shell to
  hostowner namespace (window stays; contents elevate).
- Direct admin window: `hamUI new -as hostowner` prompts for password,
  spawns a fresh window already elevated.

### X11 / Linux apps via Xvfb-in-linux-ns

`hamUI new -kind x11 -cmd '/usr/bin/firefox'`:
- Spawns Xvfb inside linux ns drawing to a memory-mapped file.
- hamUI reads + composits to physical fb.
- Plan-9-shape `/dev/mouse` ↔ X11 event translation.
- Per-window `framebuffer` IS the Xvfb buffer.
- Path to Firefox/Chromium without writing our own X11 server.

### Drag-to-create-window

Plan 9 rio's canonical gesture: left-click on root, drag a rectangle,
release → that rectangle becomes a new window (default: hamsh). When a
GUI command runs inside (e.g. `firefox`), the window's `kind` flips and
it becomes that app. No right-click menus. The drag IS window creation.

User: *"Ironically, this resembles directly a desktop environment I
built in the past."*

### Phasing — AI-debug FIRST

1. [x] **Phase 1 ✅ LANDED** — hamUI skeleton; `/dev/wsys/1/` with
   `text` / `output` / `cmd` / `ns` / `pid` / `uid` / `kind` /
   `geometry` files. Kernel-tee strategy on `devcons_write`/`_read`;
   ZERO hamsh refactor. AI cmd-injection round-trip works
   (`echo cmd > /dev/wsys/1/cmd` → hamsh readline pop). 12/12
   assertions PASS. (`cda060e`, `abae723`, `025c7b1`, `32bb867`,
   `8f833cd`, `425486a`, `df962fe`)
2. [~] **Phase 2** (in flight 2026-05-28) — multi-window via
   `/dev/wsys/<N>`. Background hamsh instances with per-wid AI-debug
   surface; serial console stays on wid 1; bg windows only readable
   via `/dev/wsys/N/text`. `hamUI new` / `hamUI list` /
   `hamUI close <wid>` userland tool.
3. [ ] **Phase 3** — per-window elevation visible in `uid` / `ns`
   files. `newshell hostowner` inside swaps the window's uid;
   `hamUI new -as hostowner` spawns a fresh elevated window.
4. [ ] **Phase 4** — framebuffer-backed pixel windows + drag-to-create
   gesture. Requires real framebuffer rendering past the current
   text-mode VGA.
5. [ ] **Phase 5** — X11 bridge (Xvfb in linux ns + mouse/kbd event
   translation). Path to Firefox/Chromium.
6. [ ] **Phase 6** — snarf (clipboard), wctl resize/move, focus
   policies.

### Retired open questions

Daemon-mode (not PID 1); multiplexed keyboard; defer acme; strict Plan
9 draw protocol.

## Bigger lifts — no immediate plan

- NUC network silent on real I219 (needs hardware time).
- iwlwifi & other firmware-blob drivers — ship via the planned
  `non-free-firmware` channel at `https://255.one/non-free-firmware/`
  (placeholder already deployed 2026-05-27). Not blocked, just deferred.
- Browser (Firefox/Chromium) in hamUI window — gated on X11 bridge
  (hamUI Phase 5).
- Suspend / power management.

---

## Next-up: useful-system gap fill (2026-05-28)

Discussed with user 2026-05-28 — order locked. Dispatch one or two
agents at a time, only two if scopes don't touch.

### Priority queue

1. [~] **hamUI Phase 2** — multi-window (`a1e35482b1aa02a94` in
   flight). See `### Phasing` block above. Strategic continuation
   of Phase 1.
2. [~] **/dev/urandom + NTP client** (`aa25fbbb1ef512e17` in
   flight). New `sys/src/9/port/devrandom.ad` cdev seeded from
   RDRAND (xorshift fallback). NTP via kernel UDP primitives
   (Plan-9-shape, no sockets); sets kernel realtime epoch; wired
   into `etc/rc.boot` after DHCP. Test gates host-vs-guest within
   24h.
3. [ ] **shutdown / reboot / halt / poweroff** — basic system
   management. ACPI shutdown vector or 0x604 / 0xB004 magic write;
   reboot via triple-fault or KBC. Userland `/bin/{shutdown,reboot,
   halt,poweroff}` + clean unmount sequence.
4. [ ] **Outgoing SSH client + curl/wget**. We ship `sshd`, no
   `ssh` out. Hpm has the HTTPS fetcher internally — expose as
   `/bin/curl` (or wget shape). SSH client is bigger (full TLS-shape
   for ssh transport — share code with sshd where possible).
5. [ ] **Pipes + job control in hamsh**. Audit current pipe
   support (`a | b`); add `&` background; `bg`/`fg`/`jobs` builtins;
   process groups + SIGTSTP/SIGCONT.
6. [ ] **Real editor** (vi-shape or acme-shape). `ed` is too
   minimal for daily use. acme is more Plan-9-pure but bigger; vi
   is smaller scope. Pick when reached.
7. [ ] **tar + gzip/gunzip**. Share/backup workflows. tar single-
   stream first; archive walks D4's recursive copy shape.
8. [ ] **Audio** (`aplay`-shape). `snd_hda_intel.ko` loads; need
   the userland tool that pushes PCM to the cdev.
9. [ ] **`hpm update` + rollback**. Install works; in-place
   upgrade does not. Rollback / snapshot before upgrade.

### Inventory of remaining gaps (uncategorized)

Tools / shell ecosystem:
- `grep -r` recursive
- `sed`-shape (or hamsh-native equivalent)
- `diff`, `patch`
- `xargs`, `kill`, `pkill`, `killall`
- `tab-completion` audit; persistent command history
- `which`, `whereis`, `type`, `env`, `printenv`

Network surface:
- `netstat` / `ss` — what's listening / connected
- `traceroute`, `arp`
- IPv6
- `scp` / `rsync` (gated on `ssh` client + tar)

Kernel / system:
- VT switching (Ctrl+Alt+F1..F6) — likely superseded by hamUI
  multi-window in text mode
- Hot-plug (USB mouse/keyboard discover-on-insert)
- Suspend / power management
- Watchdog + kernel-panic capture to flash / serial
- inotify-shape file watch
- Signal depth (SIGWINCH, SIGCHLD wired everywhere it should be)

Reliability / observability:
- Kernel oops capture (svc logs cover userland only)
- `strace`-shape syscall trace
- Memory-pressure visibility (`/proc/meminfo` polish; OOM kill log)

Distribution / updates:
- Signed indexes (`sha256` covers tarballs; index itself is
  unsigned today)
- Multi-arch (ARM64) — currently x86_64 only

