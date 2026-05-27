# cat - concatenate files to stdout

## NAME

cat - stream one or more files to stdout

## SYNOPSIS

    cat [<file>...]

## DESCRIPTION

With no argument, `cat` drains stdin to stdout (the canonical pipe
behaviour: `... | cat` is a no-op filter). With one or more file
arguments, each is opened with `sys_open`, read in 128-byte
chunks, and written to stdout in order.

No flags, no `-n`/`-A`/`-v` numbering or escaping — just bytes.

## EXAMPLES

    cat /etc/motd
    cat /usr/share/man/man.1.md
    echo hi | cat

## SEE ALSO

more(1), less(1), head(1), tail(1)
