# Hamnix TODO

What's still open. **For what's shipped, read [`STATUS.md`](STATUS.md)** —
it's append-only, dated, and the source of truth.

Pointers:
- Design: [`docs/architecture.md`](docs/architecture.md),
  [`docs/native-api.md`](docs/native-api.md) (Layer 1 Plan 9 syscalls),
  [`docs/hamUI.md`](docs/hamUI.md), [`docs/security.md`](docs/security.md).
- Snapshot: [`README.md`](README.md). Onboarding: [`CONTRIBUTING.md`](CONTRIBUTING.md).
- Latest audits (2026-06-13): [gap vs Linux](docs/audit_gap_vs_linux_2026-06-13.md),
  [arch shortcuts](docs/audit_arch_shortcuts_2026-06-13.md).

Markers: `[ ]` open · `[~]` in flight.

---

## ⚠ Direction (2026-06-13, post-audit)

Two fresh audits landed today. Both agree: Plan 9 spine is real and held;
many subsystems claim "done" but are stubs or in-memory selftests. The
next push is **post-audit cleanup wave**, not a new keystone. Pile-of-
disjoint-fixes cadence, multiple parallel agents.

**Top blockers to "ship as a real Linux competitor" (gap audit):**
1. Kernel capacity caps: `NTASKS=16` / `NR_FDS=16` / TCP `MAX_SOCKETS=8`
   — no Debian server workload survives. Lift to 256+ each.
2. `accept()`/`bind()`/`listen()` are stubs in the Linux ABI shim. Real
   server binaries (openssh-server, nginx, postgres) cannot run as
   advertised.
3. Net-protocol selftest dishonesty: ~17 files in `drivers/net/*.ad`
   (sctp, mptcp, wireguard, ipsec, macsec, vxlan, geneve, gre, l2tp,
   ipip, sit, nat64, igmp, bond, bridge, vlan, ipvlan, macvlan) are
   IN-MEMORY selftests per their own headers — NOT wired to any NIC
   or `/net` path. README & STATUS frame them as real. Either wire or
   relabel.
4. `u_caps.ad` gates NOTHING — POSIX capabilities are paper.
5. No KASLR, no KPTI, no SMEP/SMAP wiring. Security posture below
   2008-era Linux.
6. No cgroups at all (`u_syscalls.ad:7754` is comment-only). systemd
   and containers cannot run.
7. No suspend/resume. Laptops drain on lid close.
8. No kernel oops capture — kernel panics vanish into the serial
   console.

**Top architectural shortcuts (arch audit):**
9. **Compositor monolith still 28,152 LOC.** DE pivot waves 1–6
   ADDED v2 client apps but did not SUBSTITUTE — `daemon_pixel` still
   draws 613 lines of menu fallbacks. Finish substitution.
10. **DE tests are 100% structural grep.** None boot QEMU and verify
    render. The v2 waves are unprovable until a runtime DE test lands.
11. **F2 syscall sprawl unchanged.** `SYS_NICE`/`SVC_CTL`/`NETCFG`/
    `WSYS_*`/`RESOLVE_*` arms still carry FULL bodies in
    `arch/x86/kernel/syscall.ad`; the new ctl files are a PARALLEL
    implementation, not the implementation.
12. **5 of 11 perm bodies are world-r/w stubs** (tmpfs, fat, devcons,
    devsrv, devauth). Three (devblk/devproc/devnet) really enforce.
    tmpfs is exploitable once multi-user lands.
13. **10 hostowner gates** still raw `current_task_uid() != 1` in
    `arch/x86/kernel/syscall.ad` — bypass the F3 server boundary.
14. **F10-9 over-claim:** `is_ext_path` still imported in
    `linux_abi/u_syscalls.ad:603,3338,7376`.
15. **Plan 9 `Dir` records** emit only from `/srv` so far —
    devproc/devnet/devblk listings still `NAME\n`. F10-6 MVP needs
    followthrough.
16. **#439 buddy DOUBLE FREE** still parked — genuine reclaim-path
    double-free; locks alone insufficient.

NUC: boots; USB mouse still dead on metal (filed, not blocking).

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

## Post-audit cleanup wave (current focus)

