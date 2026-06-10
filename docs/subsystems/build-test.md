# Build & Test

> **Source of truth:** `scripts/` (all), `tests/`, `.github/`,
> `adder/scripts/`
> **Last verified against source:** 2026-06-10
> **Boot/install detail:** [../BOOT.md](../BOOT.md),
> [../REAL_HARDWARE.md](../REAL_HARDWARE.md)

## Purpose

The build pipeline (Adder compiler → kernel/user ELFs → bootable images)
and the very large QEMU-driven test suite (~700 `scripts/test_*.sh`).
There is no `make`-driven C build; everything is shell scripts invoking
the Adder compiler plus image-assembly tooling.

## Key files

### Build

| Path | Role |
|--|--|
| `scripts/build_x86_kernel.sh` | (fetches/builds the custom Linux dev kernel for the M1 `.ko` loop — not the Hamnix kernel) |
| `scripts/build_user.sh` | compile the `user/` Adder binaries (`x86_64-adder-user`) |
| `scripts/build_installer_img.sh` | **the primary artifact**: `build/hamnix-installer.img` (ESP-only GPT; kernel + squashfs root loaded into RAM by firmware) |
| `scripts/build_installed_nvme.sh` | run the installer once → `build/hamnix-installed.qcow2` (golden VM disk) |
| `scripts/build_iso.sh` | thin shim that delegates to `build_installer_img.sh` |
| `scripts/build_modules.sh` / `build_linux_modules.sh` | build the `.ko` regression modules |
| `scripts/build_modules_dep.py` / `build_modules_alias.py` | generate `modules.dep` / `modules.alias` |
| `scripts/build_packages.py` | build `hpm` packages (run with `python3`) |
| `scripts/gen_install_manifest.py`, `gen_linux_abi.py`, `gen_autostubs.py`, `gen_secureboot_blob.py` | code/asset generators |
| `scripts/build_*_fixture.py` | FS test fixtures (btrfs/ntfs/iso/xz/source-pkg) |
| `scripts/_build_lock.sh` | per-test build-output isolation lock (auto-wipes compiled outputs) |

### Test

| Path | Role |
|--|--|
| `scripts/ci-test.sh` | the CI runner (builds + boots QEMU; `--quick`/`--demo` modes) |
| `scripts/test_*.sh` (~700) | per-feature integration tests (boot a QEMU image, assert on serial/markers) |
| `scripts/_installed_boot.sh` | shared harness: boot a fresh copy of the golden installed disk |
| `scripts/_qemu_drive.sh`, `_kernel_iso.sh`, `_make_ext4_test_disk.sh` | QEMU/disk harness helpers |
| `scripts/ocr_boot_log.py` | OCR a boot-video capture (`<video>.ocr.txt`) for serial-less HW debug |
| `tests/u-binary/`, `tests/linux-modules/`, `tests/distros/` | fixtures: Linux user binaries, `.ko` sources, distro namespaces |
| `adder/scripts/test_compiler_*.sh` | compiler regression tests (run via `run_compiler_tests.sh`) |
| `.github/` | CI workflows |

## Architecture & data structures

- **Two-stage image build**: `build_installer_img.sh` produces the
  in-RAM installer; `build_installed_nvme.sh` runs that installer once
  against a blank disk to produce the golden `hamnix-installed.qcow2`.
  Feature tests boot a throwaway copy of the golden disk via
  `_installed_boot.sh`. There is **no pre-baked root image**; the
  installer lays ext4-on-NVMe.
- **Per-test isolation**: `_build_lock.sh` wipes compiled outputs per
  test so builds are clean; `HAMNIX_BUILD_DIR` (opt-in) isolates per-
  output build dirs for parallel work.
- **Serial-driven assertions**: tests boot QEMU, feed/await serial
  markers (not fixed sleeps), and grep the boot log. HW-debug uses the
  ESP `LOG.TXT` extent + `ocr_boot_log.py` because the NUC has no serial.

## Entry points

- `scripts/ci-test.sh` — run the suite.
- `scripts/build_installer_img.sh` → `build/hamnix-installer.img`.
- `scripts/build_installed_nvme.sh` → `build/hamnix-installed.qcow2`.
- `python3 scripts/build_packages.py` — build hpm packages.

## Invariants & gotchas

- **`.py` build scripts run with `python3`, not `bash`** (e.g.
  `build_packages.py`, `gen_install_manifest.py`, `build_initramfs.py`).
- Interactive/serial tests must gate keystrokes on a **boot-ready
  marker**, not a fixed `sleep N` (fixed sleeps pass in isolation, regress
  under integration load). A freshly-booted hamsh drops the FIRST serial
  command line — re-send each selftest until its marker appears.
- Under concurrent load, TCG-QEMU can starve and virtio-blk reads fail
  (`status=255`) → spurious ext4 test FAILs. Verify in a quiet window;
  trust compile + a clean isolated run.
- UEFI tests need OVMF; the suite is UEFI-only (no BIOS path).

## Related docs

- [adder-compiler.md](adder-compiler.md) — the compiler the build invokes.
- [../BOOT.md](../BOOT.md), [../REAL_HARDWARE.md](../REAL_HARDWARE.md).
- [../packages.md](../packages.md) — the hpm package build.
