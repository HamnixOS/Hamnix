# man - display Hamnix manual pages

## NAME

man - display the on-disk manual page for a topic

## SYNOPSIS

    man <topic>

## DESCRIPTION

`man` reads a markdown manual page from `/usr/share/man/<topic>.<N>.md`
and writes it verbatim to stdout. Sections are tried in order: 1, 4,
5, 8 (user commands, devices, file formats, admin). The first hit
wins.

Hamnix man pages are plain markdown. No troff, no compression, no
roff macros — just `cat`-able text with a structured header. This is
the Plan 9 manual-page shape: the man-page renderer is a file copy.

If no page exists for the topic, `man` writes `man: no entry for
<topic>` to stderr and exits 1.

## EXAMPLES

    man man        # this page
    man hamsh      # the shell
    man hpm        # the package manager
    man ls         # listing directories

To browse every topic with a one-line description, see `help`.

## SEE ALSO

help(1), hamsh(1)
