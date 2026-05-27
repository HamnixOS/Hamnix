# df - report filesystem mounts

## NAME

df - dump /proc/mounts

## SYNOPSIS

    df

## DESCRIPTION

Reads `/proc/mounts` and writes it verbatim to stdout. On Hamnix
the mount table reflects the per-process namespace (see `bind`,
`mount` in the hamsh man page) plus any kernel-side device file
servers (`#distro`, `#s`, `#p`, ...).

No filesystem size / free-space reporting yet — there is no stat
syscall on Hamnix. `df` is currently a procfs viewer for
namespace inspection.

## EXAMPLES

    df
    df | grep distro

## SEE ALSO

mount(1) (hamsh builtin), du(1)
