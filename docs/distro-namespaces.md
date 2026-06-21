# Distro-shape namespaces

**Imported-binary personalities via per-process Layer-1 namespaces.**

> **Status:** the architectural design described here is shipped. The
> live recipe is in [`/etc/rc.boot`](../etc/rc.boot) — `linux = ns clean
> { bind '#distro' / ; bind /home /home; bind '#c' /dev ; … }` (plus a
> duplicate-body `debian` alias). The `ns clean { … }` modifier (see
> [`HAMSH_SPEC.md`](HAMSH_SPEC.md) §13) is what makes
> `enter linux { … }` hermetic. This doc captures the design
> rationale; the shipped recipe is the source of truth for the
> binding list.
>
> **2026-05-26 update — rootfs migration to a separate partition.**
> The distro backing store is no longer baked into the kernel ELF's
> cpio. It lives on a separate ext4 partition (`/dev/...p3` on the
> ISO; vda on the QEMU `-drive` path), which the kernel auto-
> discovers at boot via a `.hamnix-roots` sentinel and registers in
> the per-name file-server stack as `#distro`. The init namespace
> `bind '#distro' /n/distros` so the shell sees the partition at
> `/n/distros/`. The linux ns recipe uses `bind '#distro' /` so the
> linux ns sees it as `/`. apt writes are visible to the shell at
> `/n/distros/usr/bin/...`, NOT at `/usr/bin/...` (which stays
> Hamnix-native cpio). See
> [`rootfs_partition.md`](rootfs_partition.md).

In Hamnix, as in Plan 9, there is no global root. The kernel knows
about file servers — disk filesystem drivers, kernel device drivers,
9P servers. A namespace is a per-process binding of paths to those
servers. Init's namespace is constructed at boot from a kernel-default
set of mounts (hamnixfs at /, devcons at /dev/cons, etc.); every
subsequent process inherits its parent's namespace and can modify its
own copy with `bind` / `mount` / `unmount` / `rfork(RFNAMEG)`.

A **distro-shape namespace** is a namespace assembled to look like a
particular Linux distribution. From inside it, paths resolve to a
Debian / Ubuntu / SUSE / etc. backing store: `/bin/bash`,
`/lib/x86_64-linux-gnu/libc.so.6`, `/etc/passwd` in Debian's format.
It is **not different in kind** from init's namespace — both are just
namespaces. The convention that init mounts hamnixfs at `/` is a
choice the boot scripts make, not a privileged property of the kernel.
A user could legitimately boot Hamnix and immediately replace init's
`/` mount with a remote 9P export — that's a valid configuration,
not an escape from anything.

Imported Linux binaries (apt, dpkg, postgresql, python3) run inside
distro-shape namespaces because that's the namespace shape they
expect. Native Adder binaries (hamsh, the init system, sshd, the
Hamnix-native package manager `hpm`) run inside init's default
namespace because that's the namespace shape *they* expect. Neither
is the "real" /; they're peer namespaces.

**Anti-pattern alert (load-bearing):** if a tool's job is
"manage Debian packages" or "extract a .deb" or "fetch with curl,"
**it is a Linux userland tool — run real Debian from inside the
Linux namespace. Do NOT write an Adder reimplementation of it.**
We did this once with `user/apt.ad` + `user/dpkg.ad` + `user/
dpkg_deb.ad`, spent months, and deleted all three (2026-05-26,
commits `0de1c63`..`3ff5bfc`) once `enter linux { /usr/bin/apt }`
worked. See [`architecture.md` § "What runs where"](architecture.md)
for the full rule. The native Hamnix package manager (`hpm`,
shipped) is NOT a substitute for apt — it manages **Hamnix-side**
services and state in the DEFAULT namespace, not distro packages.
See [`packages.md`](packages.md) for the `hpm` spec.

## Layout

Two example namespaces a user-facing process might inhabit. The
"Default init namespace" column is the namespace `/etc/rc` builds at
boot; the "Debian-shape namespace" column is what `distrorun debian-trixie`
constructs.

