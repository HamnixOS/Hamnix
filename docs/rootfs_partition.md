# Rootfs partition — Plan 9-shape, two-medium layout

## TL;DR

Hamnix's ISO carries the kernel ELF on a small ESP and a separate
ext4 partition (`/dev/...p3` on the live medium) for the bulk of
distro content (real Debian apt/dpkg, busybox, future user data).
At boot the kernel auto-discovers the ext4 partition, reads its
`.hamnix-roots` sentinel for the name (today: `distro`), and
registers it in the named file-server stack as `#distro`.
Userspace `etc/rc.boot` then `bind`s `'#distro'` at `/n/distros`
in the init namespace and at `/` inside the
`linux = ns clean { ... }` recipe — so:

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
AHCI; etc.) and reads its ext4 superblock area. Any device whose
bytes 0x438..0x439 are `53 EF` (little-endian 0xEF53) is mounted via
`ext4_init(slot)`. The kernel then reads the `.hamnix-roots`
sentinel from the partition root (planted by
`scripts/build_rootfs_img.py`) for the named-stack registration —
today that file names the partition `distro`, so it lands as
`#distro` in the per-name file-server stack (also as
`#by-id/<partuuid>` in the persistent alias table).

```text
[rootfs] scanning block devices for ext4 magic
[rootfs] ext4 magic on slot 1 (vda3)
[rootfs] mounted ext4 rootfs (slot=1, registered as #distro via .hamnix-roots sentinel)
```

If no ext4 partition is found (e.g. `-kernel ELF` boot with no
rootfs disk attached), the kernel logs `[rootfs] no ext4 partition
found` and continues. The init namespace falls back to cpio-only;
the `linux = ns clean { bind '#distro' / ; ... }` recipe will see
`'#distro'` resolve to nothing and `enter linux { ... }` will fail
with `-ENOENT` (use `HAMNIX_CPIO_LEAN=0` to ship the full cpio
fallback).

## How userspace exposes it (etc/rc.boot)

The init namespace `bind`s `'#distro'` at `/n/distros` so the
**shell has read/write access** to the partition's free space:

```hamsh
bind '#distro' /n/distros
```

The shell can:
- `cat /n/distros/usr/bin/dpkg` — read the real Debian dpkg
- `cat > /n/distros/home/me/myfile` — write user files to the partition

