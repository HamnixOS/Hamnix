# Hamnix security model — Plan 9-shape, namespace-as-authority

> **Status:** v1 is shipped across `b40e874`..`ae15032`
> (2026-05-26..27). Every phase below has a "Shipped at" line citing
> the landing commit. The Plan-9-shape model is the live model;
> `/dev/auth`, `newshell`, the hpm uid==1 gate, the live ISO
> credentials (hostowner password `hamnix`; the live session logs in
> as the default regular user `live`), and the installer credential prompts
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
hostowner:x:1:1::/home/hostowner:/bin/hamsh
alice:x:1000:1000::/home/alice:/bin/hamsh
```

Format: `name:passwd:uid:gid:gecos:home:shell` — standard 7-field
passwd(5). The passwd field is always `x` (hashes live in
`/etc/shadow`) and gecos is empty. This is the SAME file bound into the
Linux namespace, so busybox/glibc/apt parse it without "bad record".

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

### Live-image default login (normal-distro shape)

Like a normal Linux live image, the live session **logs in as a regular
user, not the admin**. The live ISO ships:

- `hostowner` (uid 1) — the admin. Password `hamnix`.
- `live` (uid 1001) — the default REGULAR login user. The live console
  (and DE) boot in AS `live`; `whoami` reports `live`.
- `dave` (uid 1000) — a second regular user used by the auth fixtures.

`rc.boot` does all its privileged setup as the hostowner and then, on the
live-image branch only, **drops the interactive console to `live` with
`setuid 1001`** before handing off. To do admin work you elevate
explicitly with `newshell hostowner` (password `hamnix`) — the
factotum-shape re-login idiom, exactly like `sudo` on a normal distro.
The `-kernel` developer boot and the installed system take the other
`rc.boot` branches and stay hostowner (no login manager yet — the
installed-system per-user auto-login is a follow-up).

The **installer** lets you pick your own regular-user name (like
Ubuntu's install-time user) and set the hostowner password; see
`etc/install.hamsh`.

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
delegates to that server's policy function. F10-2 (#455) moved each
policy body INTO its server's .ad file (see the table below); the
dispatcher imports each `<server>_perm_check` and calls it.

`vfs_link` and `vfs_symlink` (along with `vfs_open` / `vfs_open_write`
/ `vfs_perm_check_exec` / `vfs_open_kernel`) now all resolve the
caller's path through the per-Pgrp namespace BEFORE invoking the
dispatcher, so every gate call sees the resolved `#X/...` form. An
unbound path returns ENOENT at the F1 substrate gate before reaching
the perm check.

