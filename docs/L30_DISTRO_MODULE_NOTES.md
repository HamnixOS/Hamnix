# L30 — Stock distro .ko load attempt

## What this is

The L-track regression (L1..L28) loads *fixtures we wrote and built
against pinned linux-6.12.48 headers*. L30 is the next escalation:
take a kernel module that the host's Debian distribution ships
**unmodified** — code we did not write, compile, or link against
Hamnix headers — and point our L1 loader (`kmod_linux`) at it.

We pick the smallest software-only crypto helper available on the
host. None of these touch real hardware, so a load failure here is
"missing ABI" and nothing else.

Candidates (first match wins):
- `/lib/modules/$(uname -r)/kernel/lib/crc8.ko[.xz]`
- `/lib/modules/$(uname -r)/kernel/lib/libcrc32c.ko[.xz]`
- `/lib/modules/$(uname -r)/kernel/crypto/crc32c_generic.ko[.xz]`

The script (`scripts/test_l30_distro_module.sh`) decompresses if
needed, stages the file as `tests/linux-modules/distro_crc.ko` (so
the existing `build_initramfs.py` glob picks it up), rebuilds, boots
QEMU, runs `insmod /lib/modules/6.12/distro_crc.ko`, and harvests
log output. It is **best-effort** — only a kernel panic or an empty
QEMU log is a hard failure.

## First run — 2026-05-15, kernel 6.12.63+deb13-amd64

Host module selected: `/lib/modules/6.12.63+deb13-amd64/kernel/lib/crc8.ko.xz`
(decompressed to a 5,624-byte ELF relocatable).

### What worked

- ELF parse: `shnum=29 shentsize=64`, module name `crc8`.
- `vermagic` extracted: `6.12.63+deb13-amd64 SMP preempt mod_unload modversions`.
- Two MODVERSIONS-protected symbols bypassed cleanly (we don't enforce CRCs).
- `.gnu.linkonce.this_module` section located, 1280 bytes (the
  struct module template the kernel hands back to `init_module`).
- Image laid out at `0x0000000000421000`, 4096 bytes.
- **25 relocations applied**, 3 skipped.
- Kernel did not panic; `hamsh$` prompt returned cleanly after the
  failed insmod; `exit` then halted the kernel normally.

### What failed

- **Single missing symbol**: `__x86_return_thunk`, referenced **3
  times** in the module's relocations.
  This is the Spectre v2 / retpoline return-trampoline symbol every
  modern x86_64 Linux module emits to terminate a `ret` instruction
  via the indirect-thunk mitigation. Stock kernels provide it as
  either a 1-byte naked `ret` (when retpolines are off) or a
  patched-in trampoline (when on).
- After relocations finished, the loader reported `no init_module
  symbol` — the module's init entry is encoded via the `.init`
  pointer **inside** the `struct module` template in
  `.gnu.linkonce.this_module`, not as a flat `init_module` ELF
  symbol. Our loader currently only looks for the latter.
- `insmod` exited with code 1 ("init_module failed"), but that is
  graceful failure — kernel control returned to userspace.

### Concrete first-run unresolved-symbol list

    '__x86_return_thunk'    (x3 references)

That is the entire list. One symbol. Three relocations.

## Implications for the L-track roadmap

This is excellent news. It says the L1..L28 ABI is **already
sufficient for a real distro module's symbol surface** — `crc8`
calls into no kernel API other than what's implicit in its module
init/exit boilerplate. The remaining gaps are:

1. **`__x86_return_thunk`** (L31 candidate): trivial to add — export
   a 1-byte `ret` (or a 2-byte `bnd; ret`) thunk into the kernel
   symbol table. This is a one-line fix.

2. **`init_module` discovery via `struct module`** (L32 candidate):
   teach `kmod_linux` to read the `init` field out of
   `.gnu.linkonce.this_module` instead of (or in addition to)
   looking up a standalone `init_module` symbol. The Linux struct
   layout is stable across 6.12.x — offsets can be hard-coded for
   now and made versioned later.

Once both are in, the next first-run on `crc8.ko` should reach
`module_init` and run the upstream `crc8_populate_msb` /
`crc8_populate_lsb` table builders (they touch nothing but
malloc'd memory).

## How to re-run

    bash scripts/test_l30_distro_module.sh

The script auto-skips with exit 0 (and a `L30: no candidate distro
module on this host; skipping` line) if no candidate is present —
safe for CI on non-Debian or stripped-down hosts.

The captured serial log path is printed on the final line of the
script's output; it is **not** auto-deleted, so you can grep it for
further triage.
