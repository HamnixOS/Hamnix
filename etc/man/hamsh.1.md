# hamsh - the Hamnix interactive shell

## NAME

hamsh - Hamnix's shell, also PID 1 (the init / supervisor)

## SYNOPSIS

    hamsh                       # interactive
    hamsh <script.hamsh>        # source a script
    hamsh /etc/rc.boot          # how the kernel calls it as init

## DESCRIPTION

hamsh is a Python-flavored shell with C-style `{ }` blocks and its
own small dynamically-typed evaluator. It is NOT Adder; it shares
no grammar or evaluator with the compiler.

Statement dispatch follows the first token of every top-level line:
  1. control construct (`if`, `while`, `for`, `def`, `return`,
     `break`, `continue`, `try`, `ns`, `enter`, `spawn`)
  2. assignment (`x = ...`, `x += ...`)
  3. command (the first word is the command name; bare words are
     literal strings; pipes `|` and redirects `>` work as usual)

hamsh boots as PID 1 and reads `/etc/rc.boot` as its first script.
Booting drops into an interactive prompt unless you spawn a non-
interactive replacement.

## BUILTINS

`cd`, `bind`, `unmount`, `mount`, `import`, `export`, `echo`,
`svc`, `read`, `newshell`, `exit`. See `help builtins` for a
one-line description of each.

## NAMESPACES

Every process owns a per-process namespace (Pgrp). `bind SRC DST`
grafts SRC onto the name DST; `ns { ... }` captures a template;
`enter <ns> { ... }` runs a command inside that template; `spawn`
detaches it. The shape is Plan 9: names are bindings, not
sandboxed views.

## EXAMPLES

    cd /usr/share/man
    ls *.md
    echo hello | grep ell
    bind '#distro' /n/distros
    enter linux { /usr/bin/apt-get update }
    spawn detached bootns { motd }

## FILES

- `/etc/rc.boot` — the boot script (sourced as init)
- `/etc/hamsh.rc` — optional per-shell startup script
- `/etc/svc/<name>.hamsh` — service definition file consumed by
  the `svc` builtin

## SEE ALSO

help(1), man(1), svc(1)
