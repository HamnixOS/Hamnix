# top - one-shot /proc dashboard

## NAME

top - print a snapshot of system and per-task state

## SYNOPSIS

    top

## DESCRIPTION

Prints a one-shot summary: load average (from `/proc/loadavg`),
memory totals (from `/proc/meminfo`), and the per-task table
(from `/proc/tasks/`). Unlike Linux `top`, Hamnix `top` does not
redraw — it prints once and exits. Use `watch top` for a
periodic refresh.

## EXAMPLES

    top
    watch -n 2 top

## SEE ALSO

ps(1), free(1), watch(1)
