# /etc/rc.boot — Hamnix boot rc, interpreted by hamsh running as PID 1.
#
# This file IS init. The kernel ELF-loads /init (a 2-line shim that
# execs /bin/hamsh /etc/rc.boot); hamsh-as-init sources this script,
# then drops to the interactive prompt. Everything the old hard-coded
# user/init.ad did — the "V0 namespace recipe" — now lives here as
# plain hamsh statements you can edit without recompiling anything.
#
# HAMSH_SPEC §9: the prompt IS the outermost namespace; a `bind` at
# top level mutates that ambient namespace and persists. §11: the
# init / service supervisor falls out of `spawn` + handles.
#
# Syntax notes (hamsh is not bash — these matter):
#   - '#' starts a comment; device-letter names like '#s' MUST be
#     single-quoted so the lexer does not eat them as a comment.
#   - '[' ']' are list-literal syntax and ':' is its own token, so
#     marker text that contains them is single-quoted into one word.
#   - `bind SRC DST` grafts the source SRC onto the lookup name DST.
#     Source-first matches BOTH Linux's `mount source target` AND
#     Plan 9's `bind new old` (which is itself source→target). Old
#     `bind /srv '#s'` snippets in this tree were a wrapper bug —
#     not a "Plan 9 style" choice.

echo 'rc.boot: hamnix boot rc starting'

# --- the namespace recipe -------------------------------------------
# The kernel exposes raw devices under '#X' letter aliases (it knows
# letters, not paths). These three binds give them their conventional
# Plan 9 path names in the ambient namespace. Every command hamsh
# later spawns inherits this table via its COW Pgrp clone.
#
#   bind '#s' /srv    — name-server directory (source-first)
#   bind '#p' /proc   — per-task introspection (status / ns / ...)
#   bind '#/' /n      — conventional mount-point parent
#
# '#c' (console) is deliberately NOT bound onto /dev: vfs.ad already
# ships /dev/cons as a direct cdev, and grafting the single-file
# console device over the /dev directory would shadow /dev/null,
# /dev/cpuinfo, etc. /dev is the Layer-1 byte-source pile; the
# '#'-namespace is Layer 2 — they coexist without binding together.
bind '#s' /srv
bind '#p' /proc
bind '#/' /n

# Rootfs partition (Plan 9 shape, docs/rootfs_partition.md). The
# kernel auto-discovered the ext4 partition at boot via
# mount_rootfs_partition() and (Phases 3-6) registered it under the
# sentinel-declared name '#distro' in the per-name file-server stack.
# Plan 9 convention: mount file servers at conventional names under
# /n. The bind here is source-first: SRC='#distro' (the partition's
# file server), DST=/n/distros (the lookup name in the shell view).
#
# This `bind` snapshots the Chan at bind time per plain Plan 9
# chan.c — already-bound paths cannot be yanked by hot-plug, even
# if another partition later pushes a duplicate '#distro' onto the
# named stack. Only fresh binds re-consult the stack.
#
# The shell sees:
#   /n/distros/usr/bin/dpkg       — read the real Debian dpkg
#   /n/distros/home/me/myfile     — write user files to the partition
#
# Anything `apt install` writes from inside `enter linux { ... }`
# lands at /n/distros/usr/bin/<X> (because the linux ns rebinds
# '#distro' at /). The shell's own /usr/bin/ stays Hamnix-native
# (cpio-served); apt cannot shadow Hamnix paths.
bind '#distro' /n/distros
echo 'rc.boot: namespace recipe applied (rootfs at /n/distros)'

# --- boot services --------------------------------------------------
# A boot service is a namespace template (HAMSH_SPEC §11) plus a
# `spawn` of a command into it. `bootns` is an empty overlay: it adds
# no binds of its own, so a spawned service simply inherits the boot
# namespace assembled above.
bootns = ns {
}

# motd — print the message of the day. Launched as a detached service
# (HAMSH_SPEC §11: `spawn detached` = a process that outlives the
# shell, the daemon path). motd is short-lived so it just prints and
# exits; the detached spawn proves the rc launches services the way
# a real init/service-supervisor does.
motdsvc = spawn detached bootns {
    motd
}

# sshd — the in-tree SSH-2 server (user/sshd.ad → /bin/sshd). Promoted
# from `spawn detached` to a managed service supervised by hamsh-as-
# init. The definition lives at /etc/svc/sshd.hamsh; `svc start sshd`
# parses it, registers the entry, and forks /bin/sshd as a non-
# detached child of PID 1 (so the supervisor can reap it). Restart
# policy in the .hamsh file is on-failure with 1 s..30 s exponential
# backoff — if sshd crashes after handling its bounded number of
# sessions, the supervisor brings it back without operator action.
# After this line a `svc status sshd` shows the service as running
# with its current pid.
svc start sshd

echo 'rc.boot: boot services launched'

# Static-IP fallback (DISABLED by default).
#
# Earlier revisions of this rc UNCONDITIONALLY overrode the kernel's
# DHCP-bound config with a hard-coded 10.250.10.99 / 10.250.10.1.
# That was useful for ONE specific edge case — a Skull Canyon NUC
# whose e1000e I219 PHY/MAC init wasn't yet driving DHCP cleanly —
# but it broke DNS / connectivity in every OTHER environment where
# DHCP DOES work: QEMU/SLIRP user-mode networking (10.0.2.x),
# GNOME Boxes, and almost every home / office LAN. The override
# pointed the system's DNS at 10.250.10.1 which isn't reachable
# from a normal SLIRP guest, so `hpm refresh` would print
# "cannot resolve 255.one" and bail.
#
# Default policy: let DHCP win. The kernel runs the DHCP discover/
# offer/request/ack handshake during early init (see init/main.ad
# around the dhcp_discover() call) and latches cfg_src=dhcp on
# success. We do nothing here — the kernel state is the source of
# truth. If DHCP failed, `ifconfig` below prints "(none)" and the
# operator can pin a static config by hand:
#
#   ifconfig eth0 10.250.10.99 netmask 255.255.255.0
#   ifconfig gw   10.250.10.1
#   ifconfig dns  1.1.1.1
#
# Or, for the NUC-style "DHCP not yet driving on this chip" case,
# uncomment the block below (or the future opt-in path: a marker
# file like /etc/static-ip.conf naming the address triplet).
#
# ifconfig eth0 10.250.10.99 netmask 255.255.255.0
# ifconfig gw 10.250.10.1
# ifconfig dns 10.250.10.1

