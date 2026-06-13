# Hamnix TODO

What's still open. **For what's shipped, read [`STATUS.md`](STATUS.md)** —
it's append-only, dated, and the source of truth.

Pointers:
- Design: [`docs/architecture.md`](docs/architecture.md),
  [`docs/native-api.md`](docs/native-api.md) (Layer 1 Plan 9 syscalls),
  [`docs/hamUI.md`](docs/hamUI.md), [`docs/security.md`](docs/security.md).
- Snapshot: [`README.md`](README.md). Onboarding: [`CONTRIBUTING.md`](CONTRIBUTING.md).

Markers: `[ ]` open · `[~]` in flight.

---

## ⚠ Namespace law

Hamnix is **Plan 9-shaped. There is NO global filesystem route.** A
process sees a path only because something was *bound or mounted into
its own namespace*. **No work may write to a global `/var`/`/usr`/
`/etc`/`/var/lib/dpkg`/`/var/cache/apt`/`/var/www`.** All Linux-binary-
shim and distro/package state lives inside a distro-shaped namespace
exported by the userland **`distrofs`** 9P daemon; a shim is launched
`rfork(RFNAMEG)` → mount/bind `distrofs` → exec. A TODO is mis-shaped
if it says "write X to `/var/...`" without "...in the shim's distrofs
namespace" — fix the wording.

## ⚠ Boundary-discipline law

**Layer 1 (native) stays pure 9P / namespace.** The non-file modern
mechanisms — `io_uring`, `epoll`, `futex`, signalfd/eventfd/timerfd —
are the antithesis of "everything is a file." Permitted **only inside
Layer 2** as confined kernel objects for Linux guests. The moment one
becomes a native-code dependency, the architecture has been retrofitted
backwards.

---

## P9-shape hammer — current wave

**Closed (see STATUS rows for cites + gates):** F1 #446, F2 #447,
F3 #448, F4 #449, F5 #445, F6 #450, F8 #451, F9 #452. F10 second-pass
audit #453 closed; report at `audit_F10_report.md`. F10-1 #454, F10-2
#455, F10-3 #456 closed.

**Open:**
- [~] **F7 #390** — FD-mark fold continuation post-4c (stdio/tmpfs/
  pipes/socketpair/p9/net/epoll-family/ptmx/fuse still mark-based;
  pipes = highest-leverage next fold; `NR_FDS=16` per task will pinch
  Debian userland).
- [~] **F10-6 #458** — Plan 9 `Dir` record minimum viable landed
  (`b9572451`): `lib/p9dir.ad` wire format + `lib/p9.ad` decoder +
  `SYS_LISTDIR_RECORDS=318` + devsrv emits Dir; deferred:
  `_dirfile_read`/devproc migration (needs per-Chan `p9_dir_mode` flag)
  and userland `ls`/`du` migration.
