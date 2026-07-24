# DE-under-LLVM visual gate (`scripts/test_de_visual_gate_llvm.sh`)

Repeatable, regression-protected proof that the **whole-kernel LLVM-compiled**
Hamnix kernel boots to the graphical hamUI desktop. This is the LLVM-lane
sibling of the native-kernel `scripts/test_de_visual_gate.sh` and locks in the
project's top-priority result (native Adder kernel, LLVM-compiled for speed,
still driving the full scene-file DE).

## What it does

1. Builds the full LLVM DE stack, each step skipped when its artifact exists:
   - `build/cutover/host_ac.elf` — the Adder compiler with the LLVM backend
     (`adder_cc_bootstrap`).
   - `build/user/*.elf` — the compiled Adder userland (`/init` + `/bin/*`) via
     `scripts/build_user.sh`. **Load-bearing:** without these the cpio has no
     `/init`, so the kernel falls back to a baked user-demo stub at a kernel
     address that NX-faults — it never reaches userspace. (This is the single
     easiest way to get a misleading "LLVM kernel is broken" result: the kernel
     is fine, the initramfs just had no `/init`.)
   - `build/initramfs_blob.S` — the cpio blob, built with `HAMNIX_DE_SELFTEST=1`
     so the DE demo apps (Files/Editor) auto-launch and the `[visual_gate]`
     launch-queue trio (Calendar/Calculator/System-Monitor) runs — the same
     path `test_de_visual_gate.sh` uses to guarantee several mapped windows.
   - `build/kllvm/hamnix_kernel_llvm.elf` — the linked higher-half LLVM kernel
     (`scripts/build_kernel_llvm.sh`).
2. Wraps the ELF in a BIOS-GRUB multiboot ISO (QEMU's `-kernel` loader rejects
   the ELFCLASS64 higher-half kernel; GRUB's multiboot loader accepts it — the
   same trick as `scripts/_kernel_iso.sh`).
3. Boots it under KVM (`-cpu host`, `-m 1024M`, `-vga std`, headless) with a
   FIFO-backed serial (input + capture) and a QEMU monitor socket.
4. Asserts, for a PASS (exit 0):
   - **(a)** `[scene_de] kernel scene compositor owns /dev/fb` — the rl5 fb flip.
   - **(b)** `[panel] appmenu entries:` — the panel came up with a populated menu.
   - **(c)** `>= WINDOW_MAP_MIN` (default 4) distinct
     `[devwsys] window <wid> mapped pid=<pid>` markers — real scene-DE app
     windows allocated.
   - **(d)** a captured framebuffer screendump that is **not** a single flat
     color (a genuine render, not a blank backdrop).
5. **Interactivity** (reported; hard-gated only under `REQUIRE_INTERACT=1`):
   drives the DE's real app-launch path from the host over the serial console
   — `echo /bin/hamtermscene > /dev/wsys/run/launch`, the same queue the
   Applications menu / panel / a desktop double-click use — and looks for a NEW
   higher `wid` afterward. This is the ctl-file injection path the project
   prefers over the flaky `/dev/mouse` route.

## How to run

```sh
bash scripts/test_de_visual_gate_llvm.sh
```

Useful env: `LLVM_CLANG_OPT=-O2` (the -O2 lane also boots per
`docs/kernel_llvm_phase5b.md`), `ACCEL=tcg` (KVM-less / TCG-masked-bug repro),
`MEM=1536M`, `WINDOW_MAP_MIN=4`, `REQUIRE_INTERACT=1`, `HAMNIX_SKIP_BUILD=1`
(require a prebuilt ELF), `HAMNIX_KLLVM_REBUILD=1` (force a kernel rebuild).
Artifacts (serial log, ISO, PPM/PNG screendumps, `SUMMARY.txt`) land under
`build/de_visual_gate_llvm/<timestamp>/`.

## Not in the CI battery (on-demand)

Unlike the on-device browser gates (which reuse a prebuilt installer image via
`HAMNIX_SKIP_BUILD=1`), this gate needs a bespoke LLVM kernel that the standard
CI image build does **not** produce, and building it end-to-end (host_ac +
~250-program userland + LLVM kernel) plus a ~2-3 min KVM boot is well over the
per-shard budget of the KVM-less bare-metal battery. It is therefore an
**on-demand** gate — run it by hand after any `ssa*.ad` / `ssa_llvm.ad` /
`codegen.ad` / `build_kernel_llvm.sh` change. It SKIPs cleanly (exit 0) when
`/dev/kvm`, `grub-mkrescue`, `qemu`, or `socat`/`nc` is absent.

## Current empirical status (main @ 8e191678)

