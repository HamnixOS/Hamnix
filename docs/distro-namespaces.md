# Distro-shape namespaces

**Imported-binary personalities via per-process Layer-1 namespaces.**

Hamnix's native rootfs has its own filesystem identity: Plan 9-shape
paths, minimal /etc, Adder binaries at /bin. FHS-Linux conventions
(/lib/x86_64-linux-gnu, /etc/debian_version, /usr/share/doc/, etc.)
do **not** live in the native rootfs. They live inside per-process
namespaces called **distro-shape namespaces** that imported Linux
binaries are run inside.

A distro-shape namespace is constructed by rfork(RFNAMEG); mount of a
distro-rootfs backing store as an overlay at /; bind of selected
native paths (/home, /net, /srv, /dev, /proc) back into the namespace;
exec of the target binary. From inside the namespace, the world looks
like that distribution: /bin/bash, /lib/x86_64-linux-gnu/libc.so.6,
/etc/passwd in Debian's format. Outside the namespace, nothing
changed.

The OS identity is therefore never compromised by what Linux binaries
expect. There is no global /lib/x86_64-linux-gnu, no global
/etc/debian_version, no global FHS on Hamnix. Those exist only inside
the namespaces of processes that need them.

## Layout

| Path | Native namespace | Debian-shape namespace |
|------|------------------|------------------------|
| /bin | Adder binaries (hamsh, ls, ps, cat, ...) | Debian binaries (bash, ls, apt, dpkg, ...) |
| /lib | minimal — Adder runtime support | /lib/x86_64-linux-gnu, glibc, ld-linux-x86-64.so.2 |
| /usr | minimal | full Debian /usr (share, lib, bin, ...) |
| /etc | Hamnix config (motd, passwd, group, rc, os-release) | Debian config (debian_version, apt/, dpkg/, ld.so.cache, ...) |
| /var | minimal | Debian /var (lib/dpkg, log, cache/apt, ...) |
| /home/$user | shared (bound from native) | shared (bound from native) |
| /net | shared (bound from ipd) | shared (bound from ipd) |
| /srv | shared | shared |
| /dev | shared (bound from native) | shared (bound from native) |
| /proc | shared — pids are global on Hamnix, same as Plan 9 | shared |

## Boundary rules

1. **Native rootfs MUST NOT contain FHS-Linux files.** No
   /lib/x86_64-linux-gnu/, no /etc/debian_version, no /usr/share/doc/
   in the actual on-disk Hamnix rootfs. These live exclusively inside
   distro-shape namespace backing stores at /var/lib/distros/<name>/.