> **RECONCILED 2026-06-17** (source-verified, not audit-snapshot). ~12 of
> the 16 post-audit items below are DONE since the 2026-06-13 audit and
> have been checked off. **Genuinely still open:** CPU-mitigations
> (SMEP landed; **SMAP CR4-flip + KASLR + KPTI** open — the SMAP flip is
> gated OFF because high-half kernel pages are US=1 and flipping would
> triple-fault until they're re-stamped US=0); **suspend/resume** (S3
> suspend path real; HW **wake-vector trampoline** in entry.S pending);
> **F2 thin-shim** (delegation done, arm bodies physically remain);
> **DE pivot dead-code removal** (functionally retired at runtime;
> ~20K dead LOC still in `user/hamUId.ad`). The buddy double-free (#439)
> is FIXED (boot-CR3 guard, `mm/page_alloc.ad:40-65`), not parked.

Disjoint, parallelizable. Top items go through agents first.

### Capacity & Linux-ABI blockers (gap audit)

- [x] **Lift kernel capacity caps.** (DONE: NTASKS=256, NR_FDS=64, TCP slots=256.) `NTASKS=16` → 256 (or grow
  dynamically); per-task `NR_FDS=16` → 256; TCP `MAX_SOCKETS=8` → 256.
  Audit other hardcoded small caps. Cite: `kernel/sched/core.ad:939,5553`,
  `drivers/net/tcp.ad:187`.
- [x] **Real `listen()`/`accept()`/`bind()` in Linux ABI.** (DONE: AF_INET via tcp_listen/tcp_accept + AF_UNIX + AF_NETLINK + UDP, all real.) Today only
  client-side `connect` works (`linux_abi/u_syscalls.ad:14421` header).
  Implement the server-side socket triple over native `/net` 9P so
  openssh-server, nginx, postgres start.
- [x] **Net-protocol honesty pass.** (DONE: all 18 files carry honest "in-memory selftest only" / "real data paths wired" banners; STATUS framing accurate.) For each of sctp/mptcp/wireguard/
  ipsec/macsec/vxlan/geneve/gre/l2tp/ipip/sit/nat64/igmp/bond/bridge/
  vlan/ipvlan/macvlan: either wire to the NIC/`/net` data path OR add a
  prominent "in-memory selftest only" comment + remove from STATUS
  "real" framing.
- [x] **u_caps wiring.** (DONE: CAP_SYS_ADMIN gates mount; CAP_NET_ADMIN gates devnet ctl.) Make capset/capget gate at least the obvious
  ops (CAP_NET_ADMIN, CAP_SYS_ADMIN). File's own header
  (`linux_abi/u_caps.ad:18-20`) admits it gates nothing.
- [ ] **CPU-mitigations & kernel hardening.** Wire SMEP/SMAP (CR4
  bits + `clac/stac` at uaccess boundaries); KPTI; KASLR; STATUS line
  about kernel lockdown. `arch/x86/kernel/trap_diag.ad:382` literally
  says SMAP not enabled.
- [x] **cgroup v2 skeleton.** (DONE: real cpu.max bandwidth controller, scheduler-enforced — kernel/sched/cgroup_cpu.ad.) At least one real controller (cpu or
  memory) gated by `/sys/fs/cgroup/<group>/cpu.max`. systemd refuses
  to boot without this.
- [ ] **Suspend/resume.** S3 + S0ix on ACPI. Save/restore CPU state +
  device callbacks.
- [x] **Kernel oops capture.** (DONE: panic()→_persist_oops writes OOPS.BIN+LOG.TXT to ESP; user/oopsread.ad reader.) `panic()` writes a structured record to
  the ESP `LOG.TXT` extent (already wired for boot log). Then `journalctl
  -k`-shape userland reader. Cite TODO.md:309.

### Architectural correctness (arch audit)

- [ ] **F2 thin-shim conversion.** Replace `SYS_NICE`/`SYS_SVC_CTL`/
  `SYS_NETCFG`/`SYS_RESOLVE`/`SYS_WSYS_*` syscall ARM BODIES with thin
  shims that delegate to the corresponding ctl file. The ctl files are
  the real implementation; the syscall arms must stop duplicating.
- [x] **Perm-body real-enforcement pass.** (DONE: tmpfs per-inode mode; fat hostowner-write/world-read; devcons/devsrv real gates; devauth admit-all by design — gate is in the cdev.) Replace world-r/w stubs in:
  `fs/tmpfs.ad::tmpfs_perm_check` (give entries per-inode mode bits);
  `fs/fat.ad::fat_perm_check`; `sys/src/9/port/devcons.ad`; `devsrv.ad`;
  `devauth.ad`. tmpfs first (highest exploit surface).
- [x] **Hostowner-reach cleanup.** (DONE: 0 raw `current_task_uid() != 1` left in syscall.ad; routed through `_syscall_require_hostowner`.) Route the 10 raw `current_task_uid()
  != 1` checks in `arch/x86/kernel/syscall.ad` through the F3 server
  boundary (`_perm_check_<X>` at the file open / write site), so policy
  lives in one place per resource.
- [x] **F10-9 followthrough.** (DONE: no live `is_ext_path` import/call site remains; only a retired-ladder comment.) Delete `is_ext_path` and its remaining
  call sites at `linux_abi/u_syscalls.ad:603,3338,7376`.
- [x] **Plan 9 `Dir` record full emission.** (DONE: devproc + devnet + devblk all emit Dir records; the devblk path was un-shadowed by fixing the SYS_SECCOMP_NATIVE=318 collision → 320, commit 6bea0bfd. Remaining F10-6 follow-on: real atime/mtime + per-task uid.) F10-6 MVP only emits from
  `/srv`. Extend to devproc / devnet / devblk dir listings so userland
  can `stat`-per-line without re-stat.
- [ ] **DE pivot finish — substitution not addition.** Wave 1–6 added
  v2 client apps without deleting the corresponding `daemon_pixel`
  fallback paths. Now physically remove the dead render code and the
  no-op markers, replace the `daemon_pixel` framework with a thin
  router. Compositor target: drop `user/hamUId.ad` below ~10 KLOC.
- [x] **Runtime DE smoke test.** (DONE: test_installer_de_runlevel5.sh boots QEMU/OVMF + pmemsave framebuffer pixel-distinctness gate; plus test_de_scene_render/termfm/menu_input.) Boot the installer image in QEMU,
  open a terminal, screenshot. Compare to a baseline. This is the
  first non-grep DE test.
- [x] **#439 buddy DOUBLE FREE.** (DONE: root-caused to free-list links stored under a user CR3 landing in COW pages; fixed with boot-CR3 guard, mm/page_alloc.ad:40-65.) Genuine reclaim-path double-free;
  locks alone insufficient. Bisect against a reclaim disable.

---

## P9-shape hammer — long tail

**Closed (see STATUS rows for cites + gates):** F1 #446, F2 #447,
F3 #448, F4 #449, F5 #445, F6 #450, F8 #451, F9 #452. F10 second-pass
audit #453 closed; report at `audit_F10_report.md`. F10-1 #454, F10-2
#455, F10-3 #456 closed.

**Open:**
- [~] **F7 #390** — FD-mark fold continuation. Pipes next (highest
  leverage; `NR_FDS=16` cap will pinch Debian userland once lifted).
