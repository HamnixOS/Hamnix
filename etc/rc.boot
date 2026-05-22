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

echo 'rc.boot: boot services launched'
echo 'rc.boot: init complete -- handing off to interactive shell'
