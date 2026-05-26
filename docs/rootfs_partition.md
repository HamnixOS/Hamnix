# Rootfs partition — Plan 9-shape, two-medium layout

## TL;DR

Hamnix's ISO carries the kernel ELF on a small ESP and a separate
ext4 partition (`/dev/...p3` on the live medium) for the bulk of
distro content (real Debian apt/dpkg, busybox, future user data).
At boot the kernel auto-discovers the ext4 partition and exposes it
through the existing `/ext` device-letter dispatch in `fs/vfs.ad`.
Userspace `etc/rc.boot` then `bind`s the rootfs at `/n/distros` in
the init namespace and at `/` inside the `linux = ns clean { ... }`
recipe — so:

- The shell sees the rootfs at **`/n/distros/`** (read/write).
- The Linux namespace sees the rootfs at **`/`** (read/write).
- The shell's own `/`, `/etc`, `/bin`, … stay Hamnix-native (cpio).
- `apt install foo` from inside `enter linux { ... }` lands at
  `/usr/bin/foo` in the Linux ns → on the partition → visible to
  the shell at `/n/distros/usr/bin/foo`. **The shell's `/usr/bin/`
  is unaffected.**

This is the "1 GB+ live USB" model the user asked for (2026-05-26):
no FAT12 ceiling on the rootfs, the shell can write to the partition,
and Linux-ns writes can't shadow Hamnix paths.

## Why this exists (the FAT12 ceiling)

Pre-2026-05-26, the kernel ELF embedded a `cpio` initramfs containing
EVERYTHING — userland binaries, real Debian apt/dpkg, busybox, the
distro tree. As real Debian landed, the ELF grew to ~86 MiB, the ESP
had to grow to 128 MiB (with custom mformat geometry) just to hold
the ELF, and the FAT12 spec's 4084-cluster maximum capped the ESP at
~250 MiB regardless of cluster size. OVMF refuses FAT16/FAT32 ESPs.
There was no way to grow past 250 MiB without leaving the ESP.

Linux live USBs solve this with two partitions: a small ESP holding
just the kernel + initramfs + bootloader, and a separate ext4/squashfs
partition the kernel mounts at boot. Hamnix now does the same.

## Partition layout (ISO)

The ISO emitted by `scripts/build_iso.sh` is a GPT-partitioned hybrid
image:

| # | Type | Contents                                                  |
|---|------|-----------------------------------------------------------|
| 1 | BIOS boot   | GRUB i386-pc core + hybrid MBR boot code           |
| 2 | EFI System (ESP, FAT12) | kernel ELF + native PE/COFF stub @ `\EFI\BOOT\BOOTX64.EFI` |
| 3 | Linux filesystem (0x83) | ext4 image staged by `scripts/build_rootfs_img.py` |

Partition 3 is the "rootfs" / "distrofs" partition. It's an ext4
filesystem with no journal (read-mostly), built via `mkfs.ext4 -d
<staging-dir>` so all bytes are baked at build time.

## How the kernel discovers it

At boot, `init/main.ad`'s `start_kernel()` calls
`mount_rootfs_partition()` after `block_smoke_test()`. The function
walks every registered block device (vda from virtio-blk; sd0pN from
AHCI; etc.) and reads its ext4 superblock area (sectors 2..3). The
first device whose bytes 0x438..0x439 are `53 EF` (little-endian
0xEF53) is mounted via `ext4_init(slot)` and lights up the `/ext`
path dispatch in `fs/vfs.ad`.

```text
[rootfs] scanning block devices for ext4 magic
[rootfs] ext4 magic on slot 1 (vda3)
[rootfs] mounted ext4 rootfs at /ext (slot=1, exposed to namespaces as #/distrofs via etc/rc.boot's linux ns recipe)
```

If no ext4 partition is found (e.g. `-kernel ELF` boot with no rootfs
disk attached), the kernel logs `[rootfs] no ext4 partition found`
and continues. The init namespace falls back to cpio-only; the
`linux = ns clean { ... }` recipe will see `/ext` resolve to nothing
and `enter linux { ... }` will fail with `-ENOENT` (use
`HAMNIX_CPIO_LEAN=0` to ship the full cpio fallback).

## How userspace exposes it (etc/rc.boot)

