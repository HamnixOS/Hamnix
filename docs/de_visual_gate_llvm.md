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
