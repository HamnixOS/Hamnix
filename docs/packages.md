# Hamnix package manager (`hpm`) — format spec

> **Status:** v1 is **shipped**. `user/hpm.ad` (~5,400 lines)
> implements every command in this spec across `0b4b75d`..`414243a`
> (2026-05-26..27): `refresh` / `list` / `search` / `show` /
> `install` (with hooks, BFS dep solver, conflict detection) /
> `remove` / `update` / `pin` / `unpin`. Verified by
> `scripts/test_hpm.sh` (refresh/install/list/remove + conflict
> negative test). Five v1 packages live at the canonical repo
> `https://255.one/`: `hamnix-hello`, `hamnix-base`,
> `hamnix-bootloader`, `hamnix-installer-tools`, `linux-debian-12`
> (built by `scripts/build_packages.py`). The installer
> (`etc/install.hamsh`) drives `hpm install` against an
> ISO-local mini-repo at `/iso-packages/`.

`hpm` is the Hamnix-native package manager. It installs **Hamnix-side
state**: kernel modules, native userland binaries, services, drivers,
**distro-namespace populations** (e.g. `linux-debian-12`'s rootfs tree),
firmware (from the non-free pool), and the OS itself.

It does **NOT** install Debian / Ubuntu / SUSE binaries. Those are the
job of the distro's own package manager running inside the appropriate
distro namespace:

```
hpm install linux-debian-12         # populates the distro file server
hpm install --pool=non-free iwlwifi # firmware blob
                                    # then:
enter debian-12 { apt install nginx }   # real apt, real Debian binary
```

The boundary keeps each tool to its competence: hpm doesn't try to be
apt; apt doesn't try to manage Hamnix kernel modules; both manage
their own world.

## Repository layout

A Hamnix package repository is a static HTTPS-served tree:

```
<repo root>/
├── index.json           # machine-readable package list
├── index.html           # human-browsable view
├── README.md
└── packages/
    ├── hamnix-base-1.0.tar.gz
    ├── linux-debian-12-1.tar.gz
    └── ...
```

The canonical repo lives at `https://255.one/`; mirrors are anyone
who serves the same tree. `hpm` is a thin client over HTTPS — no
server-side logic required.

## Package layout (gzipped tar)

A package is a single gzipped tar containing one top-level directory
named `<name>-<version>/`:

```
<name>-<version>/
├── PKGINFO            required, key:value metadata
├── files/             required, file tree (paths inside = paths at install target)
├── pre-install.hamsh  optional, runs BEFORE files are staged (non-zero exit aborts)
├── install.hamsh      optional, runs AFTER files are staged
├── remove.hamsh       optional, runs BEFORE files are deleted (non-zero exit aborts)
└── post-remove.hamsh  optional, runs AFTER files are deleted
```

All hooks are plain hamsh, run in init's default namespace with these
env vars:
- `HPM_PKG_NAME` — the package's name
- `HPM_PKG_VERSION` — the version being installed
- `HPM_PKG_DIR` — path to the extracted package directory (still inside
  hpm's staging area at hook time, not yet at install target)
- `HPM_TARGET` — the file-server target (see `target:` below)

## PKGINFO grammar

UTF-8 text, one key per line, `key: value`. Continuation lines start
with whitespace. `#` starts a comment to end of line. Blank lines OK.

### Required keys

| Key           | Value                                          |
|---------------|------------------------------------------------|
| `name`        | `[a-z][a-z0-9-]*`, max 64 chars                |
| `version`     | dotted decimal `1.2.3`, optional `+<tag>`      |
| `arch`        | `x86_64` or `any`                              |
| `description` | one line                                       |

### Optional keys

| Key           | Value                                                            |
|---------------|------------------------------------------------------------------|
| `target`      | file-server name (default `#hamnix-system`); see "Targets" below |
| `depends`     | comma-separated `name` or `name>=version` constraints            |
| `conflicts`   | comma-separated package names this conflicts with                |
| `provides`    | comma-separated virtual names this package satisfies             |
| `replaces`    | comma-separated package names this supersedes                    |
| `namespace`   | one or more hamsh `bind` lines appended to init's recipe         |
| `conffiles`   | comma-separated paths inside `files/` preserved on upgrade if user-modified |
| `maintainer`  | freeform string                                                  |
| `license`     | SPDX identifier                                                  |
| `homepage`    | URL                                                              |

Example:

```
name: linux-debian-12
version: 12.4.1
arch: x86_64
description: Debian 12 (bookworm) rootfs for the Linux namespace
target: #distro
depends: hamnix-base>=1.0
provides: linux-debian
conflicts: linux-debian-13
maintainer: HamnixOS
license: various (Debian)
homepage: https://debian.org/
```

## Targets — where the files land

A package's `target:` declares which file server its `files/` tree is
extracted onto. The defaults cover the common cases:

| Target              | Meaning                                                                                  |
|---------------------|------------------------------------------------------------------------------------------|
| `#hamnix-system`    | (default) The init namespace's writable area — files appear at their install paths in init's default namespace. Most native packages. |
| `#distro`           | The distro partition's primary distro file server. Used by `linux-<distro>-<ver>` packages that populate a distro rootfs. |
| `#<word>`           | An existing named file server (created at boot from a `.hamnix-roots` sentinel entry). Package files land there. |
| `#<new-word>` + `namespace:` | A *new* named server. The package's install hook adds a `.hamnix-roots` entry on the underlying partition (raw root accessible via `#by-id/<partuuid>`) and `hpm` registers it in the live name table. |

The `namespace:` field lets a package declare hamsh `bind` lines that
init's recipe appends at install time — e.g. a `postgres-server`
package might say:

```
target: #postgres-data
namespace:
    bind '#postgres-data/conf' /etc/postgres
    bind '#postgres-data/data' /var/lib/postgres
```

The namespace lines are validated (no unrestricted binds over critical
paths like `/etc` from the package). Packages don't get full namespace
authority — they request specific additions.

## Version comparison

Versions are dotted-decimal tuples: `1`, `1.0`, `1.2.3`, `1.2.10`,
`2.0`. Compared component-by-component as integers. `1.2.10 > 1.2.3`
(NOT lexical). Missing components are treated as zero (`1.2 == 1.2.0`).

Optional `+<tag>` is build metadata; ignored for ordering. `1.0+a` and
`1.0+b` compare equal.

No pre-release semantics (no `-rc1` / `-beta` etc). KISS. If you need
to stage a release, use `0.9.x` versions before `1.0`.

Constraints in `depends:`:
- `name` — any version
- `name>=1.0` — at least 1.0
- `name>1.0` — strictly greater
- `name==1.0` — exactly 1.0
- `name<2.0` — less than
- `name<=2.0` — at most
- `name>=1.0,name<2.0` — compound (two entries with same name; AND'd)

## Dependency solver

Greedy breadth-first. No backtracking. Tractable and predictable.

```
1. Push the user's requested package onto a queue.
2. While the queue is non-empty:
   a. Pop a requirement (name + version constraint).
   b. If already in `resolved` or `installed`:
      - Verify the existing version satisfies the new constraint.
      - On conflict, FAIL with the full chain.
      - Otherwise skip.
   c. Find the best (highest version) package in the repo
      satisfying the constraint.
   d. If none found, FAIL with "no candidate for <name> <constraint>".
   e. Check `conflicts:` against `resolved` + `installed`.
      On conflict, FAIL.
   f. Add to `resolved`.
   g. Enqueue each of the package's `depends:` entries.
3. Return the resolved set ordered such that each package's deps
   appear before it (topological install order).
```

What this WON'T do: backtrack to try a different version when the
best-fit's deps conflict. If you hit that, you'll get a clear
"unsatisfiable: X conflicts with Y" message and have to pin manually.
The alternative (SAT solver) is overkill for v1 and would tank
predictability.

## Conflicts

Three flavors, all enforced:

1. **Same-name version conflict** — only one version of a given name
   can be installed at a time. Implicit; always enforced.
2. **Cross-name conflict** — declared via `conflicts:`. Symmetric;
   either side declaring it is enough.
3. **File conflict** — at extract time, hpm checks each file in
   `files/` against `installed.json`'s recorded file lists. If a file
   would overwrite another package's file, FAIL.

`provides:` declares virtual names. A `depends: linux-distro` is
satisfied by `linux-debian-12` if its PKGINFO has `provides:
linux-distro`.

`replaces:` lets a new package supersede an old one cleanly — `apt`
replaces a hypothetical `apt-tiny` etc. On install, the replaced
package is uninstalled first (file conflicts are then allowed).

## Pinning

`hpm install foo@1.2.3` pins `foo` to exactly `1.2.3`. The pin is
recorded in `installed.json`. `hpm update` SKIPS pinned packages.

`hpm install foo` (no `@`) installs the latest matching constraints
and records the install without a pin. Future `hpm update` will
upgrade as new versions land.

`hpm pin foo@1.2.3` pins an existing install retroactively.
`hpm unpin foo` removes the pin.

## index.json schema

Schema version 1.

```json
{
  "schema": 1,
  "repo": "HamnixOS/packages",
  "url": "https://255.one/",
  "updated": "YYYY-MM-DD",
  "description": "...",
  "packages": [
    {
      "name": "<name>",
      "version": "<version>",
      "arch": "<arch>",
      "url": "packages/<name>-<version>.tar.gz",
      "sha256": "<lowercase hex>",
      "size": <bytes>,
      "description": "...",
      "depends": ["dep1", "dep2>=1.0"],
      "conflicts": [],
      "provides": [],
      "target": "#hamnix-system"
    }
  ]
}
```

Multiple versions of a package = multiple entries with the same `name`
and different `version`.

Non-free pool: `https://255.one/nonfree/index.json` (same schema).
`hpm --pool=non-free` adds it to the search path.

## Installed-package database

`/var/lib/hpm/installed.json` on the running system:

```json
{
  "schema": 1,
  "packages": [
    {
      "name": "hamnix-base",
      "version": "1.0",
      "installed_at": "2026-05-26T18:00:00Z",
      "pinned": false,
      "target": "#hamnix-system",
      "files": ["bin/hamsh", "etc/rc.boot", ...]
    }
  ]
}
```

`files` is what hpm wrote — used for clean removal.

## Commands

| Command | Action |
|---------|--------|
| `hpm refresh` | Re-fetch `index.json` (and non-free if enabled) |
| `hpm list` | Show installed packages |
| `hpm search <pat>` | Query repo for packages matching `<pat>` |
| `hpm show <name>` | Print PKGINFO + repo metadata for a package |
| `hpm install <name>[@<ver>]` | Resolve deps, fetch, verify, extract, run hooks |
| `hpm remove <name>` | Run remove hooks, delete files, run post-remove |
| `hpm update` | Refresh; upgrade every non-pinned installed package |
| `hpm pin <name>[@<ver>]` | Pin to the installed (or specific) version |
| `hpm unpin <name>` | Remove pin |
| `hpm verify <name>` | Re-check installed files against PKGINFO |
| `--pool=non-free` | Enable the non-free pool for this invocation |

## Signing

v1 trusts HTTPS + SHA-256:
- TLS proves the repo URL identity (GitHub-signed cert for `255.one`).
- `index.json` carries SHA-256 for each tarball; `hpm` verifies the
  downloaded tarball against the recorded hash before extraction.
- Anyone with write access to `HamnixOS/packages` can ship a package.

v2 (deferred) will add GPG envelope signing for non-GitHub mirrors.
Until then, mirrors are trusted iff their TLS cert is.

## Bootstrap: installer mini-repo

The Hamnix installer ISO carries a minimal copy of the repo at
`/mnt/iso-packages/` (a path baked into the ISO). The installer's
hpm invocation points there:

```
hpm --repo=file:///mnt/iso-packages install hamnix-base hamnix-installer-tools
```

After install + reboot, `hpm` defaults back to the network repo
(`https://255.one/`) and `hpm update` pulls newer versions from
upstream.

## Non-free pool

`https://255.one/nonfree/` — same format, separate index. Holds
firmware blobs (iwlwifi, brcm, etc.) and anything else with a
license that prevents redistribution-by-default.

`hpm --pool=non-free install iwlwifi-firmware` opts in. The pool
URL is recorded in `installed.json` so `hpm update` knows to check
both indexes for installed-from-non-free packages.

## What this spec does NOT include

- **Source packages.** v1 is binary-only. On-system source builds
  would need a Linux namespace with Python or an Adder build chain
  with full kernel access — too much circular dependency for v1. If
  source distribution becomes a real need, revisit with a binary
  fallback (`source/` + `binary/` in the same package).
- **Triggers / interest files** (Debian's complex inter-package
  invalidation). Use install hooks if a package needs to react to
  another's installation; explicit > implicit.
- **Recommended / Suggested**. Just hard `depends:` for v1. Optional
  packages = the user types `hpm install <pkg>` themselves.
- **Debconf-shape interactive prompts.** Install hooks are
  non-interactive (no stdin). Configuration is via files.
- **Architecture multiarch.** v1 is x86_64-only (and `arch: any` for
  scripts/data). Multiarch when a real second arch lands.

## Cross-refs

- [HamnixOS/packages](https://github.com/HamnixOS/packages) — the
  repo itself; live at `https://255.one/`
- [HamnixOS/adder](https://github.com/HamnixOS/adder) — the language
  hpm is written in
- `etc/svc/<name>.hamsh` — service supervision; packages that ship a
  service drop their `.hamsh` definition into `etc/svc/` via their
  `files/` tree
- `docs/rootfs_partition.md` — file-server discovery (sentinel,
  `#<word>` registration, `#by-id/<partuuid>`)