2. **`apt` and `dpkg` run only inside their distro-shape namespace.**
   They write to /var/lib/dpkg, /etc/apt, /usr/lib/* — all of which
   are inside the namespace's backing store, not on the native rootfs.
3. **Multiple distro-shape namespaces coexist.** /var/lib/distros/
   can contain debian-bookworm/, debian-trixie/, ubuntu-noble/,
   suse-tumbleweed/. Each is its own backing store; processes select
   one at namespace-construction time.
4. **Distro-shape namespaces have no init.** They host individual
   binaries (or a bash shell for interactive use), not a parallel
   running system. Service management stays on Hamnix's init
   (hamsh + /etc/rc), which can launch a Linux service *into* a
   distro-shape namespace when needed.
5. **Cross-namespace IPC is via /srv (9P) or /net (sockets), both
   shared by default.** A Debian-shape postgres can talk to a native
   Adder service through /srv/postgres or /net/tcp the same way two
   native services would.
6. **Distro-shape namespaces are NOT a security boundary.** They
   isolate filesystem layout, not capability. A process inside a
   distro-shape namespace is exactly as privileged as it would be in
   the native namespace. For privilege isolation, layer additional
   namespace restrictions on top.

## Backing stores

Two implementations, in order of expected build:

1. **Disk-backed (debootstrap path).** /var/lib/distros/debian-trixie/
   is a real Debian rootfs extracted via `debootstrap` (run once on a
   host Linux box, copied onto a Hamnix-mounted disk). Entered with
   `mount /var/lib/distros/debian-trixie /` after rfork RFNAMEG.
   Heavy but works immediately; what schroot does.
2. **`debfs` 9P server (deferred).** A Layer 3 service that
   synthesizes Debian's FHS layout on demand from a package store
   (.deb archives or pre-extracted contents in object-storage form).
   Lighter, composable, more Plan 9. Build after Phase F when Layer 3
   services are routine.

## Entry point

A userland binary at `/bin/distrorun`, with convenience aliases at
`/bin/deb`, `/bin/ubuntu`, `/bin/suse` for common distros:

```
distrorun <distro-name> <command> [args...]
# convenience aliases:
deb bash                       # → distrorun debian-trixie bash
deb apt install postgresql
ubuntu apt install nginx
```

Reference implementation (pseudocode):

```
distrorun(distro, argv):
    backing = "/var/lib/distros/" + distro
    if not exists(backing):
        error("unknown distro: " + distro)
    rfork(RFNAMEG)
    mount(backing, "/")
    bind("/home", "/home")
    bind("/net",  "/net")
    bind("/srv",  "/srv")
    bind("/dev",  "/dev")
    bind("/proc", "/proc")
    exec(argv[0], argv)
```

## Phase placement

Depends on Phase C (rfork RFNAMEG + bind + mount syscalls). Lands as
**Phase C.5: distro-shape namespaces** — after Phase C's primitives
work, before Phase D's hamwd, since hamwd isn't on the critical path
for server workloads.

## Why this shape

- **Hamnix stays Hamnix.** The native rootfs is a pure Hamnix system,
  not a Debian-Hamnix hybrid. Linux compatibility is a feature
  imported binaries opt into via namespace, not a property of the OS.
- **`apt install` is safe.** Package managers operate on a namespace's
  backing store, never on Hamnix's native /. Removing a distro means
  `rm -rf /var/lib/distros/<name>`.
- **Multiple distros coexist trivially.** The same OS image can host
  Debian-bookworm and Ubuntu-noble concurrently, with no overlap
  between their /usr trees.
- **No new kernel mechanism required.** This is a *convention* on top
  of what Phase C already lands. No new syscalls, no new kernel
  subsystem — just an entry-point binary and a directory naming
  convention.

## What this does NOT include

- **No distro-shape namespace for native Hamnix binaries.** Adder
  programs run in the native namespace. Putting them in a Debian-shape
  namespace would just hide them behind FHS noise.
- **No automatic path translation between namespaces.** A
  Debian-namespace process referring to /home/david sees the same
  bytes as a native-namespace process referring to /home/david,
  because both /home mounts are the same underlying bind. Cross-
  namespace symbolic-path translation is not a thing.
- **No nested distro-shape namespaces.** A process inside Debian-shape
  cannot launch a SUSE-shape sub-namespace from within. Could be added
  if a use case appears; deferred until then.
- **No PID isolation.** Plan 9 / Hamnix pids are global. /proc shows
  all processes regardless of namespace. If PID isolation is needed
  later, it lives at a different layer.
- **No security boundary.** See Boundary rule 6.

## Test discipline

Phase C.5 lands green when all of the following pass:

1. `bash scripts/test_l_track.sh` — existing .ko regression suite.
2. `bash scripts/test_u_track.sh` — existing ELF-userland regression
   suite.
3. `bash scripts/test_distro_namespace.sh` (new):
   - `deb /bin/true` exits 0
   - `deb /bin/bash -c 'echo hi'` prints "hi"
   - `deb cat /etc/debian_version` reads from the namespace backing
     store, not from the native rootfs
   - `cat /etc/os-release` from the native namespace still shows
     Hamnix's os-release (NOT Debian's)
   - `deb stat /home/$USER` and `stat /home/$USER` show the same inode
   - Two concurrent `deb bash` sessions don't see each other's
     mount-namespace bindings

## References

- `docs/architecture.md` — layered model. This doc is the Phase C.5
  addendum to the migration plan.
- `docs/native-api.md` — `rfork`, `bind`, `mount` contracts (Layer 1).
- 9front's `none(1)` + `auth/none` patterns inspired the "drop into
  a different namespace" idiom.
- Linux's `schroot(1)` is the closest existing analog; this design
  is schroot with Plan 9's namespace primitives instead of Linux's
  mount namespaces.