- [~] **F10-4 (#457) structural landed `d193bbf8`** — do_mount no
  longer silently drops afd; Tauth runs when afd != -1, devauth-backed
  uname passed into Tattach. Test scaffolding compiles + boots green
  but printk-based e2e verification was flaky (agent timeout). Re-tool
  the test harness as follow-up. (F10-5 `a38cae28`; F10-7 bonus in
  F10-2; F10-8 `983e1ce8`; F10-9/11/12 `f9c61595`; F10-10 `a31cfb00`.)
- [~] **#459 fixed** `863f1765` — root cause was NOT the F10 wave but
  pre-existing F6 regression: `vfs_read` EISDIR short-circuit on
  DEV_DIR_FILE made every `p9_listdir` return -1 since #450 (74ff35e7);
  svc_load_all_defs silently registered nothing → runlevel-5 spawned
  nothing. Fix drops the short-circuit, lets namec_read emit "NAME\n".
  Follow-up: task-slot pool sizing under runlevel-5 burst (separate).

## Phase 4 — unify fds on `Chan` (#390)

`[x] 4a` + `[x] 4b` + `[x] 4c` landed (see STATUS). Remainder mapped by
F7 above. Layer-2 linux_abi event fds (epoll/eventfd/timerfd/signalfd/
inotify/iouring/perf/bpf/pidfd) stay marks by design (boundary-discipline
law).

---

## hamUI / DE track

DE/MATE-mirror work is **gated behind the P9-shape wave landing
cleanly** (per #459 above). When that's clear:

- [~] **Phase 4d** — BDF font store landed `24d867eb`: 3 fonts under
  `fonts/`, `lib/font_bdf.ad` parser, `<text font="sans">…</text>` markup
  routed to family dispatch with mono fallback. Deferred: runtime BDF
  file loading (compiled-in glyph tables for v1) + visual installer-image
  screenshot.
- [~] **`lib/hamui.ad` MATE-class widget set** — menu/menubar,
  scrolledwindow, dialog/modal, notebook/tabs, radio, slider/scale,
  spinbutton, combobox, progressbar, separator, image, toolbar,
  statusbar, treeview/grid, multi-line editable textview. Plus grid
  layout container + per-widget align/expand/fill, dynamic editing
  (insert/delete at caret, selection), widget destruction, damage/dirty
  tracking. v1 (#423, MATE-class baseline) + Increment 1/2/3 (#427-#429)
  landed — see STATUS rows.
- [~] **Rio-faithful reshape** (user 2026-06-11): (a) `#w` per-process
  namespace bind LANDED `616c41c4`; (b) blocking reads via WaitQueue
  already in main (verified during a); (c) image+dirty-rect wire format
  SPEC landed (40-line block at top of devwsys.ad), implementation
  across devwsys+hamUId+lib/hamui deferred to next increment.
- [~] **Basic apps** — terminal+file browser landed earlier; Snake +
  2048 menu-wired `5dd8b01b` (hamsnake/ham2048 binaries already existed,
  added Applications-menu "Games" category). Remaining: text editor.
- [ ] **hamsh `use hamui`** — bindings; may need hamsh closures +
  event loop + persistent state.
- [ ] Per-window namespace + elevation visible in `uid` / `ns` files
  (`newshell hostowner`, `hamUI new -as hostowner`).
- [ ] X11/Xvfb bridge in a kind=fb layer (path to Firefox/Chromium).
- [ ] snarf (clipboard), `wctl` resize/move, focus policies.

Remaining hamUId.ad-touching items (single 25k-line file, serialize
to avoid merge collisions): Display/Mouse/keyboard-layout settings
panels, external notification + system-tray client-registration API,
image wallpaper, screensaver+password-lock, real session save/restore,
inter-app drag-and-drop. PDF viewer (atril) deferred (needs font/PDF
stack).

> **ARM64 deprioritized below desktop work (user 2026-06-10).** Phase
> 50 preserved on `worktree-agent-a48facf53ef25a377` (`6f217d09`), NOT
> landed.

---

## GPU / graphics (#181–185, native-first)

Target: glxgears + vkcube spinning in a hamUI window, on accelerated
HW where present.

**Two laws (do not conflate):** (1) The DE never requires the Linux
*namespace*. Baseline is native Vulkan + native software rasterizer.
NOT lavapipe. (2) Linux `.ko` kernel modules via the L-shim ARE used
(`i915.ko` drives Intel silicon). `.ko` ≠ namespace.

- [~] **#181 Phase 0** — all-native Vulkan spine + software rasterizer
  + present/WSI. Zero Linux. Always-works baseline.
- [~] **#182 Phase 1** — native virtio-gpu + native venus (Vulkan
  marshalling) in a VM. Validates DRM/dma-buf/ioctl contract.
- [~] **#183 Phase 2** — DE composites via the native spine; Linux X11
  apps bridge IN via venus-shaped shim ICD + Zink, optional.
- [ ] **#184 Phase 3 (METAL-ONLY)** — Intel i915 silicon via `i915.ko`
  through L-shim: GEM+GTT/PPGTT, real KMS modeset, execlist+dma-fence,
  GuC/HuC firmware. Native software rasterizer stays the DE baseline.
- [ ] **#185 Phase 4 (long pole, optional)** — native
  ANV-equivalent (Intel-Gen ISA shader compiler + cmd-buffer build +
  bo alloc + execlist submit over #184's i915). Removes the last
  namespace dependency for HW accel.

---

## Open kernel work

Phase D inversion + §1..§13 critical path is closed. What remains:

### Latent crashes
- [ ] **#439 probabilistic post-exit wedge** — buddy DOUBLE FREE then
  CYCLE in `_try_remove_buddy` with IRQs masked. WIP fix on
  `worktree-agent-ae2373654138b1014` (`9944f32b` snapshot) + backup on
  `worktree-agent-a9c57d837298c09e7` (`a22bd04f` snapshot). Locks alone
  insufficient — genuine double-free in some reclaim path persists.
  Triage deferred until F10 wave finishes.

### Phase D follow-ups
- [x] Layer-2 `/proc → /dev` namespace bind — landed `e09596bb`:
  9 per-leaf binds in pgrp_init (cpuinfo/meminfo/uptime/loadavg/version/
  hostname/stat/mounts/diskstats); deleted ~180 lines of
  `_u_translate_proc_to_dev` string-rewrite.
- [ ] Union mounts MBEFORE/MAFTER (flag recorded; longest-prefix only).
- [x] `create(260)` DMDIR — already routed through `vfs_mkdir`; test
  coverage added `47ab21c5`.
- [~] `stat`/`fstat` per-backend hooks — path-keyed `do_stat` migrated
  to F10-2-shape hook table `47ab21c5`. `do_fstat` already per-backend
  inline; per-server hook migration deferred.
- [x] `fd2path` exact open()-time path — landed `9f9d9db3`.
- [x] `wstat` length/mtime/mode — already in `_apply_wstat` (verified +
  tested `9f9d9db3`). gid/muid still rejected with errstr; needs
  per-inode storage (separate round).
- [~] Delete the global `/var` tmpfs — per-Pgrp bind `/var → #t/var`
  already in place at `chan.ad:925` (F1 substrate). Namespace contract
  test added `9f9d9db3`. Backend-internal `vfs_mount` router entry
  remains; removal requires FS routing model migration.

### §3 Signals
- [~] Plan 9 `note_group` + cross-task `/proc/<pid>/note` structural
  landed `660978bb` (salvaged): note_pending queue + flag in TaskStruct,
  trap-return checks + delivers via handler or terminates;
  `note_group_send(pgrp_id, msg)` broadcast; `scripts/test_notedrain.sh`
  scaffolding committed. Runtime verification pending.

### §5 Modern async I/O (Layer 2 only)
- [ ] `io_uring` SQ/CQ rings (deferred; epoll covers most real Linux
  daemons).

### §7 Entropy
- [~] ChaCha20 CSPRNG: seeding + fast-key-erasure + reseed cadence
  landed (`sys/src/9/port/devrandom.ad::_maybe_reseed`).

### §8 SMP
- [~] MADT-driven SMP landed; per-CPU runqueue + load balancing
  (#139, #151, #397). Open: work stealing, CPU affinity.

### §10 Networking
- [ ] Generic unicast ARP helper; ICMP time-exceeded / redirect.

### §12 FS write maturity
- [ ] ext4 truncate on index-node files; growing a full ext4 dir block.

### §13 cdev / proc completions
- [~] `/proc/net/*` — in flight.
- [ ] Per-backend errstr + user-mode `perror` helper.

### §14 Security (stretch)
- [ ] `seccomp-bpf` (full classic-BPF program).

### §15 Compiler
- [ ] `match`/`case` tokenization → implement.

### §17 stock-Linux `.ko` (lowest)
- [ ] `MAX_EXPORTS` bumps; `usbcore`+`xhci_hcd`, `libphy`, `8021q`,
  `nf_conntrack` core. Weigh vs native drivers.

---

## Metal bring-up (human-in-the-loop)

- [ ] **xHCI hand-rolled v1 metal sub-skip** — HCH-clear MMIO poll
  wedges on real Intel NUC silicon; CPUID hypervisor-leaf detect
  skips it on metal (`ENABLE_XHCI_FORCE_INIT=1` overrides).
- [ ] Asus i5-4210U crashes during boot (regression observation).
- [ ] Asus built-in keyboard never responded under Legacy/BIOS;
  hypothesis EHCI-routed.
- [ ] MMIO-stall class audit: `drivers/usb/ehci.ad` (BIOS→OS handoff
  ~593, HCRESET ~647, port-reset ~750/~760); `drivers/ata/ahci.ad::
  _ahci_port_start` (CR/FR, CI); `drivers/nvme/nvme.ad` (unaudited).
- [ ] Real NIC silicon: e1000e EEPROM on physical Intel; r8169 RX on
  RTL8168; Broadcom tg3; Intel igb.
- [ ] Drop the FAT12 32 MiB ESP cap via GPT-ESP path.
- [ ] NUC network silent on real I219 — needs HW time.
- [ ] **#117/#118** — Verify >4GB fix kills real-HW #UD + persisted
  logs (USB boot at `-m 8G`).

## Storage driver maturity

- [ ] AHCI NCQ (serialises on slot 0 today); hot-plug / COMRESET
  retry; multi-port naming (`sd1`...).
- [ ] NVMe multi-queue + multi-namespace.
- [ ] Partition: extended-CHS chains, BSD disklabel, APM; GPT UTF-16
  names; `mount /dev/sd0p1 /mnt` path-to-slot resolver.
- [ ] ext4 mkfs multi-block-group layout; journal at mkfs time.

## Input

- [ ] Dead-key / compose / IME; blocking read on `/dev/mouse`; MADT
  IRQ-override consumption.

## Userspace polish

- [ ] **#439 family** — `enter linux { /bin/sh }` interactive stdin:
  opens but typing doesn't reach the Linux process. sshd-driven
  sessions have their own pty.
- [ ] Nested `` `{ } `` command substitution clobbers (hamsh).
- [ ] TEMP_DEBUG cleanup pass when bring-up stabilises: `[hamsh-alive]`
  heartbeat, `[execve-sysret]` register dump, `[execve-pml4]` walk,
  trap-EMERG-level bumps, hamsh `_dbg_stage` markers, per-binary
  `[runtime:NAME] _start` markers — all tagged `TEMP_DEBUG_*`.
- [ ] busybox `ls` enumeration XFAIL (musl DIR-fd round-trip);
  busybox `sh -c "a|b"` internal-pipeline `#GP`.
- [ ] `/bin` tool audit for cwd-relative defaults.
- [ ] CPython: trim frozen stdlib; PGO/LTO; C extensions (`_ssl`,
  `_socket`, ...) once a U-track `ld.so` exists.

## Bigger lifts — no immediate plan

- [ ] iwlwifi / ath11k / mt76 — real radios. Firmware via the planned
  `non-free-firmware` channel at `https://255.one/non-free-firmware/`
  (placeholder live 2026-05-27).
- [ ] Browser in a hamUI window — gated on hamUI Phase 5 (X11 bridge).
- [~] Multi-arch ARM64 (#175): Adder aarch64 backend landed
  (`aarch64-linux` + `aarch64-bare-metal` QEMU virt). **Open:** full
  bare-metal kernel port (Phase 3+).
- [ ] **Arch convergence** — factor an arch-interface (boot/MMU/trap/
  timer/IRQ/per-CPU/context-switch hooks) and link the shared portable
  core into ARM64. Gating: do once ARM64 bring-up is stable (user
  2026-06-03).
- [~] **#186 Native packages source-based (Gentoo-style)** — source-
  primary + optional binary cache. `index.json` carries
  `src_url`/`src_sha256`; binary is OPTIONAL cache. `hpm install`
  defaults compile-from-source. Native repo only — Debian/namespace
  packages stay prebuilt `.deb`. Payoff: ARM64 source packages "just
  work" once the compiler ports.
- [ ] Signed package indexes (sha256 covers tarballs; index unsigned).
- [ ] Kernel oops capture (svc logs cover userland; kernel panics
  vanish into the serial console).