- F10-4 through F10-12: nine more findings from F10 audit (afd Tauth,
  init/main.ad split, Dir record, etc.).

---

## hamUI / DE track

- [~] **`lib/hamui.ad` MATE-class widget set** — menu/menubar,
  scrolledwindow, dialog/modal, notebook/tabs, radio, slider/scale,
  spinbutton, combobox, progressbar, separator, image, toolbar,
  statusbar, treeview/grid, multi-line editable textview. Plus grid
  layout container + per-widget align/expand/fill, dynamic editing
  (insert/delete at caret, selection), widget destruction, damage/dirty
  tracking. v1 + Inc 1/2/3 landed.
- [~] **Rio-faithful reshape** — `#w` per-process namespace bind LANDED.
  Image+dirty-rect wire format SPEC landed; impl across devwsys+hamUId+
  lib/hamui in DE pivot waves 1-6. Substitution finish above.
- [ ] **hamsh `use hamui`** — bindings; may need hamsh closures + event
  loop + persistent state.
- [ ] X11/Xvfb bridge in a kind=fb layer (path to Firefox/Chromium).
- [~] BDF font store landed; runtime font file loading deferred
  (compiled-in glyph tables for v1).

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
  marshalling) in a VM.
- [~] **#183 Phase 2** — DE composites via the native spine; Linux X11
  apps bridge IN via venus-shaped shim ICD + Zink, optional.
