# Hamnix TODO

Open work, not yet milestone-scheduled. The **Kernel Roadmap** below is
the priority spine — it is dependency-ordered and **Phase D is the
prerequisite gate**. Sections after it are areas the roadmap
deliberately excludes (metal bring-up, userspace polish, storage-driver
maturity).

> **Check [`STATUS.md`](STATUS.md) before picking an item** — it is the
> source of truth for what shipped. Large chunks already closed: real
> hardware boot (BIOS + UEFI), the Plan 9 native-syscall surface,
> per-process namespaces, `distrofs`/`nsrun`, TLS 1.3 + X.509 chain
> validation, the `dpkg`/`apt`/`httpd` userland, userland sockets,
> CPython + busybox as musl static-PIE, fork → copy-on-write, the
> higher-half ELF64 kernel, preemptive scheduling, the SSH-2.0 server,
> xz decompression, apt streaming + GPG verification.

**Project-direction docs:** [`docs/architecture.md`](docs/architecture.md)
(layered model, boundary rules, migration phases),
[`docs/native-api.md`](docs/native-api.md) (Layer 1 Plan 9 syscalls),
[`docs/rio.md`](docs/rio.md) (window system), [`README.md`](README.md)
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
- [ ] Collapse the 4 per-subdir binds in `distrorun.ad` into one
  `mount(srvfd, -1, "/", MREPL, "")`.
- [ ] `create(260)` DMDIR → real directory create (needs tmpfs/ext4 mkdir).
- [ ] `stat`/`fstat` per-backend hooks (tmpfs/fat/ext4/socket).
- [ ] `fd2path` exact open()-time path (per-fd path slot in `TaskStruct`).
- [ ] `wstat`/`fwstat` fields: `length` (truncate), `mtime`, `gid`/`muid`,
  `mode` storage.
- [ ] **distrofs migration capstone:** run `apt`/`dpkg`/`httpd` *under*
  `nsrun` so `/var/lib/dpkg`, `/var/cache/apt`, `/var/www` resolve
  through distrofs; then delete the global `/var` tmpfs (supersede
  `86a13bd`). The largest open Namespace-law debt.
- [ ] distrofs persistent backing (ext4 partition / disk image) so an
  installed package survives reboot.

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

## §3 Signals  (real daemons live or die here)
- [ ] Full Linux-ABI signals: `sigaction`, `sigprocmask`, masks,
  signal-frame setup, `rt_sigreturn` (only Ctrl-C SIGINT today).
- [ ] SIGCHLD + reaping; SIGPIPE on broken pipe/socket; SIGTERM/SIGKILL.
- [ ] Plan 9 note follow-ups: `note_group`-wide (killable group),
  cross-task `/proc/<pid>/note`, NDFLT action, surface handler `msg`.

## §4 Dynamic linking / loader  (depends on §1 + Phase D)
- [ ] `dlopen`/libdl: DT_NEEDED resolution + `ld.so.cache` search path —
  unlocks apt plugins, CPython `.so`, stock Debian.
- [ ] Route interpreter lookup through the chan/namespace layer
  (`_load_interp_elf` hardcodes `initramfs_data_ptr` today).
- [ ] Verify AT_BASE/AT_ENTRY/AT_PHDR auxv for a binary loaded *inside*
  a namespace.
- [ ] **Capstone demo:** `deb /bin/true` exec'ing the stock dynamic
  Debian binary inside a namespace, driven over SSH (depends on Phase D
  + §1 + this + §16 cpio bump).

## §5 Modern async I/O  (**Layer 2 only**, depends on §2/§3)
- [ ] `epoll` (`epoll_create1`/`ctl`/`wait`); `io_uring` SQ/CQ rings;
  `eventfd`/`timerfd`/`signalfd`; `poll`/`select` fallback.
- [ ] O_NONBLOCK end-to-end: stop masking `SOCK_NONBLOCK`, EAGAIN on
  would-block across socket + file fds.

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

## §9 Interrupts & PCI  (off critical path — parallelizable)
- [ ] MSI-X: PCI cap-walk (0x11), table mapping, per-vector LAPIC
  programming — per-queue virtio-net.
- [ ] virtio-blk INTx wiring (vectors 0x41+).
- [ ] Multi-IOAPIC: consult the MADT-cached list, pick by GSI range
  (hard-coded `0xFEC00000` today).

