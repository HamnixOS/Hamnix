# Hamnix TODO

What's still open. **For what's shipped, read [`STATUS.md`](STATUS.md)** —
it's append-only, dated, and the source of truth.

Pointers:
- Design: [`docs/architecture.md`](docs/architecture.md),
  [`docs/native-api.md`](docs/native-api.md) (Layer 1 Plan 9 syscalls),
  [`docs/hamUI.md`](docs/hamUI.md) (window system),
  [`docs/packages.md`](docs/packages.md),
  [`docs/security.md`](docs/security.md).
- Current snapshot: [`README.md`](README.md).
- Onboarding: [`CONTRIBUTING.md`](CONTRIBUTING.md).

Markers: `[ ]` open · `[~]` in flight · `(NEW)` not previously tracked.

---

## ⚠ Namespace law — read before touching any shim / distro / package work

Hamnix is a **Plan 9-shaped system. There is NO global filesystem route.**
A process sees a path only because something was *bound or mounted into
its own namespace*. **No work may write to a global `/var`, `/usr`,
`/etc`, `/var/lib/dpkg`, `/var/cache/apt`, `/var/www`.** All Linux-binary-
shim and distro/package state lives inside a distro-shaped namespace
exported by the userland **`distrofs`** 9P daemon; a shim is launched
`rfork(RFNAMEG)` → mount/bind `distrofs` → exec. A TODO item is
mis-shaped if it says "write X to `/var/...`" without "...in the shim's
distrofs namespace" — fix the wording.

## ⚠ Boundary-discipline law

**Layer 1 (native) stays pure 9P / namespace. No exceptions.** The non-
file modern mechanisms — `io_uring`, `epoll`, `futex`, signalfd/eventfd/
timerfd — are the antithesis of "everything is a file." They are
permitted **only inside Layer 2** as confined kernel objects that exist
to satisfy Linux guests. The moment one becomes a dependency of native
code or of the resource model below Layer 1, the architecture has been
retrofitted backwards.

---

## TOP PRIORITY — namespace-purity base cleanup (locked with user 2026-06-05)

The base must be Plan 9 to the bone: **no global filesystem, no hardcoded
path bypasses — everything is namespaces + file servers.** Finish this
*before* pouring agents back into breadth work (ARM, GPU, drivers). See
[[memory/project_namespace_purity_mandate]]. Big-bang rewrites sanctioned;
each phase must still boot + pass the sweep (tests may be rewritten to the
new design but must pass for real).

- [x] **Phase 1 — `/dev` reference template** (`3a887b2c`). `#b`/`#c`
  bindable device servers; `ls /dev`, `/dev/blk`, `lsblk` resolve through
  the namespace. `scripts/test_dev_namespace.sh`.
