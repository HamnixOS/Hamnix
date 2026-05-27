# help - browse Hamnix's man pages

## NAME

help - print the man-page index, or show one page

## SYNOPSIS

    help
    help <topic>
    help builtins

## DESCRIPTION

`help` is the discovery counterpart to `man`. With no argument it
walks `/usr/share/man/`, opens each `*.md` file, and prints
`<topic>  - <one-line description>` for every page. The
description is the first H1 line of the file.

With a topic argument, `help <topic>` is sugar for `man <topic>` —
it spawns `/bin/man` and waits for it.

With the literal argument `builtins`, `help` lists the commands
that live inside the shell (hamsh) process rather than on disk
(cd, bind, svc, read, newshell, ...) — these have no on-disk man
page because they cannot be spawned as a separate binary.

## EXAMPLES

    help            # list everything
    help man        # this page's sibling
    help builtins   # in-shell commands

## SEE ALSO

man(1), hamsh(1)
