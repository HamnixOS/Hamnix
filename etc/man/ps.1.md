# ps - report a snapshot of running processes

## NAME

ps - print a per-task snapshot from /proc

## SYNOPSIS

    ps

## DESCRIPTION

Walks `/proc/tasks/` and prints one line per task: pid, parent
pid, state, comm. No flags, no thread filtering, no formatting
options.

`ps` reads from procfs only — the data is whatever the kernel's
per-task introspection exposes. The output is meant for human
reading, not machine parsing.

## EXAMPLES

    ps
    ps | grep hamsh

## SEE ALSO

pgrep(1), kill(1), top(1)
