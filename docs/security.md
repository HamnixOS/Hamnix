# Hamnix security model — Plan 9-shape, namespace-as-authority

> **Status:** v1 is shipped across `b40e874`..`ae15032`
> (2026-05-26..27). Every phase below has a "Shipped at" line citing
> the landing commit. The Plan-9-shape model is the live model;
> `/dev/auth`, `newshell`, the hpm uid==1 gate, the live ISO
> `live:hamnix` credentials, and the installer credential prompts
> all work in `scripts/test_security.sh` (covers Phases 1/4/5/6/7/8/9
> — the kernel-plumbing + /dev/auth + VFS perm + ext4 owner-stamp +
> newshell + hpm gate + per-user .ns recipe boundary).

## TL;DR

Hamnix's native security model is **Plan 9**'s, not POSIX's. There is
**one hostowner** (uid 1) per installed system who owns everything and
runs privileged tools like `hpm`. Other accounts are **regular users**
(uid > 1) who get a restricted namespace at login — they literally
can't address dangerous file servers or partitions, so no permission
check needs to fire for the most important boundaries. **No setuid
binaries**, no `sudo`, no `su`. The elevation idiom is `newshell
hostowner` — a factotum-shape authenticated re-login, not a permission
flag on a binary.

POSIX-shape security (real `sudo`, `/etc/sudoers`, setuid bits) lives
**inside the Linux namespace** where Debian's own machinery runs
unmodified. The two worlds don't borrow each other's idioms.

## Why Plan 9, not POSIX

setuid binaries are responsible for an enormous share of historical
Unix CVEs (every parsing bug in a setuid utility is a privilege
escalation). Plan 9 deliberately rejected the model: authority should
be **namespace-shaped, not binary-shaped**. A regular user CAN'T
escalate by tricking a privileged binary because no binary holds
elevated authority in the first place — the user's namespace simply
doesn't bind the file servers a privileged operation would need.

Hamnix already has the substrate: per-process Pgrp + bind freeze +
named file servers via sentinel + `#by-id/<partuuid>` aliases. The
security model is the natural use of those primitives.

## Two worlds

**Hamnix-native side** — hostowner + namespace-restricted regular
users. No setuid. No sudo. Authority via namespace. This document.

**Linux namespace side** (inside `enter debian-12 { ... }` etc.) —
real Debian POSIX. Real `/etc/shadow`, real `sudoers`, real `sudo`
binary, real setuid bits. Hamnix doesn't reimplement; Debian's own
machinery runs unmodified. The two security models coexist because
they apply to different namespaces.

## Users

A user is an entry in `/etc/passwd`:

```
hostowner:1:1:/home/hostowner:/bin/hamsh
alice:1000:1000:/home/alice:/bin/hamsh
```

Format: `name:uid:gid:home:shell` (no GECOS field; KISS).

- **`hostowner`** (uid 1) — the machine owner. Owns `/`, `/etc`,
  `/bin`, `/var/lib/hpm/`, the rootfs partition, all `#hamnix-system`
  file servers. Runs `hpm`. Only one per installed system.
- **Regular users** (uid >= 1000) — own their `/home/<name>` only.
  See a restricted namespace at login.
- **System users** (uid 2..999) — reserved for services. Run by `svc`
  with a declared uid in the service definition. No login shell.

uid 0 is **unused**. The "root" idiom doesn't exist. uid 1 is the
hostowner because Plan 9 historically uses 1 for `glenda` / first
user; we follow.

### Authentication

Passwords live in `/etc/shadow`:

```
hostowner:$6$<salt>$<sha-512-crypt-hash>:<last-change-days>
alice:$6$<salt>$<sha-512-crypt-hash>:<last-change-days>
```

- Format mirrors Linux's `shadow(5)` so a future migration to/from a
  POSIX system stays mechanical.
- `$6$` = SHA-512-crypt (Linux default; we already have SHA-512 from
  the TLS stack). Iteration count baked at 5000 (Linux default).
- `<last-change-days>` is days since epoch; lets a future policy
  expire stale passwords.
- File is mode 0600, owned by hostowner. Regular users can't read it.

`bcrypt` / `argon2` are deferred — adding them would require new lib
code without changing the threat model materially for v1.

### The `auth` cdev