| Server | Policy lives in (F10-2 #455) | v1 policy |
|--------|------------------------------|-----------|
| `#r` cpio | `_perm_check_cpio` (fs/vfs.ad — the cpio backend has no .ad of its own; the mode-bit lookup is inline) | reads consult per-entry mode bits in the cpio header; writes categorically denied (cpio is baked) |
| `#t` tmpfs | `tmpfs_perm_check` (fs/tmpfs.ad) | world-r/w (v1 tmpfs has no per-file owner/mode storage; TODO: tighten when TmpfsEntry grows uid/gid/mode) |
| `#e` ext4 | `ext4_perm_check` (fs/ext4.ad), via vfs.ad's `_perm_check_ext4` shim | enforces on-disk inode mode bits (owner→group→other selector) at the ext4 backend boundary |
| `#f` FAT | `fat_perm_check` (fs/fat.ad) | world-r/w (FAT volumes carry no per-file POSIX overlay; the device-policy "this stick is read-only" distinction is at the block layer) |
| `#c` devs | `devcons_perm_check` (sys/src/9/port/devcons.ad) | world-r/w on the stateless cdevs (cons/null/zero/random/time/pid/cpuinfo/meminfo/uptime/loadavg/version/hostname/stat/mounts/diskstats/mouse); hostowner-only knobs (`/dev/wsys/ctl`, `/dev/keymap` write) are gated at the cdev itself |
| `#b` block | `devblk_perm_check` (sys/src/9/port/devblk.ad) | hostowner-only (`caller_uid == 1`); raw block has no userland reach surface |
| `#p` proc | `devproc_perm_check` (sys/src/9/port/devproc.ad) | reads world-OK; writes to `/proc/<pid>/{ctl,note,notepg,oom_score_adj}` require `caller_uid == target_uid` OR `caller_uid == 1`; `/proc/svc/ctl` is world-write (the supervisor is the policy point); `/proc/self/<leaf>` always admits the caller |
| `#s` srv | `devsrv_perm_check` (sys/src/9/port/devsrv.ad) | world-r/w (SYS_SRV_POST validates the poster against the srvfd it's publishing; `#s` is a rendezvous, not a permission store) |
| `#I` net | `devnet_perm_check` (drivers/net/devnet.ad) | reads world-OK; per-connection writes world-OK (sockets are user-level); host-level admin writes (`/net/dns` server pin, `/net/ipifc/ctl`, `/net/addr`) require `caller_uid == 1` |
| `#auth` | `devauth_perm_check` (sys/src/9/port/devauth.ad) | world-r/w on the wire (anyone must be able to authenticate); the rate-limit (1/sec) + constant-time hash compare INSIDE the cdev are the real gate; the `setpass` verb's uid==self-or-1 gate lives inside `_au_setpass` |
| `#/` root slot | no body — the dispatcher returns 0 inline | bind/mount is the gate (the slot is the namespace anchor, not a backed file server) |
| `SERVER_UNKNOWN` | conservative trap | F10-2 default-deny: a path that doesn't match a known `#X` letter and doesn't fit a known FS-kind returns `EPERM_PERM`. Pre-F10-2 this fell through to cpio (server 1) — the audit's "silent grant" finding |

The kernel vfs has **no literal-path arms**. There is no `/etc/shadow`
clause, no `/var/lib/hpm/` clause, no `/dev/blk/*` clause inside vfs;
each of those is enforced where it belongs — ext4 mode bits at the
ext4 backend, hpm at the userland `hpm` tool's `uid==1` gate, raw
block at `devblk_perm_check`.

There is a **hostowner (uid 1) bypass at the dispatcher** that admits
the historical Plan 9 convention "the hostowner owns the system." It
is applied for the on-disk servers (`#e`, `#t`, `#r`) where the
0600-mode `/etc/shadow` file would otherwise deny the legitimate
hostowner read. Each server's policy retains the final say: `#b`
(`devblk_perm_check`) requires `uid == 1` rather than admitting a
bypass, `#p` (`devproc_perm_check`) admits hostowner for per-task
writes (the Linux/Plan-9 nice rule), and a future per-user homedir
server can ignore the bypass by returning `EPERM_PERM` for `uid == 1`
from its own policy. The bypass is the **floor**, not the ceiling.

### F10-2 #455: where the bodies actually live

Pre-F10-2, every `_perm_check_<server>` body lived in `fs/vfs.ad` (the
dispatcher's file), and most of them were stubs that returned 0 with
a comment ("the backend enforces"). The F10 audit (audit_F10_report.md
finding F10-2) called this out: the "policy lives at the server" claim
was held in NAME ONLY. F10-2 moved every body INTO its server's file
(see the rightmost column above) and tightened the eight stub policies
to do something real:

* `devblk_perm_check`: `caller_uid == 1` — hostowner-only on raw block.
* `devproc_perm_check`: per-task uid match for writes; world-OK reads.
  Plus a defense-in-depth uid gate INSIDE the ctl handler (the `pri` /
  `oomadj` / `policy` verbs re-check the rule on the verb application,
  so any direct `devproc_write` reach that bypassed the dispatcher
  still refuses cross-user). This is the audit's F10-7 fix (the `pri`
  verb previously had no uid gate at any layer).
* `devnet_perm_check`: host-level admin writes require hostowner;
  per-conn writes and all reads admit world.
* `devcons_perm_check` / `devsrv_perm_check` / `devauth_perm_check` /
  `tmpfs_perm_check` / `fat_perm_check`: explicitly admit world (the
  policy that fits each surface's contract — auth needs everyone, srv
  is a rendezvous, tmpfs/FAT have no mode storage in v1, the cdev
  knobs gate at the cdev). Each carries a comment naming why and
  (where applicable) a TODO for the future-tightening direction.
* `SERVER_UNKNOWN` is a new sentinel: `_path_owning_server` returns it
  for paths that match no known `#X` letter and no FS-kind, and the
  dispatcher maps it to `EPERM_PERM`. This is defense-in-depth — the
  F10-1 namespace resolve already returns ENOENT for unbound paths, so
  the trap only fires for kernel-direct callers that bypassed
  resolve_path. After F10-2, `vfs_link` and `vfs_symlink` also call
  `resolve_path` first, so the only chan_permission_check callers that
  could ever pass an unknown path are pre-existing in-kernel mediator
  helpers — those route through `vfs_open_kernel` (which resolves) or
  carry their own resolution.

`scripts/test_perm_unknown_path.sh` is the acceptance gate.

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

### F10-3 #456: default task uid model

The uid model is **explicit by construction**, not by accident. Two
named constants in `kernel/sched/core.ad` carry it:

| Constant | Value | Meaning |
|----------|-------|---------|
| `UID_HOSTOWNER` | 1 | The Plan-9 "glenda" / single system administrator. Owns the rootfs, runs `hpm`, edits `/etc/shadow`. |
| `UID_NOBODY` | 65534 | The DEFAULT for every freshly-spawned task with no real parent identity. |

The rules:

1. **`kthread_create` stamps `UID_HOSTOWNER`.** Kernel threads run in
   kernel context, have no userland surface, and are trusted by
   construction (the kernel binary contains them).
2. **`create_user_thread` inherits from the parent.** Fork and CLONE_THREAD
   both copy `task_table[current_idx_pcpu].uid` into the child. This is
   the Plan-9 contract: "child gets parent's identity."
3. **The boot-time fallback in `create_user_thread` is `UID_NOBODY`.**
   When `parent_uid == 0` (current task is the all-zero boot slot 0),
   the fresh task lands at NOBODY (65534), NOT hostowner. Pre-F10-3 the
   fallback was 1, which made every userland program before login run as
   hostowner and silently fired the dispatcher's `uid == UID_HOSTOWNER`
   bypass for the on-disk servers.
4. **PID 1 (init) is upgraded to `UID_HOSTOWNER` EXPLICITLY.** Right
   after `create_user_task(init_entry, ...)` returns the freshly-allocated
   slot, `init/main.ad` calls
   `set_task_uid_at(parent_slot, UID_HOSTOWNER)`. The boot path then
   `start_first_task`s into PID 1, which is hostowner. There is no
   window where PID 1 could be dispatched in the NOBODY state because
   `start_first_task` only runs after the explicit setter retires.
5. **Every subsequent task inherits.** hamsh forks from PID 1 (hostowner).
   Its children, and their children, all inherit hostowner — until a
   login flow explicitly downgrades them.
6. **The login flow downgrades via `SYS_SETUID_AUTH`.** The user types
   `su <name>` (or logs in over sshd / getty); the flow opens
   `/dev/auth`, authenticates the password, and calls `SYS_SETUID_AUTH`
   to flip the calling task's uid to the authenticated user's value.
   Hostowner downgrades via `SYS_SETUID(N)` directly — the arch arm
   gates on `current_task_uid() == UID_HOSTOWNER`, so a regular user
   can never elevate, only downgrade themselves.
7. **Kernel-context entry points bypass the gate.** `vfs_open_kernel` /
   `vfs_open_write_kernel` are the in-kernel-mediator paths (devauth's
   `_au_read_live_file`, `_au_setpass`); they don't go through
   `chan_permission_check`, so they read/write 0600 files without
   needing the caller's task uid to be hostowner. The kernel is trusted
   by construction. No userland-reachable syscall opens these.

`scripts/test_default_uid.sh` is the acceptance gate: a hamsh-spawned
fixture asserts initial uid == 1, downgrades to 65534, and confirms
the dispatcher denies `/dev/blk/sd0` to NOBODY (the per-server
hostowner-only policy in `devblk_perm_check` actually fires once the
hostowner bypass is no longer the default).

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
file server means writing a new `<server>_perm_check` in the server's
own .ad file and importing it from `fs/vfs.ad`'s dispatcher; the
dispatcher gains one new arm. No existing servers see their policy
churn when that lands. (F10-2 moved every existing body to its
server's file — only the cpio reader stays inline in `fs/vfs.ad`
because the cpio "backend" is fs/cpio.ad's read-only blob and its
mode-bit lookup is six lines.)

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
sshd:x:2:2::/var/empty:/bin/false
hamsh-svc:x:3:3::/var/empty:/bin/false
postgres:x:50:50::/var/lib/postgres:/bin/false
nginx-svc:x:80:80::/var/empty:/bin/false
```

`/bin/false` shell means no interactive login.

## Live ISO

The live ISO ships with hostowner `live` / password `hamnix`:

```
# /etc/passwd
live:x:1:1::/home/live:/bin/hamsh

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
| 2 | `/etc/passwd` (`name:passwd:uid:gid:gecos:home:shell`, std 7-field) + `/etc/shadow` (`name:$6$<salt>$<hash>:<days>`) formats; parser library at `lib/passwd/{passwd,shadow}.ad`. | `75214c1` |
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

## CPU hardware mitigations (SMEP / SMAP / KASLR)

Wired in `arch/x86/kernel/cpu_mitigations.ad` + `arch/x86/kernel/cpu_kaslr.ad`.

### SMEP (Supervisor Mode Execution Prevention) — **ENABLED**

CR4 bit 20. Blocks CPL=0 instruction fetches from user (US=1) pages.
Enabled early in `start_kernel` (`setup_smep_smap`), after re-stamping the
kernel high-half PML4[511] subtree and the low identity (PML4[0]) US=0.
`[cpu-mitig] SMEP enabled` / `[mitig] CR4 SMEP=1` on the boot log.

### SMAP (Supervisor Mode Access Prevention) — **ENABLED + ENFORCEMENT-PROVEN**

CR4 bit 21. A CPL=0 load/store to a user (US=1) page #PFs unless
RFLAGS.AC=1. Kernel↔user copies bracket their access with STAC/CLAC.

`SMAP_RUNTIME_ENABLE = 1` (was gated off through v3a–v3f — see the
cpu_mitigations.ad comment block for the full history).

**v3g root cause + fix (2026-06-21):** the prior triple-fault was an
*ordering clobber*. `setup_smep_smap` restamped the low identity US=0 and
flipped CR4.SMAP=1 EARLY, then `mem_init()`→`pgtable_extend_from_e820()`
force-stamped the low-identity PDPT back to US=1 (`0x87`) on the EFI path,
clobbering the restamp; with SMAP on and low identity US=1, the next CPL=0
access triple-faulted at `start_first_task`. Fix: split out
`setup_smap_late()` (SMAP restamp + CR4.SMAP flip), called from
`start_kernel` AFTER `mem_init()` so the US=0 restamp is the LAST writer to
those leaves before the ring-3 hand-off.

**STAC/CLAC audit (v3g):** all prior brackets (v3c–v3e) verified intact —
`syscall_64.S` entry+SYSRET tails, `_build_user_argv[_linux]`,
`deliver_signal_to_user`/`deliver_fault_sigsegv`, `_u_rt_sigreturn`,
`trap_diag` user-RIP read, `cow_resolve_pte`. Three NEW unbracketed CPL=0
kernel→user writes were found and bracketed under enforcement:
- `kernel/core/coredump.ad` — direct user-page snapshot memcpy.
- `kernel/sched/core.ad` — `clear_child_tid` zero-store on task exit.
- `arch/x86/kernel/syscall.ad` `do_wait4` — `wstatus_ptr` status write
  (this one killed the cow-fork test's waiting parent until bracketed).

**v3h exhaustive audit (2026-06-21):** v3g bracketed only the 3 sites it
happened to hit; v3h is a full static sweep of EVERY kernel path that
dereferences a user virtual address at CPL=0. The sanctioned patterns are
(a) route through `mm/uaccess.ad` (`copy_*_user` / `get_user_*` /
`put_user_*` / `strncpy_from_user` — user VA → phys via the US=0 identity
window), or (b) wrap the raw deref in the gated `_ua_stac()` / `_ua_clac()`
bracket (no-ops when `cpu_mitig_smap_active()==0`). No new bracket primitive
was needed. Sites found unbracketed and FIXED:

| File | Path / user access | Fix |
|------|--------------------|-----|
| `linux_abi/u_syscalls.ad` | `_u_poll_scan` pollfd[] fd/events read + revents write | `_ua_stac/_ua_clac` |
| `linux_abi/u_syscalls.ad` | `_fdset_test/_clear_all/_add` select fd_set r/w | `_ua_stac/_ua_clac` |
| `linux_abi/u_syscalls.ad` | sendfile `*offset` read + write-back | `get_user_64` / `put_user_64` |
| `linux_abi/u_syscalls.ad` | copy_file_range + splice `*off_in/*off_out` r/w | `_ua_stac/_ua_clac` (read) / `_ua_*` (write) |
| `linux_abi/u_syscalls.ad` | `_u_sigset_to_kernel` signalfd sigset read | `get_user_64` |
| `linux_abi/u_syscalls.ad` | `_u_fill_statfs` struct statfs fill (statfs/fstatfs) | `_ua_stac/_ua_clac` (2 windows) |
| `linux_abi/u_syscalls.ad` | `_u_ts_to_jiffies` / `_u_jiffies_to_ts` timerfd timespec r/w | `get_user_64` / `put_user_64` |
| `linux_abi/u_syscalls.ad` | `_u_epoll_scan` epoll_event[] write | `_ua_stac/_ua_clac` |
| `linux_abi/u_syscalls.ad` | `_u_clone3` clone_args read + pidfd write | `copy_from_user` / `put_user_32` |
| `linux_abi/u_ptrace.ad` | PEEK/POKE (tracee VA), GET/SETREGS (tracer buf) | `_ua_stac/_ua_clac` |
| `linux_abi/u_iouring.ad` | READV/WRITEV iovec read + data bounce | `get_user_64` + `copy_*_user` bounce |
| `linux_abi/u_iouring.ad` | REGISTER_BUFFERS iovec read | `get_user_64` |
| `linux_abi/u_iouring.ad` | OPENAT/STATX pathname (resolve_path) | `strncpy_from_user` copy-in |
| `arch/x86/kernel/syscall.ad` | UMDF irq-fd read result write | `put_user_64` |

Paths AUDITED and confirmed already-safe (so the sweep is provably
exhaustive): rt_sigaction / rt_sigprocmask / sigaltstack / prlimit64 /
getrlimit / setrlimit (all `get_user_*`/`put_user_*`, #163); getrusage /
times / statx / getdents64 / recvfrom / nanosleep / sched_*affinity /
gettimeofday / clock_gettime (kernel-scratch + `copy_*_user`); the AF_INET /
AF_UNIX / AF_NETLINK socket bind/connect/recvmsg paths (`copy_from_user`
into a bounce; the `_l_kernel_*` helpers take KERNEL pointers); futex /
futexv (`get_user_32`/`copy_from_user`); process_vm_readv/writev
(`copy_*_user` on the remote CR3); set_robust_list (no-op); userfaultfd
(`copy_*_user` + physical-frame fill); signal delivery + sigreturn + ELF
exec stack build + COW resolve (bracketed v3c–v3e, re-verified intact); the
`copy_*_user` physical-frame fill paths (`_u_mmap_fill_file`, demand-fault,
swap-in — all write the resolved PHYS frame, never the user VA).

**Enforcement proof:** `scripts/test_smap_enforced.sh` (gated marker
`/etc/smap-test`) does an UN-stac'd CPL=0 read of a genuinely-US=1 user
page via `arch/x86/kernel/smap_probe_asm.S`; a one-entry SMAP-probe
exception table in `arch/x86/kernel/trap_diag.ad` recovers the #PF; the
test asserts the fault fired → `[smap-enforced] PASS`. **Only enforces
under a hardware accelerator** — TCG masks the SMAP CPUID bit, so the
test SKIPs cleanly there; verify under KVM (`-cpu host`). The qemu shim
(`scripts/_kernel_iso.sh`) auto-injects `-accel kvm -cpu host` when
`/dev/kvm` is usable.

`scripts/test_smap_uaccess_paths.sh` is the companion v3h gate: it boots
with SMAP on + the UABI_FILLS / SPLICE / IOURING / USERFAULTFD / STATX boot
self-tests enabled (each drives the real Linux-ABI handlers for the audited
paths, the SPLICE leg against a genuine `vaddr != phys` user page) and
asserts every one PASSes with no #PF — i.e. the bracketed
kernel-on-behalf-of-user accesses all complete under live enforcement.

### KASLR — **v1 scaffold only (offset=0); v2 documented, not landed**

`cpu_kaslr.ad` records a per-boot offset (currently hard-wired 0) and emits
`[kaslr] offset=0x0`. Real runtime kernel-base relocation (v2) needs a PIE
kernel image, an early relocation-table walker in `head_64.S` applying the
offset to all 64-bit absolute relocations before paging, an RDRAND/TSC
offset source at 16 MiB granularity over a 256 MiB range (Linux
CONFIG_RANDOMIZE_BASE shape), and pairing with KPTI for full Meltdown
mitigation. KASLR is intentionally secondary to SMAP and is left as a
documented next-step (see the NEXT-STEP block in `cpu_kaslr.ad`); it does
not block the boot.

## Cross-refs

- [`docs/packages.md`](packages.md) — hpm; gates on uid==1
- [`docs/architecture.md`](architecture.md) — namespace + file
  server primitives this builds on
- [`docs/rootfs_partition.md`](rootfs_partition.md) — `#by-id/...`
  and named server semantics; restricted users don't see these
- `init/svc.ad` — service supervision; will gain `uid:` support
