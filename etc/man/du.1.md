# du - report entry counts under a path

## NAME

du - count entries beneath a directory

## SYNOPSIS

    du
    du <path>

## DESCRIPTION

Walks the tree rooted at `<path>` (default: cwd) and prints the
number of entries discovered. Without stat, `du` cannot yet
report bytes; the count is the file-system inventory size.

For a real per-file byte tally, pipe `find` through `wc -l` and
manually `cat` each entry — `du` is the placeholder until stat
lands.

## EXAMPLES

    du
    du /etc

## SEE ALSO

df(1), find(1), wc(1)