Authentication goes through a kernel-side `#auth` device (mounted at
`/dev/auth` per init's recipe; shipped at `f5e9982` as
`sys/src/9/port/devauth.ad`). Userland never reads `/etc/shadow`
directly. Pattern:

```
fd = open("/dev/auth", ORDWR)
write(fd, "user hostowner\n")
write(fd, "pass " + plaintext + "\n")
read(fd, response)
# response = "ok" or "denied"
close(fd)
```

The kernel-side handler reads `/etc/shadow`, hashes the supplied
password with the recorded salt, constant-time compares. Userland
never gets the hash, never has direct shadow access. This is the
factotum-shape primitive — credential handling lives in a single
audited kernel path.

## Permissions — server-boundary model (F3 #448, 2026-06-11)

Hamnix's kernel does **not** carry a global path-keyed permission
policy. Per Plan 9, **permissions live at the file server you
attached to**. A bind/mount establishes an authenticated channel; the
server applies its own per-server policy on the ops that arrive on
that channel.

Concretely, every `vfs_open` / `vfs_open_write` / exec goes through
`chan_permission_check(name, want)` in `fs/vfs.ad`. The dispatcher does
**exactly one** decision: it identifies the file server that OWNS the
path (cpio `#r`, tmpfs `#t`, ext4 `#e`, FAT `#f`, devs `#c`, block
`#b`, proc `#p`, srv `#s`, net `#I`, auth `#auth`, root slot `#/`) and
delegates to that server's `_perm_check_<server>` policy.

| Server | Policy lives in | v1 policy |
|--------|-----------------|-----------|
| `#r` cpio | `_perm_check_cpio` (fs/vfs.ad) | read-only baked-in: reads world-OK, writes denied |
| `#t` tmpfs | `_perm_check_tmpfs` | world-r/w scratch (/tmp, /var) |
| `#e` ext4 | `_perm_check_ext4` (delegates to `ext4_inode_owner_at`) | enforces on-disk inode mode bits at the ext4 backend boundary |
| `#f` FAT | `_perm_check_fat` | world-r/w (FAT volumes don't track owners) |
| `#c` devs | `_perm_check_devcons` | world-r/w introspection knobs by default; per-cdev tightening at the cdev (e.g. `/dev/wsys/ctl` is hostowner-only in devwsys.ad) |
| `#b` block | `_perm_check_devblk` | hostowner-only (raw block devices) |
| `#p` proc | `_perm_check_devproc` | world-readable; ctl-file write authority enforced at devproc |
| `#s` srv | `_perm_check_devsrv` | world-r/w; post wire-shape is the gate |
| `#I` net | `_perm_check_devnet` | world-r/w; ipifc/ctl writes enforced at devnet |
| `#auth` | `_perm_check_devauth` | world-r/w wire; rate-limit + constant-time compare inside the cdev are the real gate |
| `#/` root slot | `_perm_check_rootslot` | no-op (bind/mount is the gate) |

The kernel vfs has **no literal-path arms**. There is no `/etc/shadow`
clause, no `/var/lib/hpm/` clause, no `/dev/blk/*` clause inside vfs;
each of those is enforced where it belongs — ext4 mode bits at the
ext4 backend, hpm at the userland `hpm` tool's `uid==1` gate, raw
block at `_perm_check_devblk`.

There is a **hostowner (uid 1) bypass at the dispatcher** that admits
the historical Plan 9 convention "the hostowner owns the system." It
is applied for the on-disk servers (`#e`, `#t`, `#r`) where the
0600-mode `/etc/shadow` file would otherwise deny the legitimate
hostowner read. Each server's policy retains the final say: `#b`
(`_perm_check_devblk`) requires `uid == 1` rather than admitting a
bypass, and a future per-user homedir server can ignore the bypass by
returning `EPERM_PERM` for `uid == 1` from its own policy. The bypass
is the **floor**, not the ceiling.

### Kernel-mediator credential reads — `vfs_open_kernel`

The credential mediator (`sys/src/9/port/devauth.ad`) reads
`/etc/shadow` via `vfs_open_kernel(path)` / `vfs_open_write_kernel(path)`
— explicit-by-construction kernel-context entry points that bypass the
server-boundary gate. The CALLER (devauth) is privileged-by-construction:
the entry point exists in the kernel binary, has no userland-reachable
syscall, and is named for its single legitimate caller. This replaces
the pre-F3 `vfs_auth_mediator_active` global flag that devauth raised
around its `/etc/shadow` open — a flag whose existence the audit
flagged as the antithesis of the server-boundary model.

The Plan-9 invariant holds: **userland NEVER opens /etc/shadow
directly** — the file's 0600 hostowner-owned mode is enforced at the
ext4 backend, denying any non-hostowner userland open by mode bits;
only the in-kernel credential mediator reaches the file, and only by
calling the explicit kernel-context primitive.

### Factotum (planned, F3 follow-up)

Long-term, the in-kernel `devauth` becomes a thin shim to a userland
**factotum** server posting at `/srv/factotum`. The wire shape factotum
speaks is the same shape `devauth` speaks today:

```
fd = open("#s/factotum", ORDWR)
write(fd, "user <name>\n")
write(fd, "pass <plaintext>\n")
read(fd, response)              # "ok\n <uid> <gid>\n" or "denied\n"
close(fd)
```

A `setpass` verb extends the same wire shape:

```
write(fd, "setpass <plaintext>\n")
read(fd, response)              # "ok\n" or "denied\n"
```

When factotum lands, the kernel `devauth` either becomes a thin
forwarder to the posted srvfd or is deleted in favour of init posting
`/srv/factotum` directly. `do_mount`'s `afd` parameter (today
accepted-and-ignored, see `sys/src/9/port/syschan.ad`) is wired
through `p9c_attach` at the same time: an attach to a server CARRIES
the authenticated uname from the factotum exchange instead of the
current empty string. This unlocks per-process attach-time identity —
the Plan 9 "authenticated attach" shape.