| Path | Default init namespace | Debian-shape namespace |
|------|------------------------|------------------------|
| /bin | hamnixfs — Adder binaries (hamsh, ls, ps, cat, ...) | distro backing — Debian binaries (bash, ls, apt, dpkg, ...) |
| /lib | hamnixfs — minimal Adder runtime support | distro backing — `/lib/x86_64-linux-gnu`, glibc, ld-linux-x86-64.so.2 |
| /usr | hamnixfs — minimal | distro backing — full Debian /usr (share, lib, bin, ...) |
| /etc | hamnixfs — Hamnix config (motd, passwd, group, rc, os-release) | distro backing — Debian config (debian_version, apt/, dpkg/, ld.so.cache, ...) |
| /var | hamnixfs — minimal | distro backing — Debian /var (lib/dpkg, log, cache/apt, ...) |
| /home/$user | shared bind (same file server in both) | shared bind (same file server in both) |
| /net | ipd 9P server (same in both) | ipd 9P server (same in both) |
| /srv | srvfs 9P server (same in both) | srvfs 9P server (same in both) |
| /dev | kernel cdev family (same in both) | kernel cdev family (same in both) |
| /proc | kernel proc family — pids are global per Plan 9 (same in both) | kernel proc family (same in both) |

Note that `/bin`, `/lib`, `/usr`, `/etc`, `/var` resolve to different
file servers in each namespace; `/home`, `/net`, `/srv`, `/dev`,
`/proc` resolve to the same servers in both (via shared `bind`).

## Boundary rules

1. **No file server is privileged.** hamnixfs is a file server.
   /var/lib/distros/debian-trixie/ (mounted via a disk filesystem
   driver on whatever block device holds it) is a file server. A
   process binding either at `/` is doing the same kind of thing.
   The kernel doesn't distinguish "the real root" from "a chroot."
2. **Distro-shape namespaces have no init.** A namespace is a
   workspace for running individual binaries (or an interactive
   bash shell), not a parallel system. Hamnix's service management
   stays in init's namespace (hamsh + /etc/rc), which can launch a
   Linux service *into* a distro-shape namespace when needed.
