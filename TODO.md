# Hamnix TODO

What's still open. **For what's shipped, read [`STATUS.md`](STATUS.md)** —
it's append-only, dated, and the source of truth. Completed items live
there, not here; this file stays lean.

Pointers:
- Design: [`docs/architecture.md`](docs/architecture.md),
  [`docs/native-api.md`](docs/native-api.md) (Layer 1 Plan 9 syscalls),
  [`docs/hamUI.md`](docs/hamUI.md), [`docs/security.md`](docs/security.md).
- Snapshot: [`README.md`](README.md). Onboarding: [`CONTRIBUTING.md`](CONTRIBUTING.md).
- Latest audits (2026-06-13): [gap vs Linux](docs/audit_gap_vs_linux_2026-06-13.md),
  [arch shortcuts](docs/audit_arch_shortcuts_2026-06-13.md).

Markers: `[ ]` open · `[~]` in flight.

---

## ⚠ Direction (2026-06-20)

**Goal sharpened:** Hamnix is a **good desktop _and_ server OS in the
shape of Plan 9** — not a general "Linux competitor." That target makes
several architectural calls for us (below). Plan 9 spine is real and
held; the next push is foundational hardening, not new surface area.

Six strategic tracks, **ordered by dependency** (the compiler chain
unlocks itself — do the Linux target first):

1. **Adder Linux target (Tier 2)** — the unlock: smallest and most
   grounded task, and a precursor for tracks 2 & 3. Compile freestanding
   Adder (compute + file I/O, NO GUI / no Plan 9 base) to native Linux
   ELF. Enables host-speed dev + fuzzing.
2. **Compiler fuzzer** — depends on track 1. The solo hand-rolled
   single-pass x86 backend is the #1 structural risk; the fuzzer
   measures and de-risks it.
3. **Self-hosting on Linux + Hamnix** — depends on track 1, validated by
   track 2. Finish the `.ad` compiler and run it on the host, closing
   the bootstrap for real.
4. **Userland-isolated drivers** — highest *leverage* (toy → server) but
   independent of the compiler chain and the biggest lift. Move stock
   `.ko` execution out of the kernel fault domain.
5. **Kernel scaling rework** — independent. Kill the static-array
   ceilings before they calcify; defer deep perf (NUMA/RCU) until a real
   multicore workload can measure it.
6. **Adder code optimizer** — independent. Get compiled Adder into rough
   C territory. Baseline (`docs/bench_adder_host.md`): already ~1.6× of
   `gcc -O0`, ~4.3× of `-O2`, ~24× faster than CPython. Classic passes
   (not LLVM-scale) should reach ≤ ~2× of `-O2`.

Plus: **gate the two real boot paths in CI** (cheap, independent, high
value — see the CI section).

### Decision points (record, don't lose)

- **LLVM as an optional _second_ backend — DEFERRED.** Gated on fuzzer
  bug-density data (track 2). If adopted: keep the Adder frontend + keep
  the hand-rolled x86 backend as the pure bootstrap; add an LLVM IR
  emitter as a parallel backend. Payoff: optimization, ~free multi-arch
  (ARM64), CPU mitigations (CFI/retpoline/CET), AND a differential-test
  oracle (same program through both backends). Cost: giant C++
  dependency, ethos hit. **Do not** attempt to rewrite/translate LLVM
  into Adder — ~30M LOC, project-ending. Revisit once the fuzzer reports
  real miscompile density on the hand backend.