The Linux namespace recipe `bind`s `'#distro'` at `/` inside the
**isolated linux ns** (it's `ns clean`, a fresh empty Pgrp):

```hamsh
linux = ns clean {
    bind '#distro' /
    bind /home /home
    bind '#c' /dev
    ...
}
```

Inside `enter linux { /usr/bin/dpkg }`, the path `/usr/bin/dpkg`
resolves through the linux ns mtab to the rootfs partition's ext4
lookup.

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
A bind chain like `bind /usr /n/distros/usr` + `bind '#distro' /n/distros`
won't double-resolve — the first call only resolves the outer-most
match. Either resolve directly in one bind (`bind '#distro' /` is
what the linux ns uses) or add an explicit re-entry loop to
`chan_resolve_prefix` (deferred; risky due to cycle potential).

## Per-name file servers — shipped 2026-05-26

The original sketch in this section was "exposing each discovered
ext4 partition as ONE 9P file server reachable via the `/ext`
path-prefix dispatch." That earlier shape is preserved for legacy
paths in `fs/vfs.ad` (`/ext/HELLO.TXT` continues to resolve via
`is_ext_path`), but the **primary path is now per-named file
servers in `sys/src/9/port/chan.ad`**: each ext4 partition declares
its name in a `.hamnix-roots` sentinel and lands in the
per-name stack as `#<word>` (today: `#distro`), plus the persistent
`#by-id/<partuuid>` alias. The sections below were written as the
design and have shipped.

The user's original direction:

> "you plug in a thumb drive and it shows up as a single letter. It
> allows us to split up the default EXT4 file system in logical
> separated ways."
>
> "Let's do it split so that a FS found by the kernel without top
> level #X letters is just a single File server, but if the root
> contains #X hashtag<letter> then it's serves each folder as it's
> own fileserver."

The target design (not yet implemented):

### Bind freeze semantics (gates everything below)

**`bind '#home' /n/home` snapshots the Chan at bind time. Future
walks through `/n/home` use the stored Chan directly; they do NOT
re-resolve `#home` per walk.** This is plain Plan 9 chan.c behavior
and applies whether the source is a built-in (`#c`) or sentinel-
derived (`#home`). Consequence: a running namespace's home directory
cannot be yanked out from under it by a USB plug-in. The stack
machinery below is therefore **debug-introspection only** —
visible at `/proc/fs/` but never the persistent route for a bound
path. Only fresh `bind '#home' ...` calls (at boot, in rc.boot, or
typed at the shell) re-consult the stack.

### Allocation models (two, explicit, no case-as-marker)

| Model | Trigger | Naming scheme | Stack behavior |
|-------|---------|---------------|----------------|
| **Anonymous** | partition has no `.hamnix-roots` sentinel | `#part0`, `#part1`, `#part2`, … (sequential by discovery order) | none — sequential names never collide |
| **Named** | partition has a sentinel | `#<word>` per sentinel entry (e.g. `#home`, `#distro`, `#apt-cache`) | LIFO stack on collision between partitions; depth cap 9 |

The `#` parser MUST accept both single-char built-in letters (`#c`,
`#p`, `#s`, `#/`) and multi-char role names (`#home`, `#distro`,
`#part0`). Disambiguation is by lookup: built-ins live in
`sys/src/9/port/dev.ad`; named/anonymous mounts live in the
per-name stack table.

No case-as-channel-class convention. The shape of the name (single
char vs word; built-in vs registered) does the discrimination
without relying on case.

### Sentinel file (`.hamnix-roots`)

Plain text, one entry per line, `<word> <relpath>`:

    home    home/
    distro  debian-bookworm/
    apt-cache var/cache/apt/

Kernel parses, registers each as `#<word>` in the named stack. No
first-char derivation; the FULL word is the device name. Three
distinct roles → three distinct names → no shared stack between
them. The previous design where `home` and `host` would both want
`#h` simply cannot arise.

**Reserved words** = the built-in device-letter set today: `c`, `p`,
`s`, `/`. A sentinel entry naming one of these is rejected at parse
time (the entry, not the whole sentinel). Long-form built-ins added
later (e.g. `#console` as a verbose alias) join the reserved set
in `sys/src/9/port/dev.ad`.

**Sentinel format (strict):**
- Line format: `<word>` `WS` `<relpath>` (any whitespace; trailing newline)
- `<word>`: matches `[a-z][a-z0-9-]{0,31}` (lowercase ASCII; max 32 chars)
- `<relpath>`: relative to the partition root; must NOT contain `..`;
  must NOT start with `/`; must resolve to a directory inside the
  partition; max 256 chars
- Duplicate `<word>` in the same sentinel: REJECTED (whole sentinel
  refused; log loud)
- `<word>` collides with a built-in reserved word: that ENTRY rejected;
  sibling entries still considered
- Parse error (malformed line, missing column, unknown char):
  reject the WHOLE sentinel, do NOT fall back to anonymous mode
  (avoids "silently degraded" mounts)

### Stack semantics — true duplicates only

After full-word names, the only stack collision is two physical
devices both shipping `home` in their sentinels. Behavior:

- Boot with on-disk `home` server → stack `[home_disk]`,
  `#home` resolves to home_disk at bind time.
- Hot-plug USB also declaring `home` → stack `[home_disk, usb_home]`,
  `#home` resolves to usb_home on NEXT bind. **Existing `bind '#home' ...`
  bindings DO NOT MOVE.** Frozen at bind time, per the freeze rule above.
- A FRESH `bind '#home' /n/usb-home` after the push picks the new top.
- Unplug the USB → stack pops to `[home_disk]`, future fresh binds
  pick home_disk again.

**Positional names** for the deeper-than-top entries: `#home`, `#home2`,
`#home3`, …, up to `#home9`. Suffix is the position from top (1 is
implicit at the bare name; 2 is the second-from-top; etc.). **These
names are LIFO and unstable** — they slide as the stack changes.
They exist for `/proc/fs/` introspection and explicit `bind` of a
non-top entry. They are NOT the recommended persistent reference.

**Stack depth cap: 9** (top + 8 deeper). Past that: reject loudly,
log the refusal, do NOT evict the bottom. Eviction would orphan a
name while the underlying Chan stays alive in any already-bound
namespace — a silent-data-corruption category footgun.

### Stable instance identity — `#by-id/<partuuid>`

Persistent references use a stable alias. Every discovered partition
is also addressable as `#by-id/<GPT-partition-UUID>`, mirroring
Linux's `/dev/disk/by-id/`. This name NEVER moves: it's bound to the
on-disk identifier, not the discovery order or the sentinel word.

Persistent recipes (e.g. an installed system's `/etc/fstab`-shape
config, a script that always wants a specific disk) SHOULD use the
by-id alias:

    bind '#by-id/12345-abcdef' /n/mydisk

Positional names (`#home`, `#part0`) are for INTERACTIVE / NEW
mounts where the user means "whatever the current top is." Scripts
and configs that need stability use by-id.

### Inspection: `/proc/fs`

Built-in `#p` (proc) exposes `/proc/fs/`. Files:

- `/proc/fs/by-name/<word>` — dumps the stack for that named slot
  (top → bottom; each line = position, partuuid, sentinel word, dir)
- `/proc/fs/by-id/<partuuid>` — dumps the partition identity record
  (which named slots it occupies, which position in each)
- `/proc/fs/anonymous` — lists `#partN` → partuuid mappings

Example:

    $ cat /proc/fs/by-name/home
    1 (#home):   partuuid=ABCD-EFGH  sentinel=`home`  dir=`home/`
    2 (#home2):  partuuid=1234-5678  sentinel=`home`  dir=`home/`

    $ cat /proc/fs/by-id/ABCD-EFGH
    partition=ABCD-EFGH  device=/dev/vdb1
    serves: home (position 1 = #home)

### hamsh `bind` syntax — source first

The wrapper matches the underlying `SYS_BIND(src, dst, flag)`
syscall. **Both Linux's `mount source target` AND Plan 9's
`bind new old` are source→target** — so there is no "Plan 9 style"
inversion to apologise for; old `etc/rc.boot` snippets like
`bind /srv '#s'` were just a plain bug in the hamsh wrapper that
fed args to the syscall in the wrong order.

hamsh's `bind` builtin warns LOUDLY if arg2 starts with `#` AND
arg1 does NOT — catches muscle-memory inversions before they
silently graft a path onto a device name.

### Migration impact (shipped, 2026-05-26 wave)

This design touched, all shipped:
- Hamsh `bind` wrapper (arg order flip + multi-char `#<word>` parser
  + inversion warning) — `6f2c3cb`
- Hamsh `#` lexer (accept multi-char names, not just single chars) —
  same wave
- `sys/src/9/port/chan.ad` (named-stack table; by-id alias table;
  bind-freeze of named sources via `_freeze_named_source`) —
  `5e9c086`, `98ea65a`, `bc1000e`, `5a40d60`
- `sys/src/9/port/dev.ad` (reserved-word query `is_reserved_word`) —
  `a46dc4b`
- `init/main.ad` (`mount_rootfs_partition()` walks sentinels and
  registers named or anonymous mounts) — `8e5a712`
- `fs/ext4.ad` (sentinel reader from the partition root) — same wave
- `etc/rc.boot` (`bind '#distro' /n/distros` etc., tree-wide flip) —
  `aa8c684`
- `scripts/build_rootfs_img.py` (plants `.hamnix-roots` with
  `distro <relpath>`) — `bea976c`
- `#p` (proc) `/proc/fs/{by-name,by-id,anonymous}` introspection —
  `5182d03`

## Files involved

- `scripts/build_rootfs_img.py` — stage + mkfs.ext4 the rootfs image,
                                 plant `.hamnix-roots`
- `scripts/build_iso.sh` — build ISO, append rootfs as partition 3
- `scripts/build_initramfs.py` — `HAMNIX_CPIO_LEAN=1` strips the
                                 cpio's redundant debian copy
- `kernel/block/blk.ad` — `blk_max_slots`, `blk_slot_in_use`,
                          `blk_slot_name` enumeration API
- `init/main.ad` — `mount_rootfs_partition()` autodiscover hook
- `etc/rc.boot` — `bind '#distro' /n/distros` + `linux = ns clean { bind '#distro' / ; ... }`
- `fs/ext4.ad` — existing reader (already supports extent walks,
                 directories, symlinks, file_create, ftruncate)
- `fs/vfs.ad` — legacy `/ext` device-letter dispatch (kept for older
                tests); the primary path is now `chan.ad`'s named stack
- `docs/rootfs_partition.md` — this file