- [ ] **#184 Phase 3 (METAL-ONLY)** — Intel i915 silicon via `i915.ko`
  through L-shim.
- [ ] **#185 Phase 4 (long pole, optional)** — native ANV-equivalent.

---

## Open kernel work — long tail

### Latent crashes
- [ ] **#439 probabilistic post-exit wedge** — buddy DOUBLE FREE then
  CYCLE in `_try_remove_buddy` with IRQs masked. WIP fix on
  `worktree-agent-ae2373654138b1014` (`9944f32b` snapshot) + backup on
  `worktree-agent-a9c57d837298c09e7` (`a22bd04f` snapshot). Listed
  under post-audit wave above.

### Phase D follow-ups
- [~] `stat`/`fstat` per-backend hooks — path-keyed `do_stat` migrated
  to F10-2-shape hook table `47ab21c5`. `do_fstat` per-server hook
  migration deferred.
- [~] Delete the global `/var` tmpfs — per-Pgrp bind `/var → #t/var`
  already in place (F1 substrate). Backend-internal `vfs_mount` router
  entry remains; removal requires FS routing model migration.

### §3 Signals
- [~] Plan 9 `note_group` + cross-task `/proc/<pid>/note` structural
  landed `660978bb`. Runtime verification pending.

### §7 Entropy
- [~] ChaCha20 CSPRNG landed.

### §8 SMP
- [~] Per-CPU runqueue + load balancing landed (#139, #151, #397).
  Open: work stealing, CPU affinity.

### §10 Networking
- [~] Unicast ARP + gratuitous ARP + ICMP time-exceeded + ICMP redirect
  helpers landed `056d4500`. Forwarding-path auto-wiring gated behind
  `ip_forwarding_enabled` flag (default 0).

### §12 FS write maturity
- [ ] ext4 truncate on index-node files; growing a full ext4 dir block.
  (Attempt `bc1cb9c8` reverted as `bb7ba653` — broke heartbeat boot.)

### §17 stock-Linux `.ko` (lowest)
- [ ] `MAX_EXPORTS` bumps; `usbcore`+`xhci_hcd`, `libphy`, `8021q`,
  `nf_conntrack` core.

---

## Metal bring-up (human-in-the-loop)

- [ ] **xHCI hand-rolled v1 metal sub-skip** — HCH-clear MMIO poll
  wedges on real Intel NUC silicon.
- [ ] Asus i5-4210U boot crash; built-in keyboard never responded under
  Legacy/BIOS (hypothesis EHCI-routed).
- [ ] MMIO-stall class audit: ehci, ahci, nvme.
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

- [ ] **#439 family** — `enter linux { /bin/sh }` interactive stdin
  doesn't reach the Linux process. sshd-driven sessions have their own
  pty.
- [ ] Nested `` `{ } `` command substitution clobbers (hamsh).
- [ ] TEMP_DEBUG cleanup pass when bring-up stabilises.
- [ ] busybox `ls` enumeration XFAIL (musl DIR-fd round-trip);
  busybox `sh -c "a|b"` internal-pipeline `#GP`.
- [ ] `/bin` tool audit for cwd-relative defaults.
- [ ] CPython: trim frozen stdlib; PGO/LTO; C extensions once a U-track
  `ld.so` exists.

## Bigger lifts — no immediate plan

- [ ] iwlwifi / ath11k / mt76 — real radios. Firmware via the planned
  `non-free-firmware` channel at `https://255.one/non-free-firmware/`.
- [ ] Browser in a hamUI window — gated on hamUI Phase 5 (X11 bridge).
- [~] Multi-arch ARM64 (#175): aarch64 backend landed; full bare-metal
  kernel port (Phase 3+) open.
- [ ] **Arch convergence** — factor an arch-interface; link shared
  portable core into ARM64. Gating: do once ARM64 bring-up is stable.
- [~] **#186 Native packages source-based (Gentoo-style)** — landed
  defaults compile-from-source.
- [ ] Signed package indexes (sha256 covers tarballs; index unsigned).