- **Optimizer vs LLVM for _performance_.** Track 6 (a homegrown
  optimizer) is the keep-it-native path to "rough C ballpark" — the bench
  data says classic passes get most of the way. LLVM still wins for
  ARM64 + CPU mitigations + best-case perf. They are not mutually
  exclusive: both need an IR (Track 6's prerequisite), so Track 6's IR is
  reusable if LLVM is later adopted. Build Track 6 first; let it decide
  whether LLVM's extra perf is even needed.

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

## Track 1 — Adder Linux target (Tier 2: compute + file I/O)

**Why:** run freestanding Adder on Linux at native speed (dev + fuzzing
+ host self-hosting). NOT for GUI/namespace apps — those need Plan 9
emulation on Linux (plan9port-scale), explicitly out of scope. This is
the unlock for tracks 2 and 3.

**Grounding:** `aarch64-linux` already exists and already emits Linux
syscall numbers — mirror it for x86. Userland is freestanding (raw
`syscall`, no glibc).

- [ ] **Register `x86_64-linux` target** beside `aarch64-linux` in
  `adder/compiler/adder.py:34` (`{codegen: x86, kbuild: False,
  bare_metal: False}`). Revisit the `bare_metal` flag — it only gates
  `.modinfo`, wrong proxy for "userspace"; consider a `userspace` flag.
- [ ] **`user/linux-runtime.S`** — Linux x86_64 syscall numbers
  (write=1, read=0, open=2, close=3, lseek=8, exit=60, …) + Linux
  `_start` (argc/argv off the stack). Mirror `user/runtime.S`.
- [ ] **`user/linux-init.lds`** — `elf64-x86-64`, `ENTRY(_start)`, drop
  the `elf32-i386`/`.code64` wrapper trick.
- [ ] **Link path** in `adder.py` (mirror `:527-571` aarch64-linux) —
  `as --64`, `ld -m elf_x86_64 -nostdlib -static`.
- [ ] **Centralize syscall numbers** (high-value cleanup) — today
  scattered as `movq $N,%rax` across `user/runtime.S`; a per-target table
  lets x86-adder-user / x86_64-linux / aarch64-* coexist without copy-paste.
- [ ] **Smoke test** — compile a file-I/O Adder program to `x86_64-linux`,
  run on host, verify read/write/exit reach the Linux kernel.

## Track 2 — Compiler fuzzer

**Why:** de-risk the solo single-pass hand backend. The May 2026 sweep
fixed 5 silent miscompiles (signed/unsigned compare, sub-8-byte pointer
writes, 2-D array addresses) — the surface is real.

- [ ] **Host-test compile target** (depends on Track 1's `x86_64-linux`).
  Reuse computational codegen; only the output/exit primitive maps to
  Linux. Generated programs run natively — millions/hr, no QEMU.
- [ ] **Program generator + predicted-output oracle.** Generator emits a
  random valid Adder program AND computes its expected result by
  construction; compiled program prints actual; compare. Catches the
  whole May bug class with no second implementation.
- [ ] **Crash/assert mode** — fuzz for compiler exceptions /
  `CodeGenError` on valid input.
- [ ] **Batched in-VM pass** for the ABI/namespace surface the host
  target can't cover (syscall numbering, `_start`, 9P semantics): boot
  Hamnix once, feed thousands of programs over a channel — don't reboot
  per program.
- [ ] **Report bug density** — this number gates the LLVM decision.
- [ ] (Later, if LLVM lands) **differential oracle** — same generated
  programs through both backends, compare.

## Track 3 — Self-hosting on Linux + Hamnix

**Why:** close the bootstrap. The build is currently Python-locked
(`python3 -m compiler.adder`); the `.ad` compiler is incomplete.

- [ ] **Finish `compiler/codegen.ad` to parity** with `codegen_x86.py`
  (~3700 LOC gap: strings/string ops, remaining feature coverage). Use
  the fuzzer (Track 2) to validate against the Python compiler.
- [ ] **Build the `.ad` compiler as an `x86_64-linux` binary** (via
  Track 1) so `adder_cc` runs on the host, compiling Adder→Hamnix at
  native speed — Python becomes a one-time seed.
- [ ] **Run the `.ad` compiler in Hamnix too** (`x86_64-adder-user`) for
  on-device source packages (#186).
- [ ] **Correct the false claim** — STATUS.md says on-device self-hosting
  is "Done"; it is not (no build path uses the `.ad` compiler). Fix the
  wording until the above lands.

## Track 4 — Userland-isolated drivers (.ko out of kernel)

**Why:** stock `.ko` modules load into kernel memory today
(`linux_abi/loader.ad`) and share the kernel fault domain — a buggy
vendor driver panics the box. A Plan 9 _and_ server-correct OS runs
drivers as restartable userland file servers.

**Scope:** ONE build. `.ko` support stays in every image (server and
desktop alike) and loads on demand based on the hardware present — no
`.ko`-free profile, no separate server build. The goal is to change
*where `.ko` executes* (a restartable userland host, not kernel space),
not whether it's available. Native drivers stay first choice where the
hardware is standardized; `.ko` remains the escape hatch for vendor-mess
HW (consumer wifi, GPUs) — now crash-isolated.

- [~] **User-mode driver framework (UMDF-style).** First vertical slice
  landed: `linux_abi/umdf_kernel.ad` exposes the three privileged
  primitives over a narrow syscall channel — MMIO map (`SYS_UMDF_MMIO_MAP`
  321, uncacheable phys→user VA), DMA alloc (`SYS_UMDF_DMA_ALLOC` 322,
  phys-contiguous + phys exposed), IRQ file (`SYS_UMDF_IRQ_OPEN` 323 +
  blocking read on the returned irq fd, per-vector WaitQueue). The driver
  posts a `#X` server (existing namespace law). Remaining: respawn
  supervisor (auto-restart on crash), real BAR-backed driver.
- [~] **Port the `.ko` loader into a userland host process.** Landed:
  `user/umdf_host.ad` runs the ET_REL load + reloc + symbol resolution +
  `init_module` dispatch in a CPL3 process; the `.ko` lands in mmap'd
  USER memory and `_printk`/MMIO/IRQ/DMA shims bottom out into the host's
  userland shim / the new syscalls. Remaining: broaden the userland shim
  table toward `linux_abi/exports.ad` parity for richer `.ko`s, and `%gs`
  per-CPU handling in userland.
- [x] **Restart/crash-isolation test** — `scripts/test_umdf_host.sh`:
  crashes a userland driver host (NULL deref), proves the kernel + hamsh
  survive, and a fresh host re-inits the `.ko` afterward. Per-task UMDF
  cleanup hook (`register_umdf_task_exit_hook`) reclaims IRQ files + DMA
  buffers on both clean exit and crash.

## Track 5 — Kernel scaling rework

**Why:** static-array ceilings calcify the longer they bake. Lift the
*structural* limits now; defer perf tuning until a workload measures it.

**Fix now (structural — gets harder over time):**
- [ ] **Dynamic CPUs** — `MAX_CPUS=16` static arrays → dynamic per-CPU
  allocation indexed by `smp_processor_id()`. Cite: `arch/x86/kernel/smp.ad`.
- [ ] **Dynamic / list-based tasks** — `NTASKS=256` is now a *static
  array of 256*; the scheduler scans all slots O(NTASKS) to pick next
  (`kernel/sched/core.ad`). Convert to intrusive per-CPU run-lists so
  pick-next is O(active), and drop the hard task ceiling.

**Defer until a contended multicore workload exists (well-trodden, not research):**
- [ ] **Per-waitqueue locks** — replace the global `wq_lock` serializing
  every WAIT↔READY transition.
- [~] **SMP work-stealing + CPU affinity** — per-CPU runqueue + load
  balancing landed (#139/#151/#397); work-stealing and affinity open.
- [ ] **Softirq / threaded IRQs** — IRQ handlers run in hard context
  today (`arch/x86/kernel/irq.ad`); add bottom-half deferral.
- [ ] **Per-CPU slab cache** — single global free list contends under
  fork storms (`mm/slab.ad`).
- [ ] **Buddy merge-on-free** — no coalescing today; fragments over long
  uptime (`mm/page_alloc.ad`).

**Deep / punt until measured:** NUMA-node awareness + per-node pools;
RCU read-side for task/VFS traversal; LRU-ordered reclaim.

## Track 6 — Adder code optimizer (→ rough C territory)

**Why:** compiled Adder is sound but unoptimized. Baseline
(`docs/bench_adder_host.md`, `scripts/bench_adder_host.sh`): geomean
~1.6× of `gcc -O0`, ~4.3× of `-O2`, ~24× faster than CPython. The `-O2`
gap is concentrated in a few classic passes, not anything LLVM-scale.

**Goal:** rough C ballpark — **target ≤ ~2× of `-O2`** (from ~4.3×).
Non-goal: `-O2` parity / auto-vectorization. **Progress: 4.28× (`-O0`) →
3.47× (`-O1`) → 3.03× (`-O2`)** geomean of `-O2`, all fuzz-clean. lcg is
down to 1.51×; the remaining prize is `collatz`/`mmul` (5×, division- and
array-address-bound) which want LICM/CSE on a real IR.

- [x] **Increment 1 — `-O1` peephole optimizer (LANDED 2026-06-20).**
  `adder/compiler/peephole_x86.py`, gated behind `adder compile -O1` (default
  `-O0` single-pass path, used by the Hamnix image build, is unchanged).
  Four local provably-safe transforms over the emitted asm: condition→branch
  fusion, dead store-reload elim, immediate-push folding, push/pop→scratch
  forwarding (unwinds the stack-machine memory traffic via the unused
  `%r8`–`%r11`). **Result: geomean 4.24× → 3.45× of `-O2`** (1.23× speedup;
  fib 1.43×, mmul 1.38×, sieve 1.35×). 0 fuzzer miscompiles at `-O1`
  (`FUZZ_OPT=1 scripts/fuzz_adder.sh`). The IR-based steps below are the next
  increment (the peephole can't express LICM/strength-reduction/regalloc).
- [x] **Increment 2 — `-O2` stack-slot register promotion (LANDED 2026-06-21).**
  `adder/compiler/regalloc_x86.py`, gated behind `adder compile -O2` (runs
  after the `-O1` peephole; default `-O0` image-build path unchanged).
  A register allocator *over the stack slots*: the stack-machine backend keeps
  every local in an `OFF(%rbp)` slot and round-trips it through memory on every
  access; this pass promotes each function's hottest address-never-taken
  full-width scalar locals into the five callee-saved registers `%rbx,%r12–%r15`
  (never emitted by the backend, never scratched by `-O1`). Promotion is
  proven-safe per slot: only when *every* `OFF(%rbp)` appearance is a plain
  8-byte `movq` load/store (any sized/`movz*`/`movs*`/`lea`/indexed/canary use
  disqualifies it). Saves/restores via a fresh enlarged-frame slot at the
  prologue + before every `leave`. **Result: geomean 3.47× → 3.03× of `-O2`**
  (1.14× over `-O1`, 1.41× over `-O0`; sieve 2.69→2.13×, lcg 1.89→1.51×,
  collatz 5.92→5.26×, mmul 5.52→5.09×). **0 fuzzer miscompiles at `-O2`**
  (`FUZZ_OPT=2 scripts/fuzz_adder.sh`; 2000-program CI batch + 8000 soak).
  Implemented at the asm level (operates on emitted text per-function) rather
  than as a from-AST SSA IR — the same proven-safe, incremental shape as the
  `-O1` peephole, and it captures the single biggest win (memory round-trips)
  the IR was wanted for. The from-AST IR + the remaining IR-level passes below
  are still the next increment.
- [ ] **Step 0 — introduce a minimal IR.** Today's backend is single-pass,
  no IR (`adder/compiler/codegen_x86.py`); the `-O1`/`-O2` passes work on
  emitted asm text. A basic-block + virtual-register IR between AST and x86
  emission would enable LICM/CSE (below) which the asm-level passes can't
  express across control flow. (Reusable if LLVM is ever adopted — see
  Decision points.)
- [ ] **Loop-invariant code motion + strength reduction.** Hoist
  invariant base addresses; strength-reduce index math like `i*DIM+k`.
  Directly attacks the largest `-O2` gaps (mmul 7.8×, collatz 6.8×).
- [ ] **CSE + simple inlining** of small leaf functions (`putc`, leaf
  recursion).
- [ ] **Validate:** every pass must preserve results — gate on the fuzzer
  (Track 2) + `scripts/bench_adder_host.sh` correctness check; track the
  Adder/`-O2` ratio falling in `docs/bench_adder_host.md`.

## CI / verification gap

- [ ] **Gate the two real boot paths in CI.** Today `ci.yml` gates 14
  tests, all `-kernel` multiboot (only `test_efi_gop` touches OVMF, and
  only checks pixels). Add as gates: `test_installer_boot_heartbeat.sh`
  (USB/installer image, real OVMF) and `test_installer_nvme_inram.sh`
  (installed-disk, real OVMF). Verify both finish reliably under TCG
  first; the lane the original `ci.yml` header promised never landed.

---

## Kernel hardening & correctness

- [ ] **CPU-mitigations.** SMEP landed; **SMAP CR4-flip + KASLR + KPTI**
  open. SMAP flip is gated OFF because high-half kernel pages are US=1 —
  flipping triple-faults until they're re-stamped US=0. Cite:
  `arch/x86/kernel/trap_diag.ad:382`.
- [ ] **Suspend/resume.** S3 path real; HW wake-vector trampoline in
  `entry.S` pending. S0ix later.
- [ ] **F2 thin-shim conversion.** `SYS_NICE`/`SVC_CTL`/`NETCFG`/
  `RESOLVE`/`WSYS_*` syscall arm BODIES still duplicate the ctl-file
  implementation in `arch/x86/kernel/syscall.ad`; replace with thin
  delegations.
- [~] **#439 post-exit wedge.** Boot-CR3 guard landed
  (`mm/page_alloc.ad:40-65`); a probabilistic reclaim-path
  double-free/cycle in `_try_remove_buddy` may remain — needs runtime
  verification. WIP snapshots on `worktree-agent-ae2373654138b1014`
  (`9944f32b`), `worktree-agent-a9c57d837298c09e7` (`a22bd04f`).
- [~] `stat`/`fstat` per-backend hooks — `do_stat` migrated to hook
  table (`47ab21c5`); `do_fstat` per-server migration deferred.
- [~] Delete the global `/var` tmpfs — per-Pgrp bind `/var → #t/var` in
  place; backend `vfs_mount` router entry removal needs FS-routing
  migration.
- [~] Plan 9 `note_group` + cross-task `/proc/<pid>/note` landed
  (`660978bb`); runtime verification pending.

## P9-shape hammer — long tail

- [~] **F7 #390** — FD-mark fold continuation. Pipes next (highest
  leverage).
- [ ] **F10-4 … F10-12** — remaining F10-audit findings (afd Tauth,
  `init/main.ad` split, full Dir-record atime/mtime + per-task uid, etc.).

## hamUI / DE track

- [~] **`lib/hamui.ad` MATE-class widget set** — menu/menubar,
  scrolledwindow, dialog/modal, notebook/tabs, radio, slider, spinbutton,
  combobox, progressbar, separator, image, toolbar, statusbar,
  treeview/grid, multi-line textview; grid layout + per-widget
  align/expand/fill, dynamic editing, destruction, damage tracking.
  v1 + Inc 1/2/3 landed.
- [~] **Rio-faithful reshape** — `#w` per-process bind landed; image+
  dirty-rect wire format being implemented across devwsys+hamUId+hamui.
- [ ] **DE pivot finish — substitution not addition.** Physically remove
  the dead `daemon_pixel` render fallbacks (~20K dead LOC in
  `user/hamUId.ad`); replace with a thin router. Target: `user/hamUId.ad`
  below ~10 KLOC.
- [ ] **hamsh `use hamui`** — bindings; may need hamsh closures + event
  loop + persistent state.
- [ ] X11/Xvfb bridge in a `kind=fb` layer (path to Firefox/Chromium).
- [~] BDF font store landed; runtime font-file loading deferred.
- Known bugs: cursor hotspot (clicks at arrow bottom, not tip); terminal
  ~0.5s input lag.

## GPU / graphics (#181–185, native-first)

Target: glxgears + vkcube spinning in a hamUI window, accelerated where
present. **Laws:** (1) DE never requires the Linux *namespace* — baseline
is native Vulkan + native software rasterizer (NOT lavapipe). (2) `.ko`
modules via the L-shim ARE used (`i915.ko`); `.ko` ≠ namespace.

- [~] **#181 Phase 0** — native Vulkan spine + software rasterizer + WSI.
- [~] **#182 Phase 1** — native virtio-gpu + native venus in a VM.
- [~] **#183 Phase 2** — DE composites via native spine; Linux X11 apps
  bridge in via venus-shaped ICD + Zink (optional).
- [ ] **#184 Phase 3 (METAL)** — Intel i915 silicon via `i915.ko`.
- [ ] **#185 Phase 4 (optional)** — native ANV-equivalent.

## Driver / storage / input maturity

- [ ] AHCI NCQ (serialises on slot 0); hot-plug / COMRESET retry;
  multi-port naming (`sd1`…).
- [ ] NVMe multi-queue + multi-namespace.
- [ ] Partition: extended-CHS, BSD disklabel, APM; GPT UTF-16 names;
  `mount /dev/sd0p1 /mnt` path-to-slot resolver.
- [ ] ext4 mkfs multi-block-group layout + journal at mkfs time; ext4
  truncate on index-node files; growing a full dir block (prior attempt
  `bc1cb9c8` reverted `bb7ba653` — broke heartbeat boot).
- [~] Networking forwarding-path auto-wiring (gated behind
  `ip_forwarding_enabled`, default 0).
- [ ] Input: dead-key / compose / IME; blocking read on `/dev/mouse`;
  MADT IRQ-override consumption.
- [ ] stock-Linux `.ko` coverage: `MAX_EXPORTS` bumps; `usbcore`+
  `xhci_hcd`, `libphy`, `8021q`, `nf_conntrack` core. (Reconcile with
  Track 4 — `.ko` work should target the userland host, not the kernel.)

## Userspace polish

- [ ] `enter linux { /bin/sh }` interactive stdin doesn't reach the Linux
  process (sshd sessions have their own pty).
- [ ] Nested `` `{ } `` command substitution clobbers (hamsh).
- [ ] busybox `ls` enumeration XFAIL (musl DIR-fd round-trip); busybox
  `sh -c "a|b"` internal-pipeline `#GP`.
- [ ] `/bin` tool audit for cwd-relative defaults.
- [ ] CPython: trim frozen stdlib; PGO/LTO; C extensions once a U-track
  `ld.so` exists.
- [ ] TEMP_DEBUG cleanup pass when bring-up stabilises.

## Metal bring-up (human-in-the-loop)

- [ ] **xHCI v1 metal** — HCH-clear MMIO poll wedges on real Intel NUC;
  USB mouse dead on metal.
- [ ] Asus i5-4210U boot crash; built-in keyboard never responded under
  Legacy/BIOS (hypothesis EHCI-routed).
- [ ] MMIO-stall class audit: ehci, ahci, nvme.
- [ ] Real NIC silicon: e1000e EEPROM on Intel; r8169 RX on RTL8168;
  Broadcom tg3; Intel igb; NUC I219 silent.
- [ ] Drop the FAT12 32 MiB ESP cap via GPT-ESP path.
- [ ] **#117/#118** — verify >4GB fix kills real-HW #UD + persisted logs
  (USB boot at `-m 8G`).

## Bigger lifts — no immediate plan

- [ ] iwlwifi / ath11k / mt76 — real radios. Firmware via the planned
  `non-free-firmware` channel.
- [ ] Browser in a hamUI window — gated on hamUI Phase 5 (X11 bridge).
- [~] Multi-arch ARM64 (#175) — aarch64 backend landed; full bare-metal
  kernel port (Phase 3+) open. **Note:** an LLVM second backend (see
  Decision points) would subsume much of this.
- [ ] **Arch convergence** — factor an arch-interface; link a shared
  portable core into ARM64. Do once ARM64 bring-up is stable.
- [ ] Signed package indexes (sha256 covers tarballs; index unsigned).