The wire shape is fixed by this commit so a follow-up agent can land
factotum without churning the consumers (`hamsh`'s `newshell`, `su`,
`login`, `sshd`).

### Why the model changed (audit finding #448)

The pre-F3 kernel had a literal-path policy funnel
(`_vfs_check_perm`) that hard-coded `/etc/shadow`, `/dev/blk/*`,
`/var/lib/hpm/*`, ext4 mode bits, a `uid==1` global bypass, and a
`vfs_auth_mediator_active` global backdoor. The Plan 9 audit (#444,
pillar 3) called this out as the antithesis of "permissions live at
the attached server." F3 (#448) moves every clause to where it
belongs: `_vfs_check_perm` is gone (replaced by the dispatcher
`chan_permission_check`), the global backdoor is deleted, and ext4
mode-bit enforcement is at the ext4 backend boundary, not in the
kernel vfs.

The dispatcher itself is small (≈25 lines) and contains no policy —
it routes by server letter, exactly the same routing
`_open_hash_alias` already does for the open path. Adding a new
file server means writing a new `_perm_check_<X>`; the dispatcher
gains one new arm. No existing servers see their policy churn when
that lands.

**No setuid / setgid / sticky.** These don't exist in the on-disk
format Hamnix writes. (The kernel ignores them on Debian-side files
inside the linux ns — that ns has its own VFS path.)

## Namespace as authority

The strongest layer: **regular users see a restricted namespace** at
login. Their hamsh inherits a namespace recipe (`/etc/users/<name>.ns`
— optional per-user override; falls back to `/etc/users/default.ns`)
that:

- Binds `/home/<their-name>` writable.
- Binds `/tmp` writable (per-user tmp, isolated).
- Binds `/bin`, `/usr/bin` from `#hamnix-system` READ-ONLY.
- Does **NOT** bind `/dev/blk/*` (raw block devices).
- Does **NOT** bind `#by-id/<partuuid>` (raw partition roots).
- Does **NOT** bind `/var/lib/hpm/` (hpm's state).
- Does **NOT** bind named-server creation paths.

This means a regular user can't even `cat /dev/blk/vda` (the path
doesn't resolve in their namespace). The permission check is a
defense-in-depth fallback; the primary boundary is "you can't name
it, so you can't open it."

The hostowner gets the full namespace recipe (init's default) with
everything bound.

## The elevation idiom: `newshell <user>`

POSIX `sudo` = "elevate THIS command's authority temporarily."
Plan 9 / Hamnix = "open a new shell session AS that user, with their
full namespace."

```
$ newshell hostowner
password: ********
[hostowner@hamnix ~]$ hpm install linux-debian-12
[hostowner@hamnix ~]$ exit
$ # back to your regular-user shell
```

`newshell` is a hamsh builtin (not a binary at all, so it can't be
tampered with). It:
1. Reads the target uid from `/etc/passwd`.
2. Prompts for password.
3. Writes to `/dev/auth` to authenticate.
4. On success: `rfork(RFPROC|RFNAMEG)`, switch task uid/gid in the
   child, load the target user's namespace recipe, `exec /bin/hamsh`.
5. Parent (your original shell) sees a child it can wait on.

No setuid binary. No environment leak. No setuid path-search game.
Authority is granted by the kernel after password auth, not stolen
from a binary's setuid bit.

A second idiom for one-shots: `newshell hostowner -c '<command>'` —
runs `<command>` as hostowner and exits. Same auth path.

## hpm + authority

hpm refuses to run if `uid != 1`. Single check at start; clean error:

```
$ hpm install linux-debian-12
hpm: package installation requires hostowner. Try `newshell hostowner`.
```

Combined with namespace restriction: regular users can't open
`/var/lib/hpm/installed.json` to read state, can't open `/dev/blk/*`
to write to partitions, can't address `#by-id/...` to bypass. The
uid check is documentation; the namespace is the actual gate.

## Services and uids

`/etc/svc/<name>.hamsh` gains an optional `uid:` field:

```
name: postgres
uid: 50           # system uid for postgres
ns: postgres-svc  # the namespace recipe with #postgres-data bound
exec: /usr/bin/postgres
```

`svc` starts the service in the supervisor (init's namespace,
hostowner-owned), then before `exec` switches uid + applies the
service's namespace recipe. Service files live in a namespace where
ONLY their state directories are writable. Compromise of one service
doesn't grant access to another's data.

System uids 2..999 are baked in `/etc/passwd`:

```
sshd:2:2:/var/empty:/bin/false
hamsh-svc:3:3:/var/empty:/bin/false
postgres:50:50:/var/lib/postgres:/bin/false
nginx-svc:80:80:/var/empty:/bin/false
```

`/bin/false` shell means no interactive login.

## Live ISO

The live ISO ships with hostowner `live` / password `hamnix`:

```
# /etc/passwd
live:1:1:/home/live:/bin/hamsh

# /etc/shadow
live:$6$<salt>$<hash of 'hamnix'>:<days>
```

No regular users on the live system; everything runs as `live`. The
installer replaces this with the user's choice before laying down
`/etc/passwd` on the installed system.

## Installer prompts

Following Debian's UX (different model underneath):

```
[install] Hostowner username: hamnix
[install] Hostowner password: ********
[install] Confirm password:   ********

[install] Create additional regular users? [y/N] n

[install] Install Linux runtime? [Y/n] y
[install]   Debian distro: [1] debian-12 (bookworm) [2] debian-13 (trixie)
[install]   Selection: 1
[install]   Debian-side POSIX-root password: ********
[install]   (this is the root password INSIDE `enter debian-12`; separate
[install]    from your Hamnix hostowner password)
[install]   Confirm: ********

[install] Writing /etc/passwd + /etc/shadow on target...
[install] Done. Reboot from disk to continue.
```

If the user opts out of installing a Linux runtime, the second
password prompt is skipped. They can `hpm install linux-debian-12`
later, at which point that package's `install.hamsh` will prompt
for the Debian-side root password.

## Linux namespace uid mapping

Inside `enter debian-12 { /bin/bash }`:
- Hamnix hostowner (uid 1) → Debian root (uid 0).
- Hamnix regular user `alice` (uid 1000) → Debian uid 1000 (mapped 1:1).
- The Linux namespace's own `/etc/passwd` is the Debian rootfs's
  passwd; Hamnix's `/etc/passwd` is not bound into the linux ns.
- `sudo` inside the linux ns prompts the Debian-side root password.
  This is **independent** from the Hamnix hostowner password.

This split keeps things safe: a Debian binary compromised inside
the linux ns can escalate to Debian-root inside that ns but can't
touch Hamnix-side state (the linux ns is `clean` and doesn't bind
Hamnix's privileged paths).

## What this document does NOT include

- **Capabilities** (Linux fine-grained privilege). The hostowner-or-not
  binary distinction is enough for v1. If a future need surfaces,
  add per-namespace capability binds rather than a Linux-shape
  capability set.
- **SELinux / AppArmor / TOMOYO**. Mandatory access control on top
  of DAC — much heavier infrastructure than v1 needs. Namespace
  restriction is already mandatory-ish (you can't grant authority
  you don't have).
- **ACLs**. Owner/group/other is the v1 ceiling. If real
  multi-collaborator setups need finer control, revisit.
- **Quotas**. No per-user disk quota in v1.
- **PAM**. Authentication is one path (`/dev/auth` → SHA-512-crypt
  against `/etc/shadow`); no pluggable modules.
- **Containers / cgroups**. Plan 9 namespaces are the substitute;
  per-process namespace is the only isolation surface.

## Implementation surface — shipped phases

All phases below landed across the 2026-05-26..27 wave. The
`scripts/test_security.sh` regression covers the boundary in 13 phases.

| Phase | Description | Shipped at |
|------:|-------------|-----------|
| 1 | `uid`/`gid` fields on TaskStruct; inherited on fork; passed through `rfork`. New `SYS_GETUID=288` / `SYS_GETGID=289` / `SYS_SETUID=290` (hostowner-only). | `cf041e5` |
| 2 | `/etc/passwd` (`name:uid:gid:home:shell`) + `/etc/shadow` (`name:$6$<salt>$<hash>:<days>`) formats; parser library at `lib/passwd/{passwd,shadow}.ad`. | `75214c1` |
| 3 | SHA-512-crypt (`lib/crypt/sha512_crypt.ad`) — glibc-compatible `$6$` (5000-iteration Linux default); built on `lib/sha2/sha512.ad`. | `0bb5f3c` |
| 4 | `#auth` cdev at `/dev/auth` (`sys/src/9/port/devauth.ad`) — kernel-side credential check via `/etc/shadow` + rate limit; userland never sees hashes. | `f5e9982` |
| 5 | VFS permission check on `open`/`create`/`exec` (owner/group/other rwx). | `931bf0d` |
| 6 | ext4 stamps owner/group/mode on inode create; `ext4_mkfs` lays down the root as hostowner. | `b42c243` |
| 7 | `newshell <user> [-c <cmd>]` + `read [-s] VAR` hamsh builtins (Plan-9-shape elevation; `read -s` mutes echo for password prompts). | `deb8bb1`, `43d7499` |
| 8 | hpm write commands gate on uid==1; read-only commands (`list`, `search`, `show`) are unrestricted. | `8721866` |
| 9 | `svc` switches uid before `exec` per `/etc/svc/<name>.hamsh`'s `uid:` field; sshd runs as system uid 2. | `363263d` |
| 10 | `/etc/users/<name>.ns` per-user namespace recipe loaded at `newshell`-spawned interactive shell; falls back to `/etc/users/default.ns`. | `43d7499`, `ac0bf0d` |
| 11 | Live ISO bakes `live:hamnix` as the single hostowner; system users `sshd` (uid 2) + `hamsh-svc` (uid 3) baked in `/etc/passwd`. | `ac0bf0d` |
| 12 | Installer prompts (`etc/install.hamsh`) for hostowner credentials; non-interactive overrides via `HAMNIX_HOSTOWNER_USER` / `HAMNIX_HOSTOWNER_PASSWORD`. | `ac0bf0d` |
| polish | Boot-time uid fallback; svc setuid error codes. | `0212f17` |

Test coverage (`scripts/test_security.sh`, covers Phases 1/4/5/6/7/8/9, expanded header at `ae15032`):
- A regular user can't open `/dev/blk/vda`.
- A regular user can't open `/var/lib/hpm/installed.json`.
- A regular user running `hpm install` is rejected with the
  hostowner-required message.
- `newshell hostowner` (correct password) succeeds; wrong password
  fails; rate-limited (1 attempt/second to thwart brute force).
- Service running as uid 50 can't read another service's state dir.

## Cross-refs

- [`docs/packages.md`](packages.md) — hpm; gates on uid==1
- [`docs/architecture.md`](architecture.md) — namespace + file
  server primitives this builds on
- [`docs/rootfs_partition.md`](rootfs_partition.md) — `#by-id/...`
  and named server semantics; restricted users don't see these
- `init/svc.ad` — service supervision; will gain `uid:` support
