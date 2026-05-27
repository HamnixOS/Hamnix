# cp - copy a file

## NAME

cp - copy one file to another

## SYNOPSIS

    cp <src> <dst>

## DESCRIPTION

Reads `<src>` into memory (up to ~8 KiB) and writes the bytes to
`<dst>`. Single-file only — no recursive directory copy, no flag
support, no `cp -r`. For tree copies, use `find` + a loop.

Both paths are passed to the kernel by C-string. Relative paths
resolve against the calling process's cwd.

## EXIT STATUS

- 0 on a successful copy.
- 1 if `<src>` cannot be opened or `<dst>` cannot be written.

## EXAMPLES

    cp /etc/motd /tmp/motd.bak
    cp /usr/share/man/man.1.md /home/me/man-help.md

## SEE ALSO

cat(1), mv(1), ln(1)