Boot reaches, reproducibly under KVM `-cpu host`:

- `[boot:init] blob=… size=17720` — `/init` found in the cpio (needs
  `build_user.sh` first, see above),
- `[hamsh] M16.35 shell ready` → `hamsh$ [hamsh:stage-08] ed-readline-first`
  — full userspace, matching `docs/kernel_llvm_phase5b.md` Phase 5s,
- `[scene_de] kernel scene compositor owns /dev/fb (rl5 flip)` — assertion (a)
  PASSES, and the compositor paints the desktop **backdrop**.

But the scene-DE **clients do not render**: `rc.5` rforks the desktop/panel/
file-manager/editor children (pids 18-26) yet **zero** `[devwsys] window …
mapped` markers appear, `[de_present] live_windows=0`, and the screendump is a
flat 1280x800 backdrop (3 colors, 99% one color). The children are created
READY but never dispatched — the "child READY but not dispatched" scheduler
gap noted in `docs/kernel_llvm_phase5b.md` (Phase 5d, line ~207). The kernel's
own devwsys `newwindow` path is fine (the boot self-test
`[MULTITASK_BAR] all three live windows listed in /dev/wsys/windows` maps 3
windows), so this is a scheduler/dispatch codegen gap for the detached scene
clients, not a devwsys bug.

So assertions (b), (c), (d) currently **FAIL** and the gate reports FAIL — the
honest state: the LLVM kernel boots to the DE backdrop + interactive shell, but
the full windowed desktop render is not yet working at this commit. The gate is
the regression lock: it goes green the moment the scene clients are dispatched
and map their windows (and stays red if a codegen change regresses the boot).
Fixing the dispatch gap is a kernel/compiler change out of scope for this
test-harness task (which touches `scripts/` + `docs/` only).

Cross-accelerator check (`ACCEL=tcg`): TCG gets marginally further — a scene
client is actually dispatched and `execve`s its user ELF (`execve: jumping to
0x400012`), where under KVM the clients never run at all — but the boot then
stalls with still **0** windows mapped. So the gap reproduces under both
accelerators; the observed `-cpu host`-vs-TCG difference (KVM starves the
clients earlier) is consistent with the project's "KVM `-cpu host` exposes
TCG-masked codegen bugs" note. Neither accelerator produced the "6-7 windows"
render at 8e191678 in this reproduction.

## 2026-07-23 re-investigation — the "0 windows" gate FAIL is NOT an LLVM codegen bug; it is a layout-sensitive fork/exec wild-free storm that reproduces IDENTICALLY in the NATIVE kernel booted through this same BIOS-ISO/in-RAM-initramfs harness (evidence-backed)

A deep root-cause pass at `fd2776ef` **overturns the "LLVM scheduler-dispatch
miscompile" framing.** The DE-under-LLVM gate FAILs because of a
**layout-sensitive `[pa-corrupt] free of wild addr` storm on the fork/exec COW
teardown path — a KERNEL bug common to BOTH the native and LLVM lanes, not an
`ssa_llvm.ad`/`ssa.ad` codegen divergence.** All experiments below reverted; no
source committed except this note; native kernel byte-identical.

### 1. Reproduced both, then A/B'd in the SAME harness
- Fresh **clean-source LLVM** kernel (`build_kernel_llvm.sh`, `-O0`, selftest
  initramfs, KVM `-cpu host`, `-m 1024M`, BIOS-GRUB-ISO): gate FAILs — fb-flip
  OK but `windows mapped=0`, `[panel] appmenu` missing, screenshot blank. Serial
  is drowned in **5655** `[pa-corrupt] free of wild addr 0x…` lines
  (addrs `0x475000‥0x1106000`, i.e. the user-image region frames), boot reaches
  `[init] entering runlevel 5` only at printk-line **7269** (vs ~664 on a healthy
  boot). The scene clients rfork (pids 18-28) but never map windows; boot idles
  at the `hamsh$` stage-08 prompt.
- **NATIVE** kernel (`_adder_cc.sh adder_cc_link_kernel init/main.ad`, the exact
  default native backend, SAME selftest initramfs + SAME BIOS-ISO harness):
  **IDENTICAL FAIL — storm=5655, same wild addrs `0x475000‥0x1106000`,
  windows=0, rl5 at line 7269.** So the native kernel, driven through the LLVM
  gate's harness, fails exactly the same way. The premise "LLVM maps 0 windows
  while the native kernel PASSES" holds only because the two gates use DIFFERENT
  harnesses: `test_de_visual_gate.sh` boots native under **OVMF + a real ext4
  installer image** (no storm), while `test_de_visual_gate_llvm.sh` boots under
  **BIOS-ISO + the in-RAM cpio initramfs** (storm). The comparison is
  harness-confounded; it is NOT native-vs-LLVM.

