# Rootfs partition — Plan 9-shape, named roots on one ext4

## TL;DR

Hamnix ships a UEFI-only GPT disk image, `build/hamnix.img`, built by
`scripts/build_img.sh`. It has a small FAT ESP (the PE/COFF stub +
kernel ELF) and **one** ext4 partition that holds the entire live
system. That single ext4 carries a `.hamnix-roots` sentinel at its
root with one `<word> <relpath>` line per **named root**:

```
sysroot   sysroot
distro    distro
```

Each line registers a named file server: `#sysroot` (the native Adder
userland) and `#distro` (a minimal Debian). These are **subtrees of
the one ext4** — they share its free space; they are NOT separate
partitions. (Future per-user home roots join the same sentinel and
draw from the same pool.) On install to a real disk the ext4 grows to
fill the disk and every root draws from one common pool. Isolation
between roots comes from the namespace / file-server layer, not from
partitioning.

At boot the kernel auto-discovers the ext4 partition by its 0xEF53
superblock magic, reads `.hamnix-roots`, posts `#sysroot` + `#distro`,
**binds `#sysroot` at `/`**, and ELF-loads `/init` directly off ext4.
The native shell's `/`, `/bin`, `/etc` are therefore served from
`sysroot/` on the partition. The `linux = ns clean { ... }` recipe in
`etc/rc.boot` then binds `#distro` at `/` inside its hermetic
namespace — so:

- The native shell sees `/`, `/bin`, `/etc` served from `sysroot/`.
- The Linux namespace sees `/` served from `distro/`.
- `apt install foo` from inside `enter linux { ... }` lands in the
  `distro/` subtree, NOT in the shell's `sysroot/`-backed paths.

> **Isolation enforced (landed 2026-05-29, commit 7ac3e14).** The
> native (`sysroot/`) and Debian (`distro/`) roots are genuinely
> isolated at the namespace/file-server layer: `enter debian { ... }`
> forks a child with an empty namespace and binds `#distro` at `/`, so
> the Debian subsystem cannot see `sysroot`, and every distro-side
> write composes through the frozen `distro` dir prefix so the bytes
> can only land under `distro/`. The PID-1 boot shell no longer binds
> the distro tree ambiently. Regression-gated by
> `scripts/test_img_distro_isolation.sh` (boots `build/hamnix.img`
> under OVMF and asserts the two roots stay separate across a
> distro-side write).

> **No cpio in the live root.** The shipped image carries a
> trailer-only (empty) cpio (`HAMNIX_CPIO_EMPTY=1`); the live system
> boots entirely off the ext4 root. The in-kernel cpio machinery is
> retained only for the developer `-kernel` test path, which still
> boots from an embedded cpio.

## Historical: why this layout exists (the FAT12 ceiling)

> HISTORICAL background — the original two-medium (ESP + ext4)
> rationale. The current image is a GPT disk (not a hybrid ISO), but
> the reason for keeping the bulk content off the FAT ESP is the same.

Pre-2026-05-26, the kernel ELF embedded a `cpio` initramfs containing
EVERYTHING — userland binaries, real Debian apt/dpkg, busybox, the
distro tree. As real Debian landed, the ELF grew to ~86 MiB, the ESP
had to grow to 128 MiB (with custom mformat geometry) just to hold
the ELF, and the FAT12 spec's 4084-cluster maximum capped the ESP at
~250 MiB regardless of cluster size. OVMF refuses FAT16/FAT32 ESPs.
There was no way to grow past 250 MiB without leaving the ESP.

Linux live USBs solve this with two partitions: a small ESP holding
just the kernel + bootloader, and a separate ext4 partition the
kernel mounts at boot. Hamnix does the same.

## Partition layout (`build/hamnix.img`)

The GPT disk image emitted by `scripts/build_img.sh`:

| # | Type | Contents                                                  |
|---|------|-----------------------------------------------------------|
| 1 | EFI System (ESP, FAT12, ~32 MiB) | native PE/COFF stub @ `\EFI\BOOT\BOOTX64.EFI` + `\hamnix-kernel.elf` |
| 2 | Linux filesystem (ext4, ~512 MiB) | the whole live system, staged by `scripts/build_rootfs_img.py` |

Partition 2 is the single ext4 that backs every named root. It's an
ext4 filesystem with no journal (read-mostly), built via `mkfs.ext4 -d
<staging-dir>` so all bytes are baked at build time. Its top level is:

```text
ext4 partition root
├── .hamnix-roots        (sentinel: sysroot -> sysroot/, distro -> distro/)
├── sysroot/             (native Adder tools + /init + /etc; #sysroot)
└── distro/              (minimal Debian apt/dpkg/busybox closure; #distro)
```

## How the kernel discovers it

At boot, `init/main.ad`'s `start_kernel()` calls
`mount_rootfs_partition()` after `block_smoke_test()`. The function
walks every registered block device (vda from virtio-blk; sd0pN from
AHCI; USB; etc.) and reads its ext4 superblock area. Any device whose
bytes 0x438..0x439 are `53 EF` (little-endian 0xEF53) is mounted via
`ext4_init(slot)`. The kernel then reads the `.hamnix-roots`
sentinel from the partition root (planted by
`scripts/build_rootfs_img.py`) and registers **each** declared entry
in the per-name file-server stack — today `#sysroot` and `#distro`
(also each as `#by-id/<partuuid>` in the persistent alias table).

```text
[rootfs] scanning block devices for ext4 magic
[rootfs] ext4 magic on slot 1 (vda2)
[rootfs] .hamnix-roots: registered #sysroot -> sysroot/
[rootfs] .hamnix-roots: registered #distro -> distro/
```

The kernel then **binds `#sysroot` at `/`** and ELF-loads `/init`
directly off ext4 via a fd-less read path (`_ns_ext4_slurp_by_id` in
`fs/vfs.ad`) — `/init` loads before any user fd table exists. `/init`
execs `/bin/hamsh /etc/rc.boot`, which resolve through the inherited
`#sysroot` bind to `sysroot/` on the partition.

On the developer `-kernel` test path (no disk attached), the kernel
logs `[rootfs] no ext4 partition found` and continues; that path boots
from the embedded cpio root instead (the shipped image never does).

## How userspace exposes it (etc/rc.boot)

The kernel already binds `#sysroot` at `/`, so the native shell's
`/`, `/bin`, `/etc` come from `sysroot/` on the partition. The
bootstrap rc re-asserts that bind (idempotent) and `source`s the full
boot rc off the partition.

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

## The isolation model (user direction 2026-05-26)

> "the mounts a linuxname space uses is just diffrent mounts from
> the init system on a clean ns. isolating the software int he
> linuxname space from the normal shell/init crated mounts. AKA
> installing via apt only lands in the linux ns/file servers and the
> shells root view is uneffected."

**What apt sees**: a `/` served from the `distro/` subtree (`#distro`)
of the ext4. Writes go to `/usr/bin/<X>` etc. within that subtree.

**What the native shell sees**: a `/` served from the `sysroot/`
subtree (`#sysroot`) of the same ext4. The Debian tree is a *different
named root* on the same partition; the linux ns binds it at `/` only
inside its `ns clean` recipe, so it doesn't appear in the shell's `/`.

This is Plan 9's namespace model: two named file servers (`#sysroot`,
`#distro`) backed by subtrees of one ext4, bound at different paths in
different namespaces, with clean isolation when you start with
`ns clean { ... }`.

> Both subtrees share the one ext4's free space — they are not
> separate partitions. **Confinement of distro-side writes (apt/dpkg)
> to within `#distro` is enforced** as of commit 7ac3e14: every write
> composes through the frozen `distro` dir prefix, so it can only land
> under `distro/` and never touches `sysroot/`. See
> `scripts/test_img_distro_isolation.sh`.

## How to grow the rootfs

`scripts/build_img.sh` ships ~512 MiB of ext4
(`HAMNIX_ROOTFS_SIZE_MB`, default 512); the first-boot resize hook
grows it to fill the disk on a real install. When building the rootfs
image directly, the size is auto-picked by
`scripts/build_rootfs_img.py` (staging bytes + ~96 MiB headroom). To
force a specific size:

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

## How to skip it (the developer `-kernel` test path)

The ~380 kernel test scripts use QEMU's `-kernel ELF` mode (via the
`scripts/_kernel_iso.sh` / `scripts/run_x86_bare.sh` shim), which loads
the kernel ELF directly without attaching a disk. That path STILL boots
from an embedded cpio root (the cpio machinery is retained for exactly
this reason). For those:

1. Build the cpio with the full debian closure (the `-kernel` path
   default): no env var needed. (`build_img.sh` instead sets
   `HAMNIX_CPIO_EMPTY=1` for the shipped image.)