3. **`apt` and `dpkg` mount their package state in their own
   namespace.** They write to /var/lib/dpkg, /etc/apt, /usr/lib/* —
   all of which, in their namespace, resolve to the distro backing
   store. Init's namespace is untouched not because it's protected
   but because nothing in the apt namespace binds anything to it.
4. **Multiple distro-shape namespaces coexist trivially.**
   /var/lib/distros/debian-bookworm/, debian-trixie/, ubuntu-noble/,
   suse-tumbleweed/ each back a different namespace shape; processes
   pick which one to inherit at namespace-construction time.
5. **Cross-namespace IPC is via shared file servers.** /srv (9P) and
   /net (ipd's sockets) are bound by convention in every namespace
   from the same servers. A Debian-shape postgres talks to a native
   Adder service through /srv/postgres or /net/tcp the same way two
   native services would.
6. **Distro-shape namespaces are NOT a security boundary.** They
   change which file servers serve which paths, not what a process
   is allowed to do. A process inside a Debian-shape namespace is
   exactly as privileged as it would be in init's namespace. For
   privilege isolation, layer additional namespace restrictions on
   top (e.g., `bind -c` on /dev to drop access to specific cdevs).

## Backing stores

Two implementations, in order of expected build:

1. **Disk-backed (debootstrap path).** /var/lib/distros/debian-trixie/
   is a real Debian rootfs extracted via `debootstrap` (run once on a
   host Linux box, copied onto a Hamnix-mounted disk). The disk
   filesystem driver — ext4, fat — is the file server. Entered with
   `mount` at the namespace's `/` after `rfork(RFNAMEG)`. Heavy but
   works immediately.
2. **`debfs` 9P server (deferred).** A Layer 3 service that
   synthesizes Debian's FHS layout on demand from a package store
   (.deb archives or pre-extracted contents in object-storage form).
   Lighter, composable, more Plan 9. Build after Phase F when Layer 3
   services are routine.

## Entry point

There is no dedicated `distrorun` / `deb` / `ubuntu` binary —
running a Linux binary is plain hamsh namespace verbs against a
captured `ns clean { ... }` template. The historical `distrorun`
proposal in the early drafts of this doc was retired before any
binary was shipped; `etc/rc.boot` defines `linux` (and `debian`
as a duplicate body) as `ns clean { ... }` templates and the
shell `enter`s them:

```
hamsh$ enter linux { /usr/bin/apt --version }
hamsh$ enter debian { /bin/cat /etc/debian_version }
hamsh$ svc = spawn linux { /usr/bin/postgres }   # detached
```

The current live recipe (from `etc/rc.boot`):

```hamsh
linux = ns clean {
    bind '#distro' /        # rootfs partition becomes /
    bind /home /home        # keep user files
    bind '#c' /dev          # console + cdev family
    bind '#p' /proc         # per-task proc
    bind '#s' /srv          # 9P registry
    bind '#/' /n            # mount-point parent
    bind /tmp /tmp          # scratch
}
```

The first bind grafts the rootfs partition's file server (registered
as `#distro` via the `.hamnix-roots` sentinel — see
[`rootfs_partition.md`](rootfs_partition.md)) at `/`. The remaining
binds re-expose the shared file servers inside the new namespace
(without them, `/dev/cons`, `/srv/...`, `/home/david` would all
resolve to whatever the distro backing happens to ship for those
paths — typically nothing useful).

### Interactive shell — `enter linux { sh }`

`enter linux { sh }` (bare `sh`, no `-c`) drops you into an
**interactive** shell inside the Linux namespace: the shell's
`stdin/stdout/stderr` are wired to the controlling terminal (the
console line discipline cooks + echoes keystrokes, #164), and the
hamsh that launched it BLOCKS in `waitpid` until the guest shell
`exit`s — a genuine context switch into the Linux ns and back. You can
run commands (`ls /`, `cat /etc/debian_version`, …) and `exit`
returns to hamsh.

For this to work `#distro` must actually CONTAIN a runnable `/bin/sh`.
Two shells are staged into the distro tree
(`/var/lib/distros/default/`) by `scripts/build_initramfs.py`
(in-cpio) and `scripts/build_rootfs_img.py` (on the ext4 rootfs
image):

* **busybox** (`tests/u-binary/u_busybox_musl`, a musl static-PIE
  ET_DYN with no `PT_INTERP`) — planted at `/bin/busybox` with applet
  symlinks (`/bin/sh`, `/bin/ls`, `/bin/cat`, …). This is the
  guaranteed-runnable shell: `enter linux { sh }` resolves `/bin/sh →
  busybox` and runs it. The Hamnix ELF loader runs static-PIE images
  directly.
* **the genuine Debian dash (+ bash)** — `usr/bin/dash` (the real
  Debian `/bin/sh`) is staged from
  `tests/distros/debian-minbase/rootfs/` via the curated
  `REAL_DEBIAN_FILES` list (with a `/bin/dash` usrmerge alias) into
  BOTH the in-cpio slice and the ext4 rootfs image. `usr/bin/bash`
  (plus `libtinfo.so.6`) is heavier (~1.2 MB) so it is staged ONLY into
  the ext4 rootfs image (`build_rootfs_img.py`), keeping it off the
  RAM-constrained in-cpio `-kernel` boot. These are DYNAMIC ELFs
  (`PT_INTERP = /lib64/ld-linux-x86-64.so.2`); running them exercises
  the dynamic loader / `ld.so` + glibc relocation path. Reach them
  explicitly with `enter linux { /bin/dash }` / `enter linux {
  /bin/bash }`.

**Command resolution** (`spawn_resolved` in `user/hamsh.ad`). A body
command without a `/` is resolved by (1) walking the active namespace's
`$PATH` (colon-separated; the `enter` body inherits the launching
shell's `PATH=/bin:/sbin:/usr/bin`), then (2) a static-prefix fallback
(`/bin/`, `/sbin/`, `/usr/bin/`, `/usr/sbin/`) for a hermetic namespace
that seeded no env. So `enter linux { sh }` finds `/bin/sh` and
`enter linux { bash }` finds `/usr/bin/bash` (Debian usr-merge) without
the call site spelling out a path. A command WITH a `/`
(`enter linux { /bin/dash }`) is taken verbatim.

**Verified (busybox):** `enter linux { sh }` against the busybox
fixture drops into the `/ #` prompt, accepts typed commands over the
terminal (`echo`, `cat /PROVENANCE`, `ls /` all run inside the
`#distro` root), and `exit` returns to hamsh. Gated by
`scripts/test_enter_linux_sh_interactive.sh`.

**The two `code=127` failure modes** (the "`enter linux {sh}` exits
127" symptom) are distinct:

1. **Resolution miss** — if NO shell is staged at all,
   `/var/lib/distros/default/bin/sh` does not exist, every resolution
   candidate `-ENOENT`s, and `spawn()`'s child `sys_exit(127)`s. Cured
   by always staging at least one runnable shell (busybox is the
   guaranteed one).
2. **Shared-library load failure** — the DYNAMIC Debian `/bin/sh`
   (dash) and `/bin/bash` resolve and `sys_execve_env` maps `ld.so`
   (you see the `[aslr] interp bias` line), but `ld.so`/glibc
   relocation can still fail and the process exits 127 before printing
   a prompt. That is the linux_abi `mmap` / shared-object track, NOT a
   hamsh-resolution defect — busybox (static-PIE, no `PT_INTERP`)
   sidesteps it, which is why busybox `sh` is the interactivity gate.

## Stock-Debian binary coverage

With version-agnostic lib staging (the `lib*.so*` glob, see
[Shared-object loading](#shared-object-loading-ldso-mmap-path)) and the
recursive `PT_INTERP` loader, a broad set of REAL Debian ELFs run
unmodified inside `enter linux { … }` and produce correct output:

| Binary | NEEDED closure | Status |
| --- | --- | --- |
| `/bin/dash` (`/bin/sh`) | `libc` | runs |
| `/bin/bash` | `libtinfo`, `libc` | runs (`$BASH_VERSION` prints) |
| `/bin/cat`, `/bin/ls`, `/usr/bin/wc`, `/usr/bin/sort`, `/usr/bin/head` | `libc` (+`libselinux`/`libpcre2`/`libacl` for some) | run |
| `/usr/bin/dpkg`, `/usr/bin/dpkg-deb`, `/usr/bin/dpkg-query` | `libmd`, `libz`, `liblzma`, `libzstd`, `libbz2`, `libselinux`, `libc` | run |
| `/usr/bin/apt`, `/usr/bin/apt-get` | `libapt-pkg`, `libapt-private`, `libstdc++`, `libsystemd`, `libcrypto`, … | run |
| `/usr/bin/tar`, `/bin/gzip` | `libacl`, `libselinux`, `libc` | run (dpkg unpack forks them) |

`dash` carries the same `libc`-only closure dpkg does, so it ran as soon
as dpkg did; `bash` only additionally needs `libtinfo.so.6`, which the
`lib*.so*` glob stages automatically. There was no remaining shared-object
mmap gap to fix for the shells — the version-agnostic glob is what closed
it. The sweep is gated by `scripts/test_linux_debian_coverage.sh` (Part A).

## Offline package install (`apt-get install` / `dpkg -i`)

The Linux namespace has **no routed network** to `deb.debian.org`, so real
package installation is proven against a **local `file://` apt repo**
staged inside the Debian root by `scripts/build_local_apt_repo.sh`:

```
/opt/localrepo/
    pool/main/h/hamhello/hamhello_1.0_amd64.deb
    dists/local/main/binary-amd64/Packages(.gz)
    dists/local/Release
/etc/apt/sources.list.d/local.list   ->  deb [trusted=yes] file:///opt/localrepo local main
/var/cache/apt/archives/hamhello_1.0_amd64.deb   (copy for the dpkg -i short path)
```

`hamhello` is a dependency-free leaf whose installed program
`/usr/bin/hamhello` prints the unique marker
`HAMHELLO_INSTALLED_AND_RAN_OK`. Two install paths are exercised:

```hamsh
hamsh$ enter linux { /usr/bin/apt-get update }
hamsh$ enter linux { /usr/bin/apt-get install -y --no-download hamhello }
hamsh$ enter linux { /usr/bin/hamhello }            # -> HAMHELLO_INSTALLED_AND_RAN_OK
```

The `apt-get install` fork chain is `apt-get → /usr/lib/apt/methods/file`
(fetch the `.deb` off the repo) `→ dpkg --unpack → dpkg-deb (→ tar →
gzip) →` coreutils (`rm`/`mv`/`cp`/`mkdir`/`chmod`/…) for the filesystem
install. The shorter `dpkg -i` path (`dpkg → dpkg-deb → tar → gzip`) is
exercised as an independent fallback:

```hamsh
hamsh$ enter linux { /usr/bin/dpkg -i /var/cache/apt/archives/hamhello_1.0_amd64.deb }
hamsh$ enter linux { /usr/bin/hamhello }            # -> HAMHELLO_INSTALLED_AND_RAN_OK
```

Both the install closure (apt `file`/`copy` methods, dpkg helpers,
`tar`/`gzip`, the coreutils set, `bash`) and the localrepo subtree are
staged into the `-kernel` cpio by `build_initramfs.py`'s
`REAL_DEBIAN_FILES` slice; the installer-image live `#distro`
FULL-mirrors the whole fixture (`build_rootfs_img.py`), so the repo rides
into that path automatically (the `var/cache` copy is pruned there, but
the pool `.deb` the apt path needs is kept). Per the **MINIMAL** mandate
the base tree stays debootstrap-minbase — `apt-get install` from the local
repo is the on-demand add path, not a fat golden image.

Regenerate the repo on any host that has run `BUILD.sh`:

```sh
bash scripts/build_local_apt_repo.sh   # idempotent; needs dpkg-deb + gzip
```

## Phase placement

Depends on Phase C (rfork RFNAMEG + bind + mount syscalls). Lands as
**Phase C.5: distro-shape namespaces** — after Phase C's primitives
work, before Phase D's hamwd, since hamwd isn't on the critical path
for server workloads.

## Why this shape

- **There's no "Hamnix vs. Debian" rivalry at the kernel level.**
  hamnixfs is one file server. A Debian rootfs on disk is another.
  Both are equally "real" to the kernel. The OS isn't a Hamnix-Debian
  hybrid; it's a kernel that lets each process pick a namespace shape.
- **`apt install` is naturally scoped.** Package managers do their
  filesystem mutations on whatever file server backs their namespace's
  /. That happens to be the distro backing store. Removing a distro
  is `rm -rf /var/lib/distros/<name>/` from a namespace that has the
  disk file server bound there.
- **Multiple distros coexist trivially.** Same Hamnix image can host
  Debian-bookworm and Ubuntu-noble concurrently; their `/usr` trees
  never overlap because they're served by different file servers.
- **No new kernel mechanism required.** This is a *convention* on top
  of what Phase C already lands. No new syscalls, no new kernel
  subsystem — just an entry-point binary and a directory naming
  convention.

## What this does NOT include

- **No distro-shape namespace for native Adder binaries.** They run
  in init's namespace because that's the one they're built against.
  Running them inside a Debian-shape namespace would just hide them
  behind FHS noise.
- **No Adder reimplementations of Linux userland tools.** apt, dpkg,
  bash, curl, wget, tar, gzip, xz, gpg, etc. all exist in Debian and
  run inside the Linux namespace. We don't ship Adder ports of them.
  When a Linux tool needs to talk to a Hamnix concept (a `/srv` 9P
  service, a `/net` socket), shim the bridge layer, not the tool.
- **No automatic path translation between namespaces.** A
  Debian-namespace process referring to /home/david sees the same
  file-server response as a native-namespace process referring to
  /home/david, because both /home mounts bind the same server. There
  is no symbolic-path translation across namespaces — bytes match
  because the same server answers both reads.
- **No nested distro-shape namespaces.** A process inside Debian-shape
  cannot launch a SUSE-shape sub-namespace from within. Could be added
  if a use case appears; deferred until then.
- **No PID isolation.** Plan 9 / Hamnix pids are global. /proc shows
  all processes regardless of namespace. PID isolation, if ever
  wanted, lives at a different layer.
- **No security boundary.** See Boundary rule 6.

## Comparison to Linux schroot

Linux's schroot is the closest existing analog *in shape*: both
arrange for a binary to see a different `/`. They differ in **what
"different" means**.

- **schroot** creates a chroot — restricting a process to a subtree
  of "the real /". There IS a real /, the kernel knows it, and the
  chrooted process is restricted to a view of it. Escape is a
  meaningful concept (CVE-able).
- **Hamnix `enter linux { ... }`** binds the namespace's / to a
  different file server. There is no "the real /" at the kernel
  level. The new namespace isn't restricted; it just has different
  file servers serving different paths. There's nothing to escape
  from.

The distinction matters: if you internalise schroot's framing,
`enter linux` looks like a weaker container. If you internalise
Plan 9's framing, it looks like a configuration choice. The latter
is what Hamnix actually does.

## Shared-object loading (ld.so mmap path)

A real Debian binary like `apt(8)` is dynamically linked: `ld-linux`
(the `PT_INTERP`) maps the binary's `DT_NEEDED` closure at exec time.
For each DSO, glibc's `_dl_map_segments` issues a sequence of `mmap`
calls that the Linux-ABI layer must service:

1. A **whole-DSO reservation** — `mmap(NULL, total_vaddr_span,
   PROT_NONE|PROT_READ, MAP_PRIVATE, fd, 0)` — reserving one contiguous
   range covering every `PT_LOAD`. In Hamnix this routes through
   `mm/vma.ad::vma_alloc` → `_vma_alloc_large`, which backs the span
   with up-to-4-MiB buddy chunks stitched into one virtual window in
   the per-task mmap arena `[1 GiB, ~4 GiB)`. Even a single-page map
   takes this windowed path so the returned VA is a proper US=1
   per-task mapping (never a raw US=0 low-identity address).
2. Per-`PT_LOAD` **`MAP_FIXED` overlays** inside that reservation, each
   with the segment's file offset and `prot`. A strict sub-region alias
   re-stamps the leaf PTEs to the overlay's `prot` (so a writable
   data/GOT segment is genuinely writable during relocation); an
   anonymous `.bss`-tail overlay is zero-filled.
3. File bytes are populated by `_u_mmap_fill_file`
   (`linux_abi/u_syscalls.ad`), which reads the fd through a kernel
   bounce buffer and writes each page via its **physical** frame in the
   identity window — never through the user VA. This is the W^X
   keystone: a `PROT_READ` `.text` page's read-only leaf PTE is never
   written at CPL=0, so RELRO/GOT pages can stay read-only without the
   fill itself faulting.

"`apt: error while loading shared libraries: libapt-pkg.so.6.0: failed
to map segment from shared object`" is glibc's message when one of
those `mmap`/`mprotect` calls returns an error. The most common cause
is **not** a kernel mmap limit but a **missing DSO**: the staged distro
image didn't actually contain the file `ld.so` opened (the `DT_NEEDED`
`SONAME` symlink resolved to a target that was never staged), so the
open/`mmap` failed. The fix is in the staging scripts
(`scripts/build_rootfs_img.py` for the live `#distro` ext4,
`scripts/build_initramfs.py` for the embedded default root): the FULL
debootstrap mirror (`HAMNIX_DEBIAN_FULL=1`, default) copies every
`lib*.so*` and dereferences `SONAME` symlinks to their real bytes, and
the curated fallback now **globs** `usr/lib/x86_64-linux-gnu/lib*.so*`
version-agnostically rather than pinning specific minor versions
(which drift across Debian point releases). The larger DSO closure apt
pulls (`libapt-pkg`, `libapt-private`, `libstdc++`, `libcrypto`,
`libsystemd`, …) is therefore staged whatever the fixture's minors.

`MMAP_TRACE` in `linux_abi/u_syscalls.ad` (gate constant, default off
in ship builds) logs every linux-ABI `mmap`/`mprotect` —
`addr,len,prot,flags,fd,off → ret` — to pinpoint the first failing map
when diagnosing a new binary's closure.

## Test discipline

This phase lands green when all of the following pass:

1. `bash scripts/test_l_track.sh` — existing .ko regression suite.
2. `bash scripts/test_distro_namespace.sh` — the namespace primitive
   smoke test.
3. `bash scripts/test_linux_apt_install.sh` — real Debian apt/dpkg
   running inside `enter linux { ... }` against the rootfs partition.
4. `bash scripts/test_linux_debian_coverage.sh` — the stock-Debian
   binary coverage sweep (Part A: dash/bash/coreutils/dpkg/apt run
   correctly) plus offline `apt-get install` / `dpkg -i` of `hamhello`
   from the local `file://` repo, then running the installed binary
   (Part B). Requires `scripts/build_local_apt_repo.sh` to have staged
   the repo (it runs it automatically).

## References

- `docs/architecture.md` — layered model.
- `docs/native-api.md` — `rfork`, `bind`, `mount` contracts (Layer 1).
- `docs/HAMSH_SPEC.md` §11/§13 — `ns clean { … }` and `enter` semantics.
- `docs/rootfs_partition.md` — the `#distro` file-server backing.
- Plan 9 4th edition `intro(2)`, `bind(2)`, `namespace(4)`. The
  shape follows directly from these.
- 9front `none(1)` + `auth/none` — drop-into-a-different-namespace
  patterns from the canonical Plan 9 lineage.