# Print the live network config (IPv4 address + netmask + gw + DNS,
# with source tag — "(dhcp)" or "(static)") so a real-hardware box
# with no working keyboard can be SSH'd into off the framebuffer. If
# DHCP hasn't landed yet the line still prints with whatever the IP
# stack has — the user can re-run `ifconfig` from any later session.
echo '----- network info (ssh in with the address below) -----'
ifconfig
echo '---------------------------------------------------------'
echo 'rc.boot:STEP-1 past ifconfig dump'

# --- the Linux runtime namespace ------------------------------------
# HAMSH_SPEC §0 + §11: running a Linux binary is NOT a bespoke
# `distrorun` command — it is a captured `ns { }` value plus an
# `enter`. This is the §0 ethos: one primitive (a Chan at a name in a
# Pgrp), many skins; no special container launcher.
#
# `linux` is the distro-shape namespace recipe (docs/distro-
# namespaces.md). It is `ns clean { }` — a HERMETIC base, NOT an
# overlay of the ambient namespace (§13). The rationale: an apt-
# installed package writes files into /bin, /sbin, /etc, /lib, /usr,
# /var. If `enter linux` overlaid the ambient namespace, those paths
# would resolve to the HOST's directories and apt would scatter
# Debian binaries through Hamnix's own filesystem. Clean isolation
# is the only safe default; the explicit `bind` list below is the
# ENTIRE sharing surface between host and container.
#
# Plan 9 shape (2026-05-26 pivot, docs/rootfs_partition.md): the
# distro tree lives on a SEPARATE ext4 partition the kernel auto-
# discovers at boot. The sentinel file `.hamnix-roots` at the
# partition root names it `distro`, so it lands in the named
# file-server stack as `#distro`. `bind '#distro' /` reaches the
# rootfs partition WITHOUT mounting it in the init namespace (the
# shell's normal view) — only this linux ns recipe sees the distro
# tree at /. Anything `apt install` writes lands on the rootfs
# partition's ext4 filesystem, but is reachable only from inside the
# linux ns. The init namespace stays Hamnix-native; the shell's /,
# /etc, /bin, ... are NEVER shadowed by the Debian tree.
#
# Fallback: if the kernel didn't find an ext4 rootfs (e.g. `-kernel
# ELF` boot with no rootfs.img attached), `#distro` resolves to
# nothing and `enter linux { ... }` calls fail with -ENOENT. The
# legacy in-cpio /var/lib/distros/default path is also still bound
# below for backward compat with the rich-cpio test fixtures that
# bake the distro tree into the kernel ELF (set HAMNIX_CPIO_LEAN=0).
#
# The share list below is deliberately minimal — only paths that are
# safe to expose to a foreign-distro binary, where "safe" means
# nothing a package manager writes to:
#   /home  — user data files; the whole point of running a Linux
#            tool is usually to operate on user files.
#   /dev   — virtual devices (#c console + the rest); the only way
#            a containerised binary can talk to the user.
#   /proc  — process introspection (#p); useful for ps-style tools,
#            and the kernel scopes its view per-task anyway.
#   /srv   — 9P server registry (#s); Linux daemons can post and
#            consume 9P services here without touching distro paths.
#   /n     — Plan 9 mount-point parent (#/); conventional location
#            for ad-hoc remote / per-task mounts.
# NOT shared: /bin, /sbin, /lib, /lib64, /usr, /etc, /var, /opt,
# /root, /tmp — every path a package would land in. Those stay
# entirely inside the distro tree, so `apt install` cannot pollute
# the host.
#
# A captured `ns {}` is a TEMPLATE — configured, not entered (§11).
# Running a Linux binary is then plain namespace verbs:
#
#   enter linux { /bin/apt update }       # synchronous
#   svc = spawn linux { /bin/postgres }   # service
#
# `debian` is an rc-defined ALIAS for the same template. Because
# hamsh's `=` does NOT propagate captured ns-values through plain
# variable reassignment (a captured ns carries a body-node pointer
# in val_pay — `debian = linux` would copy the value cell but the
# scope_set path goes through eval_expr-which-yields-a-fresh-cell,
# so we duplicate the body under both names instead). This reads
# naturally when the distro IS Debian: `enter debian { apt update }`.
echo 'rc.boot:STEP-2 about to capture linux ns template'
linux = ns clean {
    bind '#distro' /
    bind /home /home
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
    bind /tmp /tmp
}
echo 'rc.boot:STEP-3 captured linux ns; capturing debian ns'
debian = ns clean {
    bind '#distro' /
    bind /home /home
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
    bind /tmp /tmp
}
echo 'rc.boot:STEP-4 captured debian ns'
echo 'rc.boot: linux runtime namespace defined (enter linux { ... }, enter debian { ... })'

echo 'rc.boot:STEP-5 about to hand off to interactive shell'
echo 'rc.boot: init complete -- handing off to interactive shell'