The init namespace `bind`s the rootfs at `/n/distros` so the **shell
has read/write access** to the partition's free space:

```hamsh
bind /n/distros /ext
```

The shell can:
- `cat /n/distros/usr/bin/dpkg` — read the real Debian dpkg
- `cat > /n/distros/home/me/myfile` — write user files to the partition

The Linux namespace recipe `bind`s the rootfs at `/` inside the
**isolated linux ns** (it's `ns clean`, a fresh empty Pgrp):

```hamsh
linux = ns clean {
    bind / /ext
    bind /home /home
    bind /dev '#c'
    ...
}
```

Inside `enter linux { /usr/bin/dpkg }`, the path `/usr/bin/dpkg`
resolves via the linux ns mtab → `/ext/usr/bin/dpkg` → ext4 lookup.

## The isolation guarantee (user direction 2026-05-26)

> "the mounts a linuxname space uses is just diffrent mounts from
> the init system on a clean ns. isolating the software int he
> linuxname space from the normal shell/init crated mounts. AKA
> installing via apt only lands in the linux ns/file servers and the
> shells root view is uneffected."

**What apt sees**: a `/` that's the rootfs partition. Writes go to
`/usr/bin/<X>` etc.

**What the shell sees**: its own Hamnix-native `/` (cpio), with the
rootfs partition available at `/n/distros/`. apt's writes ARE visible
— at `/n/distros/usr/bin/<X>` — but they DON'T shadow the shell's
`/usr/bin/` (which is cpio-served from Hamnix's own binaries).

This is exactly Plan 9's namespace model: shared mounts visible at
shared paths, per-namespace overlays for divergent views, and clean
isolation when you start with `ns clean { ... }`.

## How to grow the rootfs

The image's size is auto-picked by `scripts/build_rootfs_img.py`
(staging bytes + ~96 MiB headroom). To force a specific size:

```bash
HAMNIX_ROOTFS_SIZE_MB=512 python3 scripts/build_rootfs_img.py
```

To add more content, modify `REAL_DEBIAN_FILES` in
`scripts/build_rootfs_img.py`. Each entry is a path relative to
`tests/distros/debian-minbase/rootfs/`. Run `BUILD.sh` first to
populate the debootstrap source if it's absent.

Future apt-install scratch space: the image as built reserves ~96
MiB of free blocks at the end. `apt install foo` from inside the
linux ns writes there; the kernel's ext4 write path already handles
extent allocation + bitmap updates (see `fs/ext4.ad`).

## How to skip it (tests booting without a rootfs disk)

Most kernel test scripts use QEMU's `-kernel ELF` mode, which loads
the kernel ELF directly without attaching the ISO or rootfs disk.
For those:

1. Build the cpio with full debian closure (default): no env var needed.
2. The kernel's `mount_rootfs_partition()` walk finds no ext4 partition
   and logs the skip. The linux ns inside `etc/rc.boot` will have
   `/ext` resolve to nothing.
3. Tests that need apt/dpkg either (a) attach the rootfs.img as
   `-drive file=build/hamnix-rootfs.img,if=virtio,format=raw` so
   vda is the ext4 directly, OR (b) keep using the in-cpio fallback
   (the default-on `HAMNIX_DEFAULT_REAL_DEBIAN=1` path).

## Common pitfalls (so we don't make these mistakes again)

### Don't follow symlinks blindly into source's `/dev`
The debootstrap `tests/distros/debian-minbase/rootfs/dev/` contains
real device nodes. `rsync -a` (or `shutil.copytree`) without
`--no-D --exclude=/dev/` will OPEN AND READ those device nodes from
the source — `/dev/random` is endless, producing 100+ GiB
"random" regular files in staging until /tmp tmpfs fills up. The
`scripts/build_rootfs_img.py` rsync command exclude list is
load-bearing.

### Don't stage to /tmp tmpfs
On a 16 GiB system, /tmp tmpfs is 16 GiB. A 200 MiB rootfs staging
crowds out the kernel build cache and risks OOM. The script stages
to `build/.rootfs-stage/` (on the project disk, which is many TiB)
and tears it down on exit.

### Don't make the rootfs a global init-ns mount
The init namespace must stay Hamnix-native. If the kernel binds
the rootfs at `/` or `/usr/bin/` in the init Pgrp, the shell's own
binaries get shadowed by the Debian tree's binaries. `apt install`
would then overwrite Hamnix paths. The Plan 9 shape — mount the
rootfs at `/n/distros` (shell-visible at a different path) and only
overlay it at `/` inside the linux ns — is what preserves the
isolation guarantee.

### Don't try to put the rootfs on the FAT12 ESP
The whole point of this design is that the ESP stays SMALL (just
the kernel + EFI stub). FAT12's 4084-cluster ceiling caps it at
~250 MiB regardless of cluster size, and OVMF rejects FAT16/FAT32
ESPs. Live USB-style layouts use a separate ext4 partition; Hamnix
does the same.

### Don't auto-mount via chan_resolve_prefix chaining
`chan_resolve_prefix` does ONE prefix rewrite per `vfs_open` call.
Chaining `bind /usr /n/distros/usr` + `bind /n/distros /ext` won't
double-resolve to `/ext/usr` — the first call only resolves the
outer-most match. Either resolve directly in one bind
(`bind / /ext` is what the linux ns uses) or add an explicit
re-entry loop to `chan_resolve_prefix` (deferred; risky due to cycle
potential).

## Future direction — per-letter file servers (user direction 2026-05-26)

Stub status; tracking work. The current implementation exposes each
discovered ext4 partition as ONE 9P file server reachable via the
`/ext` path-prefix dispatch (kernel-side, fs/vfs.ad). The user
clarified the eventual shape:

> "you plug in a thumb drive and it shows up as a single letter. It
> allows us to split up the default EXT4 file system in logical
> separated ways."
>
> "Let's do it split so that a FS found by the kernel without top
> level #X letters is just a single File server, but if the root
> contains #X hashtag<letter> then it's serves each folder as it's
> own fileserver."

The target design (not yet implemented):

1. **Each discovered ext4 partition = a Plan 9 device letter.** First
   partition is `#A`, second is `#B`, etc. (mirroring how Plan 9 names
   disk devices). The current single-partition path effectively uses
   `/ext` as that letter; this generalises.

### Letter case convention

- **Lowercase** (`#a`..`#z`): used by both **sentinel-derived** servers
  (letter = first char of word) AND built-in kernel devices. Current
  built-in reserved set (verified against `etc/rc.boot`): `#c` console,
  `#p` proc, `#s` srv, `#/` mount-parent. A sentinel entry whose first
  char collides with a reserved letter is REJECTED at parse time.
  When new built-in devices are added, their letters join the reserved
  set — the source of truth is `sys/src/9/port/dev.ad`.
- **Uppercase** (`#A`..`#Z`): reserved for **anonymous** partition
  servers (no sentinel found). Auto-assigned in mount order.

This split eliminates any chance of a sentinel collision with the
built-in kernel device namespace, and gives the user a visual cue at
a glance: `#A` is "the kernel found a partition with no name preference,"
`#h` is "someone deliberately declared this is `home`."

### Single-server mode (no sentinel)

The partition's root has no `.hamnix-roots`. Kernel serves the WHOLE
partition as one anonymous file server, assigned the next free
uppercase letter (`#A`, `#B`, ...). hamsh binds it source-first:

    bind '#A' /n/mydisk

### Multi-server mode (sentinel present)

Partition root carries `.hamnix-roots` listing one or more named
servers. Each line is `<word> <relative-dir>`:

    home    home/
    distro  debian-bookworm/
    cache   var/cache/apt/

Kernel reads the sentinel, derives each server's letter from the
FIRST CHARACTER of `<word>` (lowercase), posts each as a separate
file server: `#h`, `#d`, `#c` in the example… **except** that `#c`
is the built-in console device. The sentinel parser REJECTS the
`cache` entry with a loud kernel log line, accepts `home` (`#h`) and
`distro` (`#d`). To use the cache mount the user picks a non-reserved
first char: `pkgcache` → `#p`? Also reserved (proc). Try `apt-cache`
→ `#a`. Fine.

Reserved letters today (per `etc/rc.boot` + `sys/src/9/port/dev.ad`):
`c p s /`. Everything else is fair game.

hamsh binds each independently (source-first):

    bind '#h' /n/home
    bind '#d' /n/distros
    bind '#a' /var/cache/apt

### Stack semantics on collision

A letter is a NAME that resolves to the top of a per-letter stack of
file servers. Mount pushes; unmount pops.

- Boot with on-disk `home` server → stack `[home_disk]`,
  `#h` resolves to home_disk.
- Hot-plug a USB declaring `home` → stack `[home_disk, usb_home]`,
  `#h` resolves to usb_home (top), `#hh` resolves to home_disk
  (one below top). The user-visible home just switched to the USB.
- Unplug the USB → stack pops to `[home_disk]`, `#h` is home_disk
  again, `#hh` no longer exists. Home is restored.

Three concurrent collisions yield `#h`, `#hh`, `#hhh` (top to bottom).
Pop the top → all letters slide up.

**Stack depth cap: 8** (`#h` through `#hhhhhhhh`). Past that, mount
is refused with a loud kernel log line. 8 is well past any reasonable
hot-plug scenario; the cap is a footgun limit, not a feature limit.

**Already-open fds are unaffected.** They hold direct `Chan`
references. Only NEW lookups (`open("#h/foo")`) resolve through the
current stack top. A process reading from the USB's `/home/me/notes.txt`
keeps reading it even after a NEWER USB takes the `#h` letter — only
freshly-opened paths route to the new top.

### Inspection: `/proc/fs`

Built-in `#p` (proc) exposes a `/proc/fs/` directory. Each letter in
use is a file: `/proc/fs/h`, `/proc/fs/d`, `/proc/fs/A`, etc. Reading
the file dumps the stack, top → bottom, with the source partition
identifier for each entry. Example:

    $ cat /proc/fs/h
    top (#h):  usb stick at /dev/vdb1, sentinel-word `home`, dir `home/`
    `#hh`:     boot rootfs at /dev/vda3, sentinel-word `home`, dir `home/`

This is the only way to answer "what is `#h` actually pointing at
right now" — load-bearing for debugging.

### Sentinel file format (strict)

- Line format: `<word> <relpath>` (single space; trailing newline)
- `<word>`: matches `[a-z][a-z0-9-]{0,31}` (lowercase ASCII; max 32
  chars; first char must be a lowercase letter)
- `<relpath>`: relative to the partition root; must NOT contain `..`;
  must NOT start with `/`; must resolve to a directory inside the
  partition; max 256 chars
- Duplicate `<word>` in the same sentinel: REJECTED (whole sentinel
  refused; log loud)
- First-char collisions between two words on the same partition
  (e.g. `home` + `host`): REJECTED (same reason — ambiguous letter
  assignment within one partition is a bug to fix in the data)
- First-char collides with built-in reserved letter (`c d p s f /`):
  that ENTRY rejected; sibling entries still considered
- Parse error (malformed line, missing column, unknown char):
  reject the WHOLE sentinel, do NOT fall back to single-server mode
  (avoids "silently degraded" mounts)

### hamsh `bind` syntax — source first

The wrapper matches the underlying `SYS_BIND(src, dst, flag)` syscall
and Linux's `mount source target` order. Old `etc/rc.boot` snippets
used the inverted Plan 9-flavored `bind DST SRC`; that's a bug, fixed
tree-wide by the sentinel-discovery agent.

hamsh's `bind` builtin warns LOUDLY if arg2 looks like a device-letter
(`#[a-zA-Z]` or `#[a-zA-Z][a-zA-Z]+`) AND arg1 doesn't — catches
muscle-memory inversions before they silently graft a path onto a
device letter.

## Files involved

- `scripts/build_rootfs_img.py` — stage + mkfs.ext4 the rootfs image
- `scripts/build_iso.sh` — build ISO, append rootfs as partition 3
- `scripts/build_initramfs.py` — `HAMNIX_CPIO_LEAN=1` strips the
                                 cpio's redundant debian copy
- `kernel/block/blk.ad` — `blk_max_slots`, `blk_slot_in_use`,
                          `blk_slot_name` enumeration API
- `init/main.ad` — `mount_rootfs_partition()` autodiscover hook
- `etc/rc.boot` — `bind /n/distros /ext` + `linux = ns clean { bind / /ext; ... }`
- `fs/ext4.ad` — existing reader (already supports extent walks,
                 directories, symlinks, file_create, ftruncate)
- `fs/vfs.ad` — existing `/ext` device-letter dispatch
- `docs/rootfs_partition.md` — this file
