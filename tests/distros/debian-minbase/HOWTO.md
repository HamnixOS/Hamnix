# tests/distros/debian-minbase/HOWTO.md

A real Debian minbase rootfs used as the backing store for the
`debian-minbase` distro inside Hamnix's distro-shape namespace
mechanism (see `docs/distro-namespaces.md` for the spec, and
`user/distrorun.ad` for the entry-point binary).

This directory is the **infrastructure for staging a real Debian
rootfs as a distro backing**. The actual binary tree lives in
`rootfs/` and is gitignored (too large + redistributing GPL/LGPL
packages bypasses the upstream archive convention). Only `BUILD.sh`,
`MANIFEST.txt`, and this file are tracked.

## Why

The Phase C.5 testdistro fixture (`tests/distros/testdistro/`) is a
two-file synthetic backing — just `/etc/debian_version` + `/etc/os-release`
— which proved the namespace bind path. It can't exec anything.

This fixture is a **real Debian rootfs**, so `distrorun debian-minbase
/bin/true` actually exec's the Debian-shipped `/bin/true` from inside
the namespace. From here, `deb /bin/cat /etc/debian_version` is a
genuine read of Debian's release string through the bind, and `deb
/bin/bash` is the first real distro shell on Hamnix (modulo the
dynamic-linker follow-up — see "Known limitations").

## One-time host build

Requires a Debian/Ubuntu (or any debootstrap-capable) host, sudo,
working network, and ~150 MB of disk:

    sudo apt install debootstrap
    bash tests/distros/debian-minbase/BUILD.sh

That runs:

    sudo debootstrap --variant=minbase --include=bash,coreutils \
        stable ./rootfs http://deb.debian.org/debian

then chowns the tree back to the calling user. Expected wall-clock:
2-5 minutes depending on mirror speed. Final size: ~80-150 MB.

`BUILD.sh` refuses to clobber an existing `rootfs/`. To re-run:

    sudo rm -rf tests/distros/debian-minbase/rootfs
    bash tests/distros/debian-minbase/BUILD.sh

## What lands inside rootfs/

See `MANIFEST.txt` for the expected key paths. Briefly:
- Real `/bin/true`, `/bin/false`, `/bin/cat`, `/bin/ls`, `/bin/bash`.
- Real `/lib/x86_64-linux-gnu/libc.so.6` + `/lib64/ld-linux-x86-64.so.2`.
- Real `/etc/debian_version`, `/etc/os-release`, `/etc/passwd`,
  `/var/lib/dpkg/`.

## Using it from Hamnix

`scripts/build_initramfs.py` recognises a `HAMNIX_EMBED_DEBIAN=1`
opt-in env var that walks `tests/distros/debian-minbase/rootfs/` and
embeds every file at `/var/lib/distros/debian-minbase/<rel>` in the
cpio archive. Default-off: embedding ~100 MB of Debian binaries
inflates the committed `fs/initramfs_blob.S` past GitHub's 100 MB
push limit, so it stays opt-in.

To boot Hamnix with debian-minbase available:

    HAMNIX_EMBED_DEBIAN=1 bash scripts/run_x86_bare.sh

`run_x86_bare.sh` rebuilds the kernel and boots it under QEMU via the
`scripts/_kernel_iso.sh` GRUB-ISO shim (QEMU's `-kernel` cannot load the
`elf64-x86-64` higher-half kernel directly — see `docs/BOOT.md` §1).

Then inside hamsh:

    /bin/distrorun debian-minbase /bin/true
    /bin/distrorun debian-minbase /bin/cat /etc/debian_version

## End-to-end test

`scripts/test_distro_debian.sh` is the regression. It runs distrorun
against `/bin/true` and checks exit 0, then runs it against
`/bin/cat /etc/debian_version` and checks the captured output
contains a plausible Debian release token.

The test skips cleanly (exit 0) if `rootfs/bin/true` doesn't exist —
matching `scripts/test_u5_linux_binary.sh`'s skip-on-missing pattern,
so CI on hosts that haven't run BUILD.sh still passes.

## Known limitations / follow-ups

1. **`/bin/true` is statically linkable** but the Debian-shipped
   build is dynamically linked against glibc. Running it requires
   a working `ld-linux-x86-64.so.2` as the ELF interpreter. Hamnix's
   U-track currently handles static-pie binaries; loading a Debian
   binary through its dynamic linker is a separate, larger
   bring-up. **This commit ships the infrastructure (rootfs +
   embedding + distrorun glue) so that work can land independently.**
2. **No `apt update` yet.** That needs working network from inside a
   distro namespace plus a working dynamic linker.
3. **rootfs is gitignored.** Future contributors hitting this fixture
   have to run BUILD.sh themselves. Acceptable: the binary content
   is large and the upstream archive is the source of truth.
4. **Stable channel only.** BUILD.sh hard-codes `stable`; switch to
   `trixie` / `bookworm` / `sid` by editing the script if a specific
   release is wanted.
