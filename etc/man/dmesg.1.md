# dmesg - print the kernel ring-buffer

## NAME

dmesg - read /proc/kmsg

## SYNOPSIS

    dmesg

## DESCRIPTION

Opens `/proc/kmsg` and streams its contents to stdout. On Hamnix
the kernel ring-buffer is populated by every in-kernel
`printk_str` / `printk_dec` call; `dmesg` is the userland viewer.

No flags, no `-w` (follow) mode, no level filtering. The ring is
finite; once it overflows older messages are dropped.

## EXAMPLES

    dmesg
    dmesg | grep e1000e

## SEE ALSO

cat(1), top(1)
