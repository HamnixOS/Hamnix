# find - recursively walk a directory tree

## NAME

find - print every path under a starting directory

## SYNOPSIS

    find
    find <path>

## DESCRIPTION

Walks the tree rooted at `<path>` (default: cwd) depth-first and
prints each path on its own line. Maximum recursion depth is 8
levels. `find` uses `sys_listdir` for traversal; a successful
listdir means the entry is a directory, a failure means it is a
file — there is no stat syscall on Hamnix yet.

No predicates, no `-name`, no `-exec` — this is the minimal walker.
For a richer walk, pipe `find` output through `grep` or `xargs`.

## EXAMPLES

    find /etc
    find /usr/share/man | grep '\.1\.md$'

## SEE ALSO

ls(1), grep(1), xargs(1)