2. The kernel's `mount_rootfs_partition()` walk finds no ext4 partition
   and logs the skip; the namespace falls back to the cpio root.
3. Tests that need apt/dpkg either (a) attach the rootfs.img as
   `-drive file=build/hamnix-rootfs.img,if=virtio,format=raw` so the
   ext4 is present, OR (b) keep using the in-cpio fallback
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

### Don't bind the `distro/` subtree into the init namespace's `/`
The init namespace's `/` is served from `#sysroot` (the native Adder
userland). The `distro/` Debian subtree (`#distro`) must only be bound
at `/` inside the `ns clean { ... }` linux recipe — NOT in the init
Pgrp. If `#distro` were bound at `/` or `/usr/bin/` in the init Pgrp,
the shell's own binaries would be shadowed by the Debian tree's
binaries. Keeping `#sysroot` as the init `/` and overlaying `#distro`
only inside the linux ns is what keeps the two roots separated.
(Note: both are subtrees of one ext4 sharing free space; this is
namespace separation, not filesystem-level confinement — the latter
is a separate in-flight change.)

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

### Stable instance identity — `#by-id/<partuuid>` (also = raw root)

Persistent references use a stable alias. Every discovered partition
is also addressable as `#by-id/<GPT-partition-UUID>`, mirroring
Linux's `/dev/disk/by-id/`. This name NEVER moves: it's bound to the
on-disk identifier, not the discovery order or the sentinel word.

**The `#by-id/<partuuid>` chan is ALWAYS the raw partition root**,
regardless of what the partition's sentinel declares. This is a
deliberate dual-view design (user direction 2026-05-26):

- The sentinel describes *named overlays* on the partition
  (`#distro` = `debian-bookworm/`, `#home` = `home/`, etc.). These
  are the convenience views applications bind.
- The by-id chan is the *underlying drive root* — the partition's
  actual `/`. Mount it to see everything on the disk, including the
  sentinel file itself.

This is what makes the sentinel editable in place:

    bind '#by-id/abc-def-123' /n/raw
    cat /n/raw/.hamnix-roots                   # inspect current sentinel
    echo "userdata home/me/" >> /n/raw/.hamnix-roots   # add an entry
    # next boot, #userdata will appear as a new named server

Persistent recipes (e.g. an installed system's `/etc/fstab`-shape
config, a script that always wants a specific disk) SHOULD use the
by-id alias:

    bind '#by-id/12345-abcdef' /n/mydisk

Positional names (`#home`, `#part0`) are for INTERACTIVE / NEW
mounts where the user means "whatever the current top is." Scripts
and configs that need stability use by-id. Recovery / sentinel-edit
workflows use by-id for the raw view.

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

- `scripts/build_rootfs_img.py` — stage `sysroot/` + `distro/` and
                                 mkfs.ext4 the rootfs image; plant
                                 `.hamnix-roots` (`sysroot` + `distro`)
- `scripts/build_img.sh` — assemble the GPT disk image (FAT ESP +
                          ext4 partition) → `build/hamnix.img`
- `scripts/build_iso.sh` — DEPRECATED thin shim; delegates to
                          `build_img.sh`
- `scripts/build_initramfs.py` — `HAMNIX_CPIO_EMPTY=1` emits a
                                 trailer-only cpio for the shipped image
                                 (the kernel still links the cpio symbol)
- `scripts/test_img_uefi_boot.sh` — OVMF acceptance gate: boots
                                 `build/hamnix.img` as a disk
- `kernel/block/blk.ad` — `blk_max_slots`, `blk_slot_in_use`,
                          `blk_slot_name` enumeration API
- `init/main.ad` — `mount_rootfs_partition()` autodiscover hook; binds
                  `#sysroot` at `/` and ELF-loads `/init` off ext4
- `etc/rc.boot` — re-asserts `bind '#sysroot' /` (idempotent) +
                  `linux = ns clean { bind '#distro' / ; ... }`
- `fs/vfs.ad` — `_ns_ext4_slurp_by_id` (fd-less ext4 read for `/init`);
                legacy `/ext` device-letter dispatch (kept for older
                tests); the primary path is `chan.ad`'s named stack
- `fs/ext4.ad` — reader (extent walks, directories, symlinks,
                 file_create, ftruncate)
- `docs/rootfs_partition.md` — this file