- [~] **Phase 2 — literal-arm sweep** (#388, mostly LANDED `878e9a1b`).
  DONE: `/net` (`_open_net` → bound `#I` IP server + `devnet_listdir`),
  `/dev/loop` and `/dev/blk` literal arms deleted (served by the `#c`/`#b`
  binds), dead `devblk_path_match` import removed, `/dev/cons`/`null`/`zero`
  confirmed to have no residual literal arms. `scripts/test_net_namespace.sh`
  + `test_dev_namespace.sh` green on `main`. REMAINING sub-task: `/proc`
  literal bypass (`devproc_path_match` + static `procfs_render`) — entangled
  with the well-known renderers + Layer-2 `/proc/<name>`→`/dev` translation,
  so `#p` must serve `ls /proc` and every well-known file before the literal
  arms can go. `#e` env still absent. End state: `vfs_open` has ONE
  resolution path.
- [ ] **Phase 3 — real `mount()`** (#389). No `sys_mount`/`vfs_mount`
  exists today; ~53 `is_*_path` predicate branches dispatch filesystems.
  Add a mountable-FS-server interface so ext4/fat/tmpfs/cpio attach at
  namespace points; delete the `is_*_path` ladder.
- [ ] **Phase 4 — unify fds on `Chan`** (#390). Retire the ~24
  collision-prone `FD_*_MARK` magic-integer ranges; every fd becomes a
  `Chan` pointer through the `namec` devtab.

## Now — useful-system gap fill (priority-ordered, locked with user 2026-05-28)

1. [x] **hamUI Phase 4a** — LANDED: layered draw protocol cdev
   (`/dev/wsys/<wid>/draw/<name>/{kind,z,opacity,geometry,markup,fb}`
   + `ctl` verbs `mklayer`/`rmlayer`/`setz`/`ls`).
2. [x] **hamUI Phase 4b** — LANDED: `hamUId` userland renderer daemon
   (hamML parser, bitmap-font rasteriser, compositor).
3. [x] **hamUI Phase 4c** — LANDED: `/dev/fb` framebuffer cdev; drag-
   title-to-move + click-to-close window management; drag-to-create
   gesture; GNOME2/MATE-style panel with Applications menu, taskbar
   (window-list buttons), minimize buttons, and live clock.
4. [ ] **hamUI Phase 4d** — bitmap font store (mono/sans/serif BDF).
5. [ ] **`lib/hamui.ad`** — Adder graphics library wrapping H-§G
   (Window/Layer/Rect/Text/Image/Button/Input/Event + event loop).
   See [[memory/project_app_language_decision]] — Adder + hamsh,
   no third tier.
6. [ ] **hamsh `use hamui`** — bindings on top of #5. May require
   hamsh extensions for closures + event loop + persistent state.
7. [x] **Outgoing `ssh` client** — LANDED (#170): crypto + key exchange
   + channels; dials out (including to self).
8. [x] **Pipes + job control in hamsh** — LANDED: `&` background,
    `bg`/`fg`/`jobs`, Ctrl-Z → SIGTSTP / SIGCONT. Process groups
    and pipelines work end-to-end.
9. [x] **Real editor** — LANDED: `vi` native modal text editor
    (`user/vi.ad`).
10. [x] **`tar` + `gzip` / `gunzip`** — LANDED: ustar archiver
    (`user/tar.ad`) + DEFLATE compressor/decompressor (`user/gzip.ad`,
    `user/gunzip.ad`). xz/LZMA2 decompression also landed
    (`lib/xz/xz.ad`).
11. [x] **Audio** — LANDED (#152): PCM playback path (snd_hda sound out).
12. [x] **`hpm update` + rollback** — LANDED: `hpm update` and
    transactional history + `hpm rollback` shipped (`b011ce9`,
    `65e6685`).

## hamUI later phases (after Phase 4)

- [ ] **Phase 3** — per-window namespace + elevation visible in `uid` /
  `ns` files (`newshell hostowner` inside; `hamUI new -as hostowner`
  direct). H-§B.
- [ ] **Phase 5** — X11/Xvfb bridge in a kind=fb layer. Path to
  Firefox/Chromium. H-§C.
- [ ] **Phase 6** — snarf (clipboard), `wctl` resize/move, focus
  policies.

---

## GPU / graphics track (#181–185, native-first, locked with user 2026-06-01)

Target: GL + Vulkan to the point that **glxgears and vkcube spin in a
window in the hamUI desktop**, on accelerated hardware where present.

**Two laws this track is built on — do not conflate them:**
1. **The DE never requires the Linux *namespace*.** The Debian userspace
   (apt, Mesa `.so` ICDs like `lavapipe`/ANV, served by `distrofs`) is
   never a desktop dependency. The always-works baseline is a **native
   (Adder) Vulkan spine with a native *software rasterizer*** — NOT
   lavapipe (lavapipe is a Linux Mesa userspace binary, explicitly ruled
   out as the DE fallback).
2. **Linux `.ko` kernel modules via the L-shim ARE used and wanted.** A
   `.ko` is an in-kernel module resolved against `linux_abi/api_*.ad`; it
   needs no namespace. Intel silicon is driven by `i915.ko` through the
   shim (vendor-mess HW → `.ko`, per the native-vs-L-shim law). `.ko` ≠
   namespace.

So "no Linux-namespace requirement" ≠ "no Linux kernel modules."
Hardware accel is a pure perf upgrade, never a gate: if every accel path
fails, the DE keeps running CPU-rendered on the native software rasterizer.

- [ ] **#181 Phase 0 — all-native Vulkan spine.** Native Vulkan API +
  compositor + **native software rasterizer** + present/WSI (CPU image →
  KMS/GOP scanout). Zero Linux, zero namespace. Accept: a native
  vkcube/gears composites in the DE in a VM. The always-works baseline.
- [ ] **#182 Phase 1 — native acceleration in a VM.** Native
  **virtio-gpu** driver (reuse the native virtio core in
  `drivers/virtio/`; standardized HW → native) + native **venus** (Vulkan
  marshalling — no in-guest shader compiler, the host compiles). Real
  accelerated DRM stack in a VM, no NUC, no Linux. Validates the kernel
  DRM / dma-buf / ioctl contract (depends on #163 uaccess).
- [ ] **#183 Phase 2 — DE composites via the native spine.** REQUIRED:
  native vkcube in a hamUI window with the namespace absent. OPTIONAL /
  additive: Linux X11/GL apps bridge **in** via a venus-shaped shim ICD +
  **Zink** (GL-on-Vulkan), so a Linux `glxgears` + `vkcube` spin in an
  X11 window in the DE — proving the bridge without making Linux a DE
  requirement. VM-debuggable. Relates to hamUI Phase 5 (X11 bridge).
- [ ] **#184 Phase 3 (METAL-ONLY) — Intel i915 silicon bring-up.** Drive
  the NUC iGPU via **`i915.ko` through the L-shim** (namespace-free
  kernel module): GEM + GTT/PPGTT, real KMS modeset (EDID/DP-AUX,
  pipes/planes, page-flip — replaces the GOP fb), execlist submission +
  dma-fence, GuC/HuC firmware. Accel userspace ICD = native
  ANV-equivalent (#185, Linux-free) OR Mesa ANV `.so` via the namespace
  (optional). If all accel fails → native software-rasterizer fallback
  (the desktop never goes dark). De-risked: everything above it is
  VM-proven in Phases 0–2; only the Intel-Gen delta is new. Debug via ESP
  `LOG.TXT` persistence or VFIO passthrough.
- [ ] **#185 Phase 4 (long pole, optional) — native ANV-equivalent.**
  Native Intel-Gen ISA shader compiler + command-buffer build + bo alloc
  + execlist submit over #184's i915. Removes the *last* namespace
  dependency (Mesa ANV userspace) for hardware accel on silicon. Shader
  compilation is the dividing line that makes this the hardest native
  piece (virtio-gpu needs none; bare silicon needs a real ISA compiler).
  Validate with a native spinning-cube demo. Lowest priority.

---

## Open kernel work

The Phase D inversion + §1..§13 critical path is **closed** (see
STATUS.md). What remains, off the critical path and parallelisable:

### Latent crashes
- [ ] `#DF` at `load_cr3+0x3` (the `ret` after `mov %rdi,%cr3`) when a
  freshly-built CR3's kernel half is unmapped (stale/uninitialised PML4
  entry; trap rsp lands in low memory ~0x6693200). Fires *after* test
  success in both ntpd and non-ntpd runs, so the suite still passes —
  but it's a real double-fault. Likely cause: a new address space's
  top-level PML4 isn't inheriting the kernel higher-half mappings before
  the switch. Surfaced during hamUI Phase 2 landing.

### Phase D follow-ups
- [ ] Layer-2 `/proc → /dev` translation as a namespace bind (retire
  `_u_translate_proc_to_dev` string-rewrite).
- [ ] Union mounts MBEFORE / MAFTER (flag recorded; longest-prefix only).
- [ ] `create(260)` DMDIR → real directory create (tmpfs/ext4 mkdir;
  ext4 side largely done by D4/D5).
- [ ] `stat`/`fstat` per-backend hooks (tmpfs / fat / ext4 / socket).
- [ ] `fd2path` exact open()-time path (per-fd path slot in `TaskStruct`).
- [ ] `wstat`/`fwstat` fields: `length` (truncate), `mtime`, `gid`/
  `muid`, `mode` storage.
- [ ] Delete the global `/var` tmpfs (last Namespace-law debt) once
  nothing else depends on it.

### §3 Signals
- [ ] Plan 9 `note_group`-wide + cross-task `/proc/<pid>/note` —
  needs a deferred note-delivery hook in the native trap-return path.

### §5 Modern async I/O (Layer 2 only)
- [ ] `io_uring` SQ/CQ rings — deferred (much larger than epoll;
  epoll covers most real Linux daemons).

### §6 Timekeeping
- [x] vDSO (#169): `gettimeofday`/`clock_gettime` without syscall
  overhead landed.

### §7 Entropy / RNG
- [ ] ChaCha20 CSPRNG promotion beyond M16.96 (RDRAND/RDSEED seeding
  +  reseed cadence); distinct blocking `/dev/random` vs non-blocking
  `/dev/urandom` — today both alias the same pool (D5/F2).

### §8 SMP & scheduler
- [~] **MADT-driven SMP landed** (2026-05-30): `arch/x86/kernel/smp.ad`
  discovers all APIC IDs from the ACPI MADT, boots each AP via INIT-SIPI-
  SIPI, sets up per-CPU `%gs` / `current_task`; `kernel/sched/core.ad`
  has a spinlock-protected shared runqueue and `sched_ap_idle_loop` so APs
  pick up `STATE_READY` tasks. Per-CPU runqueue + user-task load balancing
  landed (#139, #151). **Open**: work stealing, CPU affinity.

### §10 Networking
- [x] Congestion control (#166): slow-start + congestion-avoidance
  (RFC 5681) landed.
- [x] Multi-listener accept queue + window scaling + SACK + timestamps
  (#166) landed.
- [x] IPv6 (#156): addr, ND, ICMPv6, UDP/TCP over v6 + DNS AAAA landed.
- [ ] Generic unicast ARP helper; ICMP time-exceeded / redirect.

### §12 Filesystem write maturity
- [x] ext4 extent index-node support (#189): depth>0 extent trees for
  >512 MiB files landed.
- [~] ext4 directory-op maturity (rmdir + dir-rename `..` fixup) — in
  flight (#245).
- [ ] ext4 truncate on index-node files; growing a full ext4 directory
  block.

### §13 cdev / proc completions
- [~] `/proc/net/*` — in flight (tcp/udp/arp/route/dev from live net
  state).
- [ ] Per-backend errstr (ext4 / fat / blk) + user-mode `perror` helper.

### §14 Resource control & security (stretch)
- [x] Per-namespace CPU/memory caps (#174): namespace-native, not
  cgroups.
- [x] seccomp-lite (#160): per-task syscall filter at the Layer-2
  dispatch boundary.
- [x] POSIX capabilities (#296): `capget`/`capset(2)` (drop-root
  daemons).
- [ ] `seccomp-bpf` (full classic-BPF program).

### §15 Compiler / language infra
- [ ] `match` / `case` tokenization → implement.

### §17 L-track stock-Linux `.ko` (lowest priority)
- [ ] `MAX_EXPORTS` bumps as needed; `usbcore`+`xhci_hcd`, `libphy`,
  `8021q`, `nf_conntrack` core. Weigh against native drivers before
  spending.

---

## Metal bring-up (human-in-the-loop)

- [ ] **xHCI hand-rolled v1 bare-metal sub-skip** — `_xhci_v1_bringup`'s
  HCH-clear MMIO poll wedges on real Intel NUC silicon; CPUID
  0x40000000 hypervisor-leaf detection skips that sub-path on metal
  (`ENABLE_XHCI_FORCE_INIT=1` overrides).
- [ ] Asus i5-4210U crashes during boot (regression observation only;
  not a current bring-up target).
- [ ] Asus built-in keyboard never responded under Legacy/BIOS;
  hypothesis EHCI-routed. Native EHCI is QEMU-verified, not metal-
  exercised. Moot until Asus boots.
- [ ] MMIO-stall class audit, drivers still vulnerable: `drivers/usb/
  ehci.ad` (BIOS→OS handoff line ~593, HCRESET ~647, port-reset
  ~750/~760); `drivers/ata/ahci.ad::_ahci_port_start` (CR/FR, CI);
  `drivers/nvme/nvme.ad` (not yet audited).
- [ ] Real NIC silicon: e1000e EEPROM walk on a physical Intel NIC;
  r8169 RX on physical RTL8168; Broadcom tg3; Intel igb.
- [x] EFI Runtime Services (`GetTime`, `GetVariable`) + PE `.reloc`
  table + image signing (#171, Secure Boot) landed.
- [ ] Drop the FAT12 32 MiB ESP cap via the GPT-ESP path.
- [ ] NUC network silent on real I219 — needs hardware time.

## Storage driver maturity

- [ ] AHCI NCQ (serialises on slot 0 today); hot-plug / COMRESET retry;
  multi-port naming (`sd1`...).
- [ ] NVMe multi-queue + multi-namespace.
- [ ] Partition: extended-CHS chains, BSD disklabel, APM; GPT UTF-16
  names into the block tag; `mount /dev/sd0p1 /mnt` path-to-slot
  resolver.
- [x] On-target installer (#172): lays down a fresh GPT disk (FAT ESP +
  UEFI stub + ext4 root) from a running system. (No GRUB / MBR — the
  boot path is the native UEFI stub.)
- [ ] ext4 mkfs multi-block-group layout; journal (jbd2) at mkfs time.

## Input

- [x] International keyboard layouts + mouse scroll + BT HID (#178)
  landed.
- [ ] Dead-key / compose / IME; blocking read on `/dev/mouse`; MADT
  IRQ-override consumption.

## Userspace polish — known gaps

- [ ] `enter linux { /bin/sh }` interactive stdin: opens but typing
  doesn't reach the Linux process. sshd-driven sessions get their own
  pty so they aren't affected.
- [ ] Nested `` `{ } `` command substitution clobbers (hamsh).
- [ ] TEMP_DEBUG cleanup pass when bring-up stabilises: `[hamsh-alive]`
  heartbeat, `[execve-sysret]` register dump, `[execve-pml4]` walk,
  trap-EMERG-level bumps, `[I TOLD YOU SO]` sentinel, the hamsh
  `_dbg_stage` markers, per-binary `[runtime:NAME] _start` markers —
  all tagged with `TEMP_DEBUG_*` comments for grep-and-remove.
- [ ] busybox `ls` enumeration XFAIL (musl DIR-fd round-trip); busybox
  `sh -c "a|b"` internal-pipeline `#GP`.
- [ ] `/bin` tool audit for cwd-relative defaults.
- [ ] CPython: trim the frozen stdlib set; PGO/LTO; C extensions
  (`_ssl`, `_socket`, ...) once a U-track `ld.so` exists.

## Bigger lifts — no immediate plan

- [ ] iwlwifi / ath11k / mt76 — bring up real radios. Firmware ships
  via the planned `non-free-firmware` channel at
  `https://255.one/non-free-firmware/` (placeholder live since
  2026-05-27; see `memory/project_nonfree_repo.md`).
- [ ] Browser (Firefox / Chromium) in a hamUI window — gated on
  hamUI Phase 5 (X11 bridge).
- [x] Suspend / power management (#168): ACPI suspend/resume + thermal
  + battery + ACPI shutdown landed.
- [~] Multi-arch (ARM64) (#175): Adder aarch64 backend landed — both
  `aarch64-linux` (runnable Linux ELF) and `aarch64-bare-metal`
  (QEMU `virt` boot stub over PL011 UART). **Open**: full bare-metal
  kernel port (Phase 3+).
- [ ] **Arch convergence (tracked goal).** Today `arch/arm64/kmain.ad`
  is a standalone single-file spine that proves primitives phase-by-phase
  and does NOT link the mature x86 core (`sys/src/9/port/`, `kernel/`,
  `mm/`, `fs/`, `net/`, `drivers/`). The endgame is to factor an
  arch-interface (boot/MMU/trap/timer/IRQ/per-CPU/context-switch hooks)
  and link the shared portable core into the ARM64 port — Linux's
  one-core/per-arch-backend model. **Gating decision (user, 2026-06-03):
  do this once the ARM64 bring-up is stable** — keep proving primitives
  phase-by-phase first, then converge; do not converge prematurely.
- [ ] **#186 Native packages go source-based (Gentoo-style).** Since the
  Adder compiler self-hosts on-box (#154), the **native** `hpm` repo
  becomes **source-primary + optional binary cache** (Gentoo source+binpkg
  model, locked with user 2026-06-01). A package's source of truth is a
  source tarball — `.ad` sources + a recipe (name, version, runtime
  `depends`, `builddeps`, compile target `x86_64-adder-user`, produced-
  binary→install-path map). `index.json` always carries `src_url`/
  `src_sha256`; the binary becomes an OPTIONAL cache (`bin_url`/
  `bin_sha256` + an `arch` tag — wrong-arch cache ignored, falls back to
  source). `hpm install` defaults to compile-from-source (fetch source →
  resolve builddeps → invoke the on-box compiler → install map), prefers
  the cache when arch-matched, `--from-source` forces a rebuild. CI keeps
  building the binary (now the cache) AND publishes source. **Native repo
  ONLY** — Debian/namespace packages stay prebuilt `.deb` via apt/dpkg in
  the distrofs namespace. Payoff: ARM64 (#175) source packages "just work"
  once the compiler ports — no per-arch binary build farm.
- [ ] Signed package indexes (sha256 covers tarballs; the index itself
  is unsigned today).
- [ ] Kernel oops capture (svc logs cover userland; kernel panics
  vanish into the serial console).
