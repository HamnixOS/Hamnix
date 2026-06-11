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
each phase must still boot + pass the sweep.

Phases 1–3 DONE (see STATUS.md): `/dev` reference template (#388), literal-
arm sweep (`vfs_open` now has exactly ONE resolution path — zero literal
special-cases), and real `mount()` (#389, `a563d31b` — a VFS mount table
replaces the ~70 `is_*_path` backend-selection branches).

- [~] **Phase 4 — unify fds on `Chan`** (#390). Retire the
  collision-prone `FD_*_MARK` magic-integer ranges; every fd becomes a
  `Chan` through the `namec` devtab.
  - [x] Phase 4a — stateless native cdevs DONE (`091fde11`): the 13
    stateless synthetic cdevs open as `FD_CHAN_MARK` fds; behavior lives
    in namec's `_devtab_read`/`_devtab_write`.
  - [ ] **Phase 4b — stateful native fds.** `FD_EXT4`/`TMPFS`/`FAT`/
    `BUFFER`/`DIR`/`PIPE_R`/`PIPE_W`/`SOCKET`/`BLK`/`STAT`/`MOUNTS`/
    `DISKSTATS`/`AUTH`/`VTCTL`/`DEVFD`/`PROC_BASE` carry per-fd offset/
    inode/buffer state; needs a pool-`ChanT` lifecycle (extend the handle
    + slot alloc/free) before they can move off marks. Layer-2 linux_abi
    event fds (epoll/eventfd/timerfd/signalfd/inotify/iouring/perf/bpf/
    pidfd) stay marks by design (boundary-discipline law — not namespace
    files).

## Now — useful-system gap fill

1. [ ] **hamUI Phase 4d** — bitmap font store (mono/sans/serif BDF).
2. [~] **`lib/hamui.ad` — GTK/Qt-style widget toolkit (CURRENT PRIMARY
   TRACK)** — retained-mode widget library over the
   `/dev/wsys/<wid>/draw/<layer>/{markup,fb}` protocol. v1 LANDED
   (`3a45c4de`, 980 lines): box/fixed containers + label/button/entry/
   checkbox/list, measure+arrange layout, pull-based event model,
   /dev/mouse + stdin input polling. See [[memory/project_gui_toolkit_de_rewrite]].
   **User directive 2026-06-10: make this "epic" — MATE-class — BEFORE
   the DE rewrite.** Required before #3 is unlocked:
   - [ ] **Widget set**: menu/menubar, scrolledwindow + scrolling,
     dialog/modal, notebook/tabs, radio (grouped), slider/scale,
     spinbutton, combobox, progressbar, separator, image, toolbar,
     statusbar, treeview/grid, multi-line editable textview.
   - [ ] **Layout**: grid container; per-widget align/expand/fill
     (hexpand/vexpand/halign/valign) so panels and dialogs lay out like
     GTK; min/natural size negotiation.
   - [ ] **Dynamic editing**: insert/delete at caret, cursor movement,
     selection — not just append-only (terminal + text editor need it).
   - [ ] **Widget destruction** + damage/dirty tracking (repaint only
     changed regions, not the whole buffer every frame).
   - [ ] **Real per-window input** — depends on #2b below (compositor
     event file). Until it lands, keep the /dev/mouse + stdin shim; the
     swap is a one-function change (`_h_poll_pointer`/`_h_poll_keys`).
2b. [x] **Compositor per-window input event file** (#424, LANDED) — a
   per-window pointer-event file (absolute window-space x/y + button
   bitmap) and a key-event file for the focused window.
2c. [x] **KEYSTONE — live compositor renders external client "ui" markup**
   (#425, VERIFIED + pushed `29f17dc1`) — the live hamUId compositor
   rasterises an arbitrary hamui client's "ui" markup layer into the live
   frame, proven on a REAL EFI GOP framebuffer (OVMF) by
   `scripts/test_hamUI_markupclient_gop.sh` (six markup markers + PASS,
   composited pixels sampled via daemon_pixel). This was the gate on item 3
   below; the MATE-mirror DE rewrite is now UNGATED.
3. [~] **Rewrite the entire DE as a MATE MIRROR on `lib/hamui.ad`** — the
   current `user/hamUId.ad` (24.4k lines) is one monolith owning fb +
   input + WM + per-app rendering + compositing. User directive
   2026-06-10 (after VM test): "I want a mirror mate. Might be good to
   literally translate the mate code into adder, building out any missing
   pieces as we go." Mirror MATE's *component architecture & behaviour*
   (session → marco WM → mate-panel → apps-as-hamui-clients), translating
   logic module-by-module and filling toolkit gaps in `lib/hamui.ad` as we
   hit them — NOT a literal 1:1 GTK port. Decision: do NOT patch the
   monolith's perf/input; both bugs are architectural and the rewrite
   fixes them at the root. Two VM-confirmed root causes the rewrite MUST
   design out:
   - **Input leaks to the serial/boot shell + no real focus.** Daemon
     reads keys from `/dev/cons` — the SAME source the boot hamsh reads;
     console-takeover only reliably suspends fb-text *output*, so when the
     UART-input grab doesn't hold, keystrokes reach both. And focus is
     hardwired to the topmost window (`daemon_focus_slot`→`DWIN_COUNT-1`),
     no click-to-focus. FIX: a real focus model + input routed only to the
     focused client; the DE must own input exclusively (no `/dev/cons`
     sharing with a backing shell).
   - **Multi-second terminal-open lag.** Spawning a window forces a
     FULL-SCREEN present, and `daemon_pixel()` is a procedural per-pixel
     scene-graph query over every screen pixel (O(W×H), iterating all
     windows per pixel) — millions of calls per open on emulated CPU. FIX:
     blit-based, damage-clipped compositor that composes from cached
     per-window backbuffers (memcpy/blit), never per-pixel scene queries
     for the whole screen; window-open damages only its own rect.

   **Increment 1 LANDED + VM-VERIFIED (`cb9563ea`, pushed).** The
   component-split spine is proven on a REAL EFI GOP framebuffer by
   `scripts/test_hamUI_appspine_gop.sh` (nine OK markers + PASS). The
   first desktop app (`user/hamecho.ad`) runs as its OWN process,
   spawned by the compositor with a kernel-allocated wid, its hamui "ui"
   markup composited live. BOTH root causes designed out and asserted:
   (a) a focus-gated keystroke crosses into the separate process AND does
   NOT leak to the `/dev/cons` boot/serial shell — input ownership is now
   a real exclusive `/dev/fbctl` `grab`/`ungrab` claim, decoupled from
   the fb-text `suspend` hack and released on DE exit; (b) opening the app
   damages only its own window rect (`DMG_LAST_FULL==0`, no full-screen
   recomposite). Kernel surface added: `/dev/wsys/self` (client
   self-discovers its post-spawn wid) + non-blocking
   `/dev/wsys/<wid>/{keys,pointer}` reads. Also fixed a latent toolkit
   bug: `lib/hamui.ad::_h_ctl` wrote to the bare read-only `.../draw`
   listing (NULL-layer path collapse silently dropped every `mklayer`),
   so no external hamui client could create its own "ui" layer until now.
   NEXT increments: extract a real terminal as a separate-process client;
   port the session→WM→panel split so apps are launched/focus-managed
   like mate-panel/marco rather than hand-drawn in the monolith.

   **Increment 2 LANDED + VM-VERIFIED (`9dc4716c`, pushed).** A real
   terminal (`user/hamterm.ad`) now runs as its OWN compositor-spawned
   process: it self-discovers its wid via `/dev/wsys/self`, binds with
   `hamui_window_on`, seeds keyboard focus on its command entry, and runs
   real `/bin/hamsh` commands whose output renders live in the window —
   proven on a REAL EFI GOP framebuffer by
   `scripts/test_hamUI_termspine_gop.sh` (PASS). Both root causes hold for
   the terminal too: opening it damages only its own rect (no full-screen
   recomposite), and a focus-gated command crosses into the separate
   process WITHOUT leaking keystrokes to the `/dev/cons` shell. A first
   attempt failed its GOP gate because the self-test's markup-detect step
   spun up to 400 full-screen composites (blowing the 240s budget); the
   markup path itself was fine — fixed by waiting on a cheap
   `markup_client_probe()` (one `open()` of the layer) then presenting
   once. hamterm is still ONE-SHOT run-capture, not a persistent PTY
   (the honest remaining gap). NEXT: unify the other "Terminal" launchers
   (Applications-menu, panel) onto `daemon_spawn_terminal`; persistent
   PTY/job-control/ANSI; then the session→WM→panel component split.

   **Increment 3 LANDED (2026-06-10, pushed `a05d0eeb`).** (a) Menu/desktop
   "Terminal" launchers now route to the separate-process `daemon_spawn_terminal`
   (autoflag-49 GOP gate `scripts/test_hamUI_menuterm_gop.sh`). (b) DEPERF #410
   cached-layer blit compositor (`6d769feb`): the per-pixel procedural scene walk
   is cached in SCENE_CACHE, presents are pure memory blits, cursor moves blit a
   12×12 cell — the fix for the 35s terminal-open + frozen mouse. (c) `hamterm`
   is now a PERSISTENT interactive hamsh over pipes (cwd/env persist). (d) New
   separate-process apps: `hammon` (system monitor) + `hamview` (PPM/BMP image
   viewer). (e) Markup-rasterise fix: a freshly-spawned client's body is now read
   on the present that first detects its "ui" layer (was waiting up to 8 frames /
   never, for direct-present self-tests — the autoflag-49 FAIL).

   **MATE GAP ANALYSIS (2026-06-10).** DE is far more complete than a naive read
   suggests (marco-class WM, mate-panel menubar/pager/window-list, clipman,
   control-center, notification history all exist). Real gaps, prioritized:
   most-disjoint NEW apps / toolkit-only → screenshot tool (DONE: hamshot +
   /dev/fbpix pixel read-back leaf, ec34fc41, VM-verified end-to-end), image
   viewer (DONE: hamview), file-chooser + modal-alert dialog widgets (DONE:
   30764cdd), tooltip support (DONE: 8661dabc), calendar popup/widget (DONE:
   19db22e0; embedded in hamclock), hamsh `hamui` builtin verbs for dialogs/
   tooltips/calendar (DONE: 99e7e058) — widgets compile-verified, not yet
   VM-verified. Compositor perf prereqs LANDED + VM-verified: /dev/wsys gen
   leaf + SYS_WAITFDS(313) (28741f0b) — hamUId gen+waitfds consumption (kill
   busy-poll main loop + every-8-frames re-rasterize) IN FLIGHT (agent).

   **MOUSE FIXED IN VM (2026-06-10, merged 5e492591, VM-verified on main).**
   "Mouse doesn't move at all even in the VM" root-caused through THREE
   stacked bugs: (1) usb-tablet (QEMU's default absolute pointer) was never
   enumerated — added tablet attach + absolute-coord side channel through
   /dev/mouse to hamUId (f5d17401); (2) xHCI Transfer Event param is the
   completed TRB's address, not the data buffer — live events were misrouted
   (2ea70db3); (3) the boot-time synthetic xHCI selftests forged events at
   the event-ring consumer cursor, desyncing consumer vs producer AND leaving
   ERDP ahead so QEMU's ring-full heuristic silently dropped every later real
   event — fixed by cursor+ERDP rewind + forged-TRB scrub (01bd6034,
   9a6d598d). Gate `scripts/test_hamUI_mouse_gop.sh` (OVMF/GOP + QMP
   injection): BOTH PS/2 relative and usb-tablet absolute paths move the
   compositor cursor end-to-end. The desync class-bug would also have killed
   live USB keyboard input on selftest boots.
   hamUId.ad-touching → real volume/battery/network applets (model
   values today; needs real backends), Display/Mouse/keyboard-layout settings
   panels, external notification + system-tray client-registration API, image
   wallpaper, screensaver+password-lock, real session save/restore, inter-app
   drag-and-drop. PDF viewer (atril) deferred (needs font/PDF stack). Serialize
   the hamUId.ad-touching items (single 25k-line file) to avoid merge collisions.
4. [ ] **Basic apps on the toolkit** (after #2 API is stable) — terminal,
   text editor, file browser, plus games Snake + 2048. These validate the
   toolkit is genuinely app-grade, and seed the DE app suite.
5. [ ] **hamsh `use hamui`** — bindings on top of #2. May require
   hamsh extensions for closures + event loop + persistent state.

> **ARM64 is deprioritized below desktop work (user directive 2026-06-10).**
> Phase 50 (MAP_SHARED across address spaces) preserved on branch
> `worktree-agent-a48facf53ef25a377` (`6f217d09`), NOT landed. Resume ARM
> only when the desktop/toolkit track is in good shape.

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

### §7 Entropy / RNG
- [~] ChaCha20 CSPRNG: RDRAND/RDSEED seeding + fast-key-erasure DONE;
  periodic **reseed cadence** now folds fresh hw entropy on a byte
  (1 MiB) or jiffies budget for post-compromise secrecy
  (sys/src/9/port/devrandom.ad `_maybe_reseed`). `/dev/random` ≡
  `/dev/urandom` aliasing is intentional modern-Linux semantics (both
  non-blocking once seeded), so no split needed.

### §8 SMP & scheduler
- [~] **MADT-driven SMP landed** (2026-05-30): `arch/x86/kernel/smp.ad`
  discovers all APIC IDs from the ACPI MADT, boots each AP via INIT-SIPI-
  SIPI, sets up per-CPU `%gs` / `current_task`; `kernel/sched/core.ad`
  has a spinlock-protected shared runqueue and `sched_ap_idle_loop` so APs
  pick up `STATE_READY` tasks. Per-CPU runqueue + user-task load balancing
  landed (#139, #151). **Open**: work stealing, CPU affinity.

### §10 Networking
- [ ] Generic unicast ARP helper; ICMP time-exceeded / redirect.

### §12 Filesystem write maturity
- [~] ext4 directory-op maturity (rmdir + dir-rename `..` fixup) — in
  flight (#245).
- [ ] ext4 truncate on index-node files; growing a full ext4 directory
  block.

### §13 cdev / proc completions
- [~] `/proc/net/*` — in flight (tcp/udp/arp/route/dev from live net
  state).
- [ ] Per-backend errstr (ext4 / fat / blk) + user-mode `perror` helper.

### §14 Resource control & security (stretch)
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
- [ ] Drop the FAT12 32 MiB ESP cap via the GPT-ESP path.
- [ ] NUC network silent on real I219 — needs hardware time.

## Storage driver maturity

- [ ] AHCI NCQ (serialises on slot 0 today); hot-plug / COMRESET retry;
  multi-port naming (`sd1`...).
- [ ] NVMe multi-queue + multi-namespace.
- [ ] Partition: extended-CHS chains, BSD disklabel, APM; GPT UTF-16
  names into the block tag; `mount /dev/sd0p1 /mnt` path-to-slot
  resolver.
- [ ] ext4 mkfs multi-block-group layout; journal (jbd2) at mkfs time.

## Input

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
