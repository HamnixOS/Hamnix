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
#   - `bind NEW OLD` grafts device/dir OLD onto the name NEW.

echo 'rc.boot: hamnix boot rc starting'

# --- the namespace recipe -------------------------------------------
# The kernel exposes raw devices under '#X' letter aliases (it knows
# letters, not paths). These three binds give them their conventional
# Plan 9 path names in the ambient namespace. Every command hamsh
# later spawns inherits this table via its COW Pgrp clone.
#
#   bind /srv  '#s'   — name-server directory
#   bind /proc '#p'   — per-task introspection (status / ns / ...)
#   bind /n    '#/'   — conventional mount-point parent
#
# '#c' (console) is deliberately NOT bound onto /dev: vfs.ad already
# ships /dev/cons as a direct cdev, and grafting the single-file
# console device over the /dev directory would shadow /dev/null,
# /dev/cpuinfo, etc. /dev is the Layer-1 byte-source pile; the
# '#'-namespace is Layer 2 — they coexist without binding together.
bind /srv '#s'
bind /proc '#p'
bind /n '#/'
echo 'rc.boot: namespace recipe applied'

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

# sshd — the in-tree SSH-2 server (user/sshd.ad → /bin/sshd). Long-
# lived: it accepts up to a small bounded number of sessions and then
# exits (the V1 server caps at 8 clients per process). Detached so it
# survives this rc and the interactive prompt that comes after. With
# this in place, a vanilla Hamnix ISO boots straight into "ready for
# SSH on port 22" with no INIT_ELF override needed.
sshdsvc = spawn detached bootns {
    sshd
}

echo 'rc.boot: boot services launched'

# Print the live network config (IPv4 address + netmask + gw + DNS,
# with source tag — "(dhcp)" or "(static)") so a real-hardware box
# with no working keyboard can be SSH'd into off the framebuffer. If
# DHCP hasn't landed yet the line still prints with whatever the IP
# stack has — the user can re-run `ifconfig` from any later session.
echo '----- network info (ssh in with the address below) -----'
ifconfig
echo '---------------------------------------------------------'

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
# Root rebind: `bind / /var/lib/distros/default` points every path
# that isn't covered by a longer (more specific) bind below at the
# distro tree. /etc/debian_version resolves to
# /var/lib/distros/default/etc/debian_version, and any path a package
# writes to (/bin, /usr, /var, ...) lands inside the distro tree, not
# on the host. (kernel chan.ad's chan_resolve_prefix picks the
# longest matching prefix.)
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
linux = ns clean {
    bind / /var/lib/distros/default
    bind /home /home
    bind /dev '#c'
    bind /proc '#p'
    bind /srv '#s'
    bind /n '#/'
}
debian = ns clean {
    bind / /var/lib/distros/default
    bind /home /home
    bind /dev '#c'
    bind /proc '#p'
    bind /srv '#s'
    bind /n '#/'
}
echo 'rc.boot: linux runtime namespace defined (enter linux { ... }, enter debian { ... })'

echo 'rc.boot: init complete -- handing off to interactive shell'
