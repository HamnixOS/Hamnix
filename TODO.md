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

## Now — useful-system gap fill (priority-ordered, locked with user 2026-05-28)

1. [~] **hamUI Phase 2** — multi-window via `/dev/wsys/<N>/`; bg hamsh
   instances; serial console stays on wid 1. (in flight)
2. [ ] **hamUI Phase 4a** — layered draw protocol cdev plumbing
   ([`docs/hamUI.md`](docs/hamUI.md) H-§G): per-window
   `/dev/wsys/<wid>/draw/<name>/{kind,z,opacity,geometry,markup,fb}`
   + `ctl` verbs (`mklayer` / `rmlayer` / `setz` / `ls`). No
   rasterisation yet; just the file surface.
3. [ ] **hamUI Phase 4b** — `hamUId` userland renderer daemon: hamML
   parser + bitmap-font rasteriser + compositor.
4. [ ] **hamUI Phase 4c** — framebuffer driver + drag-to-create
   gesture (H-§D).
5. [ ] **hamUI Phase 4d** — bitmap font store (mono/sans/serif BDF).
6. [ ] **`lib/hamui.ad`** — Adder graphics library wrapping H-§G
   (Window/Layer/Rect/Text/Image/Button/Input/Event + event loop).
   See [[memory/project_app_language_decision]] — Adder + hamsh,
   no third tier.
7. [ ] **hamsh `use hamui`** — bindings on top of #6. May require
   hamsh extensions for closures + event loop + persistent state.
8. [ ] **Outgoing `ssh` client** — `sshd` ships but nothing dials out.
   `curl`/`wget` now exist (shared `user/http9.ad`); an SSH *client*
   is a separate protocol/crypto lift still to do.
9. [ ] **Pipes + job control in hamsh** — audit `|`; add `&`
    background, `bg`/`fg`/`jobs`, process groups + SIGTSTP/SIGCONT.
10. [ ] **Real editor** — vi-shape or acme-shape. `ed` is too minimal.
11. [ ] **`tar` + `gzip` / `gunzip`** — share/backup workflows.
12. [ ] **Audio** — `snd_hda_intel.ko` loads cleanly; need `aplay`-shape
    userland tool that pushes PCM to the cdev.
13. [ ] **`hpm update` + rollback** — install works; in-place upgrade
    + snapshot-before-upgrade do not.

## hamUI later phases (after Phase 4)

- [ ] **Phase 3** — per-window namespace + elevation visible in `uid` /
  `ns` files (`newshell hostowner` inside; `hamUI new -as hostowner`
  direct). H-§B.
- [ ] **Phase 5** — X11/Xvfb bridge in a kind=fb layer. Path to
  Firefox/Chromium. H-§C.
- [ ] **Phase 6** — snarf (clipboard), `wctl` resize/move, focus
  policies.

---

## Open kernel work

The Phase D inversion + §1..§13 critical path is **closed** (see
STATUS.md). What remains, off the critical path and parallelisable:

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
- [ ] vDSO: map `gettimeofday`/`clock_gettime` without syscall overhead.

### §7 Entropy / RNG
- [ ] ChaCha20 CSPRNG promotion beyond M16.96 (RDRAND/RDSEED seeding
  +  reseed cadence); distinct blocking `/dev/random` vs non-blocking
  `/dev/urandom` — today both alias the same pool (D5/F2).

### §8 SMP & scheduler
- [ ] Per-CPU runqueues + real SMP scheduling (AP bringup works;
  single-rq today); load balancing / work stealing; CPU affinity.

### §10 Networking
- [ ] Congestion control: slow-start + congestion-avoidance (RFC 5681),
  NewReno or CUBIC.
- [ ] Multi-listener accept queue / wider TCB table; window scaling +
  SACK + timestamps.
- [ ] Generic unicast ARP helper; ICMP time-exceeded / redirect.
- [ ] IPv6 (and DNS AAAA records, gated on IPv6 header).

### §12 Filesystem write maturity
- [ ] ext4 truncate on index-node (`eh_depth>0`) files; growing a
  full ext4 directory block; multi-cluster FAT directories.
- [ ] ext4 extent index-node support (depth>0 leaves) — D5 caps at
  depth-0 4-slot leaf today (~512 MiB max file when contiguous).

### §13 cdev / proc completions
- [ ] `/proc/net/*`.
- [ ] Per-backend errstr (ext4 / fat / blk) + user-mode `perror` helper.

### §14 Resource control & security (stretch)
- [ ] Per-namespace CPU/memory caps (ride the namespace model, not
  Linux cgroups); `seccomp-bpf`; POSIX capabilities (drop-root
  daemons).

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
- [ ] EFI Runtime Services (`GetTime`, `GetVariable`); PE `.reloc`
  table (Secure Boot prereq); drop the FAT12 32 MiB ESP cap via the
  GPT-ESP path.
- [ ] NUC network silent on real I219 — needs hardware time.

## Storage driver maturity

- [ ] AHCI NCQ (serialises on slot 0 today); hot-plug / COMRESET retry;
  multi-port naming (`sd1`...).
- [ ] NVMe multi-queue + multi-namespace.
- [ ] Partition: extended-CHS chains, BSD disklabel, APM; GPT UTF-16
  names into the block tag; `mount /dev/sd0p1 /mnt` path-to-slot
  resolver.
- [ ] ext4 mkfs multi-block-group layout; journal (jbd2). Installer
  plumbing already has the ext4 write path; GRUB-install + MBR-write
  still missing.

## Input

- [ ] International keyboard layouts (`kbd_set_layout` + compiled-in
  tables); dead-key / compose / IME; PS/2 mouse 4-byte scroll-wheel;
  blocking read on `/dev/mouse`; MADT IRQ-override consumption.

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
- [ ] Suspend / power management.
- [ ] Multi-arch (ARM64) — currently x86_64 only.
- [ ] Signed package indexes (sha256 covers tarballs; the index itself
  is unsigned today).
- [ ] Kernel oops capture (svc logs cover userland; kernel panics
  vanish into the serial console).