### 2. Force-native bisection EXCLUDES every candidate — it is not a leaf-fn miscompile
`KLLVM_FORCE_NATIVE` over seven disjoint clusters — the free path
(`_vma_free_cow_range`, `_vma_node_free`, `_vma_pte_lookup`), the map/alloc path
(`alloc_page(s)`, `alloc_pages_raw`, `elf_map_one_page(_locked)`,
`vma_demand_fault_inner`), the COW/fork-share path (`cow_share_page`,
`cow_drop_page`, `_cow_share_one_page`, `vma_fork_copy`, `vm_cow_share_*`), the
page-table crack path (`_cow_resolve_pte_slot_locked`, `_build_pt_from_pd_entry`,
`_is_boot_identity_stamp`, `elf_install_user_mapping_locked`), and the fork/exec
orchestration (`do_clone`, `do_rfork`, `do_execve*`, `load_elf64`) — each produced
a **byte-identical 5655-line storm.** A single miscompiled function would have
been caught; none was. Runtime stack-walk + PTE probes confirmed the wild frees
come from `_vma_free_cow_range` freeing `pte & PT_ADDR_MASK` for PTEs whose frame
bits equal the VA (region-backed / identity user-image frames), which
`_pa_link_ok` rejects (below the buddy floor).

### 3. The ONE build that passes is a LAYOUT ARTIFACT
The on-disk `build/kllvm/hamnix_kernel_{llvm,de}.elf` (108 MiB) DOES map 8 windows
(0 storm) — but it differs from a fresh build ONLY by a **~49 MiB larger
`.rodata`** (94 MiB vs 45 MiB embedded initramfs); `.text`/`.data`/`.bss` are
byte-identical. That size delta shifts the memory layout enough that the
fork/exec teardown no longer wild-frees — exactly the "force-X-native only
RELOCATES the victim" layout artifact documented in Phases 5g–5o/5m/5n. It is not
a codegen fix.

### 4. Root cause + correct fix locus
The defect is the pre-existing, layout-sensitive **wild-free on the fork-child
image teardown**: a fork child's inherited region-backed ELF image / demand span
is torn down through `_vma_free_cow_range`'s `cow_drop_page→free_page` arm
(mm/vma.ad) instead of the release-only `_cow_release_forked_range`/
`vma_release_forked_range` path, so region-backed (non-buddy) frames are handed to
the buddy allocator and rejected as "wild". `docs/kernel_llvm_phase5b.md` Phase 5s
already noted this storm as "PRE-EXISTING and NON-FATAL … common to both lanes"; it
is in fact FATAL to THIS gate (5655 serial lines + cleared shared low PTEs starve
the DE clients). **The fix belongs in the kernel MM teardown routing (mm/vma.ad),
not in `ssa_llvm.ad`/`ssa.ad`, and must be validated in BOTH lanes.** As a gate
concern, `test_de_visual_gate_llvm.sh` should either boot native through the SAME
BIOS-ISO harness to keep the comparison honest, or the underlying wild-free must
be fixed so both lanes render under the in-RAM path.

## 2026-07-24 — the `[pa-corrupt]` storm is FIXED at its root in `_vma_free_cow_range`; but the storm was NOT the sole cause of the 0-window gate FAIL — a SEPARATE, pre-existing scheduler-dispatch gap still blocks window mapping (evidence-backed, native-safe)

Implemented the fix locus the 2026-07-23 note identified (kernel MM teardown
routing, `mm/vma.ad`) and A/B-verified it in BOTH lanes through the in-RAM
BIOS-ISO harness. The storm is GONE. But the fix, while correct and complete for
the storm, is **necessary-not-sufficient** for the gate: with the storm at zero
the DE scene clients STILL do not map windows, because they never dispatch — a
distinct scheduler bug the storm was co-occurring with, not causing.

### The fix (`mm/vma.ad`, shared native+LLVM source)
In `_vma_free_cow_range`, the `if cow_drop_page(phys) != 0: free_page(phys)` arm
handed region-backed / identity user-image frames (below the buddy floor
`kernel_image_end()`) to `free_page`. Routed them away using the allocator's OWN
predicate:

```
last: int32 = cow_drop_page(phys)
if last != 0 and _pa_link_ok(phys) != 0:
    free_page(phys)
```

