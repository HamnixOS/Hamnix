# ls - list directory contents

## NAME

ls - list the entries of a directory

## SYNOPSIS

    ls
    ls <path>

## DESCRIPTION

Calls `sys_listdir(path, buf, count)`. The kernel returns
`name\n`-separated entries; `ls` writes those bytes to stdout
verbatim — there is no column formatting (yet) and no flag
support.

With no argument, `ls` lists the current working directory (the
process's per-task cwd, set by `cd`).

## EXAMPLES

    ls
    ls /
    ls /usr/share/man

## SEE ALSO

cd(1), find(1), pwd(1)
