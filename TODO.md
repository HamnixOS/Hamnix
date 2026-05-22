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
  inside a `distrorun` namespace — PT_INTERP + DT_NEEDED both resolved
  through the namespace bind (`6d9898e`, test_u43).

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
- [ ] **(ARCH) — USER-CONFIRMED PRIORITY (2026-05-22).** Expose
  TCP/UDP as a `/net` 9P file tree (`/net/tcp/clone`,
  `/net/tcp/N/{ctl,data,status}`); native code opens/reads/writes
  `/net` files; `socket(2)` becomes a Layer-2 *consumer* that
  translates onto it. This RETIRES the native `SYS_SOCKET`/`CONNECT`/
  `BIND`/`LISTEN`/`ACCEPT` syscalls — the architecture audit flagged
  them as non-Plan-9 Layer-1 calls, and the user ruled Layer 1 must be
  Plan-9-shaped. Rewires every native net consumer (`apt`, `ifconfig`,
  `route`, http/tls/dns/sshd) onto `/net`. Wide architectural change —
  one solo agent; dispatch after the in-flight boundary-law cleanup
  lands (overlaps `fs/vfs.ad`/`linux_abi`).
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
- `apt` against the live `deb.debian.org` mirror — DONE: `apt update`
  verifies the real InRelease (`6d72a5d`); `dpkg -i` of the genuine
  Debian `hello` `.deb` lands all 49 files into the distrofs namespace
  and they are readable there (`d2fe317` + `463c3e8`).
  Remaining: run `apt install` itself under `nsrun`; ext4-backed
  distrofs for reboot persistence; streaming xz + larger `.deb`/index
  caps for big packages.
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
    (48-entry ring), Ctrl-A/E/C, ANSI-escape state machine.
  - [x] `distrorun` retired (`1cdc34f`) — the Linux runtime is a
    captured `ns {}` value in `/etc/rc.boot`; running a Linux binary is
    `enter linuxruntime { … }`. `&&`/`||` now chains `ns`/`enter`/`spawn`.
  - Known follow-up: nested `` `{ } `` command-substitution clobbers.
  - [~] REGRESSION (being fixed): dynamic-ELF / glibc Linux binaries
    fault the kernel (`vec=0xe` @ ~`0xffffffff801d06xx`) — `test_u26_fork`/
    `test_u43`/glibc-thread; musl-static is fine. Blocks the §4 capstone.
- CPython: trim the frozen stdlib set; PGO/LTO; C extensions (`_ssl`,
  `_socket`, ...) once a U-track `ld.so` exists.
- busybox `ls` enumeration XFAIL (musl DIR-fd round-trip) — re-confirm
  after the `%rdi` fix; busybox `sh -c "a|b"` internal-pipeline `#GP`.
- `/bin` tool audit for cwd-relative defaults.
- [x] SSH follow-ups — publickey auth, generated+persisted host key,
  RFC 6979 deterministic ECDSA nonce — `5cd02bb`.