`cow_drop_page` still runs unconditionally (refcount stays exact — a genuinely
shared buddy page is still freed exactly once, a parent's per-PFN count is never
stranded). `free_page` is now reached ONLY for a frame that is (a) the last
holder AND (b) a real buddy-managed frame `_pa_link_ok` accepts — i.e. the
`_cow_release_forked_range` release-only semantics applied per-frame. The owner
region (`region_free` / `region_free_cow_safe` at the owner's reap) remains the
sole reclaimer of non-buddy frames. `_pa_link_ok` is exactly the predicate
`free_pages` uses to reject "wild addr", so the routing tracks precisely what
`free_page` would have rejected. (One-line import add of `_pa_link_ok` into
`mm/vma.ad`; no other file touched.)

Why this is a real correctness fix, not just log suppression: the `pa-corrupt`
guard rejects the wild `cur_addr` only AFTER `_free_pages_raw` has already run
`page_reset()` + `lru_remove()` on each frame's PageDesc and attempted a
buddy-merge (`_try_remove_buddy(cur_addr ^ run_size)`) with free-count
accounting — real side effects on non-buddy frames' descriptors and on the buddy
pool, ×5655 per boot. Not calling `free_page` at all removes all of it.

### A/B evidence (fresh clean builds; selftest 45 MiB initramfs; KVM `-cpu host`; BIOS-ISO in-RAM)
| build | `[pa-corrupt]` | rl5 printk line | fb-flip | windows mapped |
|-------|:---:|:---:|:---:|:---:|
| LLVM  **before** (main b8013366) | **5655** | 7269 | yes | 0 |
| native **before** (same source) | **5655** | 7269 | yes | 0 |
| LLVM  **after** (fix)           | **0**    | 1613 | yes | 0 |
| native **after** (fix)          | **0**    | 1613 | yes | 0 |

Storm eliminated in BOTH lanes; runlevel-5 restored from printk-line 7269 → 1613.
The native `before`/`after` pair proves the fix is shared-kernel-correct (not an
LLVM-lane artifact); native `after` boots clean to `hamsh$ stage-08` + the DE
backdrop fb-flip, 0 storm, no panic. `kobjdiff` PASS (native compiler and seed
agree on the new source — codegen consistency preserved; the behavior change is
the intended one).

### The 0-window FAIL is a SEPARATE, pre-existing dispatch gap — NOT the storm
The 2026-07-23 note asserted the storm "clears shared low PTEs, starving the DE
scene clients (0 windows)". Direct measurement refutes that as the whole story:
- With the storm at **0**, the rl5 scene clients (desktop icons / panel / file
  manager / editor, pids 18-26) are rforked but **never `execve`** and map **0**
  windows — `[de_present] live_windows=0`, `[panel] appmenu` never appears,
  screenshot is the flat 1280×800 backdrop (3 colors / 99%).
- This is **byte-for-byte the same** as the `before` (storm) build: `execve`
  jumps after rl5 = 0 and `[devwsys] window … mapped` = 0 in BOTH. The fix
  changed the storm (5655→0) and the boot line count (7269→1613) but did **not**
  change the scene-client dispatch outcome at all.
- The kernel's OWN in-boot devwsys self-test DOES map its 3 windows
  (`[MULTITASK_BAR] all three live windows listed in /dev/wsys/windows`), so the
  `newwindow`/devwsys path is healthy; only the **detached rl5 clients** fail to
  run. This is the "child READY but not dispatched" scheduler gap first noted in
  this doc's original status section and in `docs/kernel_llvm_phase5b.md` Phase 5d
  (the `_another_task_ready` pid-dispatch wall), repeatedly flagged there as a
  **distinct** issue. It reproduces under KVM in the in-RAM harness independent
  of the storm and independent of the accelerator.

So: the storm was a genuine, now-fixed MM correctness bug (and it did flood
serial + perturb the buddy pool / PageDesc array), but removing it does **not**
by itself turn the gate green. The remaining blocker is the scene-client
dispatch gap, which is a scheduler/fork-dispatch defect, out of scope for an MM
teardown routing fix and requiring its own investigation. The gate stays RED on
(b)/(c)/(d) until that dispatch gap is closed; (a) fb-flip PASSES and the storm
regression lock is now green.

### No-regression argument for the working (94 MiB-rodata) render + native OVMF DE
The fix only ever REMOVES a `free_page` call that the buddy guard was already
rejecting; for a genuine buddy frame (`_pa_link_ok` == 1) the behavior is
byte-identical to before. It therefore cannot regress any path that rendered
before (the layout-artifact 94 MiB build, the native OVMF `test_de_visual_gate.sh`
desktop). native `after` empirically boots clean to shell + DE backdrop with
0 storm, corroborating no boot/MM regression.