## §10 Networking  (off critical path — parallelizable)
- [ ] **(ARCH)** Expose TCP/UDP as a `/net` 9P file tree
  (`/net/tcp/clone`, `/net/tcp/N/{ctl,data,status}`); `socket(2)` →
  Layer-2 consumer of it. Do once the chan layer is real (Phase D).
- [ ] Congestion control: slow-start + congestion-avoidance (RFC 5681),
  NewReno or CUBIC.
- [ ] Multi-listener accept queue / wider TCB table; window scaling +
  SACK + timestamps.
- [ ] ICMP errors (dest-unreachable, time-exceeded, redirect); generic
  unicast ARP helper; UDP sockets; `getsockopt`/`setsockopt`; close a
  socket fd's TCP slot at task exit.

## §11 DNS resolver  (off critical path — parallelizable)
- [x] Multiple A-records (return all + round-robin), PTR/MX/SRV record
  types, TCP/53 fallback for > 512 B — `461a134` (`drivers/net/dns.ad`,
  6/6 offline self-tests + live multi-A resolve).
- [ ] AAAA records — deferred; gated on an IPv6 header (IP layer is
  IPv4-only today).

## §12 Filesystem write maturity & persistence
- [ ] ext4 `rename` (-EROFS off-tmpfs today); `truncate`/`ftruncate`;
  per-inode mtime storage; `fsync` + barrier ordering; FAT write path.

## §13 cdev / proc field completions  (after the Phase D Chan conversion)
- [ ] `/dev/uptime` idle column; `/dev/loadavg` EWMA; `/dev/stat` real
  columns; `/dev/diskstats` counters; persist `/dev/hostname`.
- [ ] Layer-2 `/proc` extensions via bind: `stat`/`mounts`/`diskstats`,
  per-pid `/proc/<pid>/*`, `/proc/self`, `/proc/net/*`, `/proc/cmdline`.
- [ ] Real `KmallocLive` (per-cache slab walker); per-backend errstr
  (ext4/fat/blk); user-mode `perror` helper.

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
Phase D (the prerequisite gate, `4964a6b`), §1 (process model / AS,
`e32ec28`), §2 (futex / TLS), and §15 (function pointers, `d321f53`)
are **landed**. Remaining critical path: **§4 — dynamic loader
(`dlopen`/libdl, namespace-routed interp lookup) + the capstone demo**
(`deb /bin/true` running a stock dynamic Debian binary over SSH).
Off the critical path, safe to dispatch in parallel: §9, §7, §13,
§12, §10, §3. §11 and §16 are landed; §6 has only the vDSO item left.
Everything in §5 is Layer-2-only per the boundary law.

---

# Metal bring-up  (human-in-the-loop lane — excluded from the roadmap)
- Real-hardware keyboard: the built-in keyboard on the Asus i5-4210U
  does not respond; leading hypothesis is an EHCI-routed keyboard (the
  EHCI driver is QEMU-verified, not yet tested on metal).
- UEFI on the real Asus — Legacy/BIOS confirmed; re-verify the UEFI
  direct-boot path on that laptop.
- Real NIC silicon: e1000e EEPROM-walk, r8169 RX on a physical RTL8168,
  Broadcom tg3, Intel igb — verify against metal.
- EFI memory-map walker in `e820.ad` (RAM > 240 MiB on UEFI boot); EFI
  Runtime Services (`GetTime`, `GetVariable`); PE `.reloc` table (Secure
  Boot prereq); drop the FAT12 32 MiB ESP cap via the GPT-ESP path.

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
- `apt` against a live `deb.debian.org` mirror — streaming + xz +
  GPG-verify are all in; the genuine end-to-end run is the last step.
- hamsh line editor: in-line cursor model (Left/Right/Delete), Tab
  completion, Ctrl-C drops the edit buffer, argv-tokenization rewrite
  (single quotes, backslash escapes).
- CPython: trim the frozen stdlib set; PGO/LTO; C extensions (`_ssl`,
  `_socket`, ...) once a U-track `ld.so` exists.
- busybox `ls` enumeration XFAIL (musl DIR-fd round-trip) — re-confirm
  after the `%rdi` fix; busybox `sh -c "a|b"` internal-pipeline `#GP`.
- `/bin` tool audit for cwd-relative defaults; SSH follow-ups (publickey
  auth, generated host key, RFC 6979 nonce).
