# Rootfs partition is Plan 9-shape, not a global mount

**Status:** design committed 2026-05-26 (commits f136f4b, a85ef44,
758d02a). See docs/rootfs_partition.md for the full design.

## What it is

The Hamnix ISO has a separate ext4 partition (partition 3 in the
GPT) for distro content. The kernel auto-discovers it at boot via
`mount_rootfs_partition()` in init/main.ad and mounts it through
the existing `/ext` device-letter dispatch.

The partition is NOT bound globally into the init namespace. Only
etc/rc.boot's userspace recipe does the binding:

  - `bind /n/distros /ext`  — init ns sees rootfs at /n/distros/
  - `linux = ns clean { bind / /ext; ... }` — linux ns sees / as rootfs

## Mistakes to NOT make

1. **Don't make the rootfs a global init-ns mount.** The shell's
   own `/`, `/usr/bin/`, `/etc/`, ... must stay Hamnix-native (cpio).
   If you `bind / /ext` at the kernel level or in init ns, apt
   installs WILL shadow Hamnix paths and break the shell.

2. **Don't try to put the rootfs on the FAT12 ESP.** That's what this
   pivot fixed. FAT12 caps at ~250 MiB (4084 clusters × 64 KiB max
   cluster size); OVMF rejects FAT16/FAT32 ESPs. Live USB-style
   layouts use a separate ext4 partition.

3. **Don't stage rootfs builds to /tmp.** tmpfs is RAM-backed and
   filling it crowds out the build cache. `scripts/build_rootfs_img.py`
   stages to `build/.rootfs-stage/` (project disk).

4. **Don't `rsync -a` from a source tree containing /dev devices
   without excluding /dev/.** rsync without `-D` (and you can't `-D`
   as non-root) will OPEN /dev/random and produce a 100+ GiB regular
   file before tmpfs fills.

5. **Don't add real Debian back to the cpio if HAMNIX_CPIO_LEAN=1
   is set.** That defeats the size-shrink the partition migration
   provides. The cpio carries init + hamsh + boot-essential .ko's
   only; everything else lives on the rootfs partition.

6. **Don't chain bind rewrites expecting double-resolution.**
   `chan_resolve_prefix` does ONE rewrite per `vfs_open`. So
   `bind /usr /n/distros/usr` + `bind /n/distros /ext` won't
   double-rewrite to `/ext/usr`. Resolve directly in one bind
   (`bind / /ext`) or add an explicit re-entry loop (deferred).

## User design direction (2026-05-26)

> "you plug in a thumb drive and it shows up as a single letter.
> It allows us to split up the default EXT4 file system in logical
> separated ways."
>
> "Let's do it split so that a FS found by the kernel without top
> level #X letters is just a single File server, but if the root
> contains #X hashtag<letter> then it's serves each folder as it's
> own fileserver."

Target shape (not yet implemented; current ships single-server):

- Each discovered ext4 partition = a Plan 9 device letter (`#A`,
  `#B`, …).
- Single-server mode if the partition root contains conventional
  Unix directories (`usr/`, `bin/`, …).
- Multi-server mode if the partition root contains marker-prefixed
  directories (`#a/`, `#b/` — marker syntax TBD), each becoming its
  own sub-server addressable as `#A/a/`, `#A/b/`, etc.

Open questions remaining for the next iteration: marker character,
auto-bind behaviour, per-server unmount semantics. See docs/
rootfs_partition.md "Future direction" section.
