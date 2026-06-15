# Dead-code / duplication audit — `scripts/` and `tests/`

Read-only audit (2026-06-15). No source deleted or edited; this is a findings report only.

## Method

- Inventory: 871 files under `scripts/` (822 `test_*.sh`), 100 `tests/test_*.ad`.
- CI surface (the only "hard" callers): `.github/workflows/ci.yml` invokes **15** scripts by name
  (`test_adder_pin.sh`, `build_user.sh`, `build_initramfs.py`, then 12 `test_*.sh` battery items +
  `test_hamsh`/`test_efi_gop`/`test_net_*`); `.github/workflows/packages.yml` invokes
  `build_initramfs.py`, `build_modules.sh`, `build_packages.py`, `build_user.sh`.
- The remaining ~800 `test_*.sh` are the **orchestrator-run regression battery**: run by basename by the
  human/orchestrator, not by an in-repo caller. Per the working agreements these are NOT dead merely for
  lacking an in-repo caller. This audit therefore targets (a) NON-test helper/builder scripts with zero
  callers, (b) scripts referencing retired artifacts, (c) orphan test fixtures with no runner, and
  (d) harness boilerplate duplication.
- For every NON-`test_` script the basename was grepped tree-wide (`.sh .py .yml .md .ad Makefile* .rc`,
  excluding `.git/` and the file's own definition) to count callers.

Tags: `SAFE-REMOVE` (no caller, no doc, superseded) · `NEEDS-REVIEW` (manual/user tool or documented —
keep unless the user confirms) · `KEEP` (live).

---

## 1. DEAD / ORPHAN SCRIPTS & FIXTURES

- [SAFE-REMOVE] `scripts/build_realinrelease_img.py` — builds an ext4 disk for `test_apt_inrelease_real.sh`.
  Evidence: its sole consumer `test_apt_inrelease_real.sh` **does not exist** anywhere in the tree
  (`ls scripts/test_apt_inrelease*` → none); zero callers tree-wide. The test it feeds was removed; the
  builder was left behind. Recommendation: remove.

- [SAFE-REMOVE] `scripts/rfork_pid1_cow.rc` — a one-off hamsh `.rc` to hand-reproduce the PID-1 first-rfork
  COW fault. Evidence: zero callers; the actual regression `test_rfork_pid1_cow.sh` plants a cpio marker
  and does **not** reference this `.rc` (its `HAMNIX_HAMSH_RC` matches elsewhere are substring noise in
  unrelated files). Leftover manual repro. Recommendation: remove (or move to a `scratch/` if kept as a
  manual repro note).

- [NEEDS-REVIEW] `tests/test_rio_blit_protocol.ad` — orphan test fixture with **no runner**. Evidence: the
  only `.sh` that mentions rio-blit, `scripts/test_de_rio_blit.sh`, is a *source-grep structural guard*
  (greps `devwsys.ad`/`hamui.ad`/`hamUId.ad`); it never compiles or executes this `.ad`. Referenced
  otherwise only in `STATUS.md`. Either it was meant to be compiled/run and the runner was never wired, or
  it is stale. Recommendation: wire a runner or remove — confirm intent with user.

- [NEEDS-REVIEW] `scripts/debug.sh` — GDB launcher for **RP2040 / STM32F4 via OpenOCD** (`arm-none-eabi-gdb`).
  Evidence: zero callers; pairs only with `.gdbinit`. These targets are from the retired MCU-OS era
  (ci.yml header: "Replaces the retired MCU-OS workflow"); current Hamnix is x86_64 + ARM64-*board*, no
  RP2040/STM32. Stale relic. Recommendation: remove the MCU branches or the whole script after confirming
  no one uses it as a generic QEMU-gdb attach.

- [NEEDS-REVIEW] `scripts/run_iso.sh` — interactive launcher that boots `build/hamnix.iso`. Evidence:
  referenced only by `STATUS.md`. The ISO is **retired** — `scripts/build_iso.sh` is now a deprecation
  shim that delegates to `build_installer_img.sh` and no longer produces `build/hamnix.iso`. So this
  launcher points at a dead artifact path. Recommendation: re-point at `build/hamnix-installer.img` (like
  `write_img_to_usb.sh`) or retire it.

- [NEEDS-REVIEW] `scripts/ci-test.sh` — generic "CI runner" (`--quick`/`--demo`). Evidence: the real CI
  (`ci.yml`) does **not** call it (`grep ci-test ci.yml` → 0); `test_efi_gop.sh` only name-drops it in a
  *comment* ("PASS line is grepped by ci-test.sh"); `docs/subsystems/build-test.md` still calls it
  "the CI runner" — a stale doc claim. Superseded by the per-test steps in `ci.yml`. Recommendation:
  fix the doc and decide whether to keep as a local convenience runner.

## 2. RETIRED-ARTIFACT REFERENCES (orphan/stale)

The baked GPT image `build/hamnix.img` and `scripts/build_img.sh` are RETIRED (memory + `STATUS.md`),
replaced by `build_installer_img.sh` + `build_installed_nvme.sh`. `build_img.sh` itself is already gone.
Remaining references are all **deprecation comments / intentional stubs** (KEEP — they give runners a
clean SKIP/redirect instead of "file not found"):

- [KEEP] `scripts/test_bios_boot.sh` — retired stub, prints `[test_bios_boot] SKIP` (BIOS retired, UEFI-only).
- [KEEP] `scripts/build_iso.sh` — deprecation shim, `exec`s `build_installer_img.sh`.
- [KEEP] `scripts/test_iso_qemu.sh` — deprecation shim, `exec`s `test_installer_nvme_inram.sh`.
- [KEEP] `scripts/test_virtio_gpu_present.sh`, `test_img_uefi_hamui.sh`, `test_img_uefi_hamterm.sh`,
  `test_useradd.sh`, `test_auth.sh`, `build_installed_nvme.sh` — `hamnix.img` appears only in comments
  documenting the migration; they actually use `build/hamnix-installer.img` / `hamnix-installed.qcow2`.

Stale-but-keep launcher (also under §1): `run_iso.sh` (dead `hamnix.iso` path).

## 3. NON-TEST SCRIPTS — caller counts (low end)

Zero in-repo callers: `build_realinrelease_img.py` (§1), `debug.sh` (§1), `rfork_pid1_cow.rc` (§1),
`write_img_to_usb.sh` (below).

- [KEEP] `scripts/write_img_to_usb.sh` — self-documented manual `dd`-to-USB user tool with safety guards
  (refuses /dev/sda, >64 GiB, prompts). Not in docs, but a deliberate user-facing utility. Keep
  (optionally link from `docs/REAL_HARDWARE.md`).
- [KEEP] Single-consumer fixtures — all genuinely consumed: `build_btrfs_fixture.py`→`test_btrfs.sh`,
  `build_iso_fixture.py`→`test_iso9660.sh`, `build_ntfs_fixture.py`→`test_ntfs.sh`,
  `build_source_pkg_fixture.py`→`test_hpm_source_pkg.sh`, `build_realgz_img.py`→`test_inflate_realgz.sh`,
  `gen_default_wallpaper.py`→`build_initramfs.py` (real import at build time).
- [NEEDS-REVIEW] M1 Linux-`.ko` dev-kernel chain: `build_x86_kernel.sh` → `run_x86_module.sh` →
  `make_initramfs.sh`, plus `x86_kernel_config.sh`. Documented in `docs/subsystems/build-test.md` and
  entered via `kernel-modules/hello/Makefile`, but **no `test_*.sh` invokes them** — manual dev tooling
  for the custom Linux module-test kernel. Keep as documented dev tools; confirm still needed for the
  `.ko` loop.

## 4. REDUNDANT HARNESS GROUPS (boilerplate dedup, NOT removals)

NOTE: in each group the "superset" scripts test genuinely DIFFERENT things (fps vs visual-gate vs
mouse-refresh vs glyph-render) — they are NOT redundant *tests*. The redundancy is the **copy-pasted
boot/capture boilerplate**. The recommendation is to extract a shared sourced helper, not delete tests.
No shared OVMF/screendump helper exists today; the existing helpers (`_kernel_iso.sh`, `_qemu_drive.sh`,
`_installed_boot.sh`, `_build_lock.sh`, `_ensure_ubin.sh`) cover the `-kernel` and installed-NVMe paths
but **not** the installer-OVMF-screendump path. **27** `test_*.sh` independently re-copy the
OVMF_VARS/OVMF_CODE + QEMU-monitor + screendump setup.

### Group A — OVMF / GOP framebuffer + monitor `screendump` (installer or golden disk)
~55–65% of each script is identical OVMF-resolve + PPM→PNG converter detect + `socat/nc` monitor +
QEMU-launch + handoff-marker-wait boilerplate (~110–130 of 196–340 lines each).
- Canonical boilerplate template: **`scripts/test_de_screenshot.sh`** (simplest single-shot screendump).
- Boilerplate-duplicating peers (KEEP the tests, factor the harness): `test_de_visual_gate.sh`,
  `test_de_mouse_refresh.sh`, `test_de_fps.sh`, `test_de_runtime_e2e.sh`, `test_img_uefi_hamui.sh`,
  `test_img_uefi_hamterm.sh`, `test_de_cursor_nudge.sh`, `test_de_kbd_shortcuts.sh`,
  `test_de_wallpaper.sh`, `test_de_runtime_smoke.sh`, `test_installer_de_runlevel5.sh`.
- Recommendation: extract `scripts/_de_ovmf_screendump.sh` (OVMF resolve, converter detect, `mon_cmd()`,
  cleanup trap, QEMU launch, marker-wait). ~770 duplicated LOC collapses.

### Group B — installer live-image + `ENABLE_*_SELFTEST=1` + serial-marker assert (`*_gop.sh`)
~40–45% identical (OVMF resolve, `mksquashfs` check, conditional rebuild with per-test
`ENABLE_*_SELFTEST` env, OVMF_RW/MEDIA_RW setup, QEMU launch, `assert_marker()`, banner/GOP grep epilogue;
~75–90 of 187–276 lines each). Capture is serial-marker grep (no screendump).
- Canonical boilerplate template: **`scripts/test_hamUI_evloop_gop.sh`** (simplest marker gate).
- Boilerplate-duplicating peers: `test_hamUI_mouse_gop.sh`, `test_hamUI_appspine_gop.sh`,
  `test_hamUI_menuterm_gop.sh`, `test_hamUI_termspine_gop.sh`, `test_hamUI_volume_gop.sh`,
  `test_hamUI_markupclient_gop.sh`, `test_hamUI_phase4c_interactive.sh`, `test_hamUI_phase4c.sh`.
- Recommendation: extract `scripts/_de_installer_selftest.sh` (checks, rebuild-with-env, launch, wait,
  `assert_marker`, epilogue); each `*_gop.sh` sets its `ENABLE_*` var + its marker names.

### Group C — pure source-grep structural guards (`test_de_*_v2.sh`, 17 scripts)
No boot, no screendump — each greps DE source files (`hamUId.ad`, `hampanel.ad`, `devwsys.ad`, `namec.ad`)
for "next-layer" wiring tokens. ~25–30% shared (PROJ_ROOT, `fail`/`fail_link` helpers, file-existence
checks, `daemon_pixel` awk-extraction, link-check loop, epilogue).
- Canonical boilerplate template: **`scripts/test_de_panel_v2.sh`** (simplest guard).
- Peers (all 17 share the skeleton): `appmenu, bottom, calpop, ctxmenu, cycler, desktop, lock, notif, osd,
  rband, resize, run, sessui, snap, sysmon, tray` `_v2.sh`.
- Recommendation: extract `scripts/_de_v2_guard.sh` (`fail` helpers, source checks, `daemon_pixel`
  extractor, link-loop, epilogue); each guard sets `GUARD_NAME` + a `LINKS` list. Cheap, low-risk, keep
  all 17 as distinct gates.

### Cross-cutting recommendation
A single `scripts/lib/common.sh` (or the three helpers above) should own: OVMF firmware resolution,
the QEMU monitor `screendump`→image idiom, the KVM-detect launch wrapper, and `assert_marker`. 27 scripts
currently re-implement the OVMF/monitor block independently.

---

## Summary counts

- DEAD/orphan (SAFE-REMOVE): **2** — `build_realinrelease_img.py`, `rfork_pid1_cow.rc`.
- Stale / superseded (NEEDS-REVIEW): **5** — `debug.sh`, `run_iso.sh`, `ci-test.sh`,
  `tests/test_rio_blit_protocol.ad`, M1 dev-kernel chain (`build_x86_kernel.sh`/`run_x86_module.sh`/
  `make_initramfs.sh`/`x86_kernel_config.sh`, treated as one cluster).
- Retired-artifact references: all are intentional KEEP stubs/shims (no removals).
- Redundant-harness boilerplate groups: **3** (A: OVMF-screendump ~11 scripts; B: `*_gop.sh` ~8 scripts;
  C: `*_v2.sh` 17 scripts) — extract shared helpers; do NOT delete the tests.
