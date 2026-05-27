# fstab - static filesystem table

## NAME

fstab - the `/etc/fstab` file format

## SYNOPSIS

    /etc/fstab

## DESCRIPTION

`/etc/fstab` is a plain text table of mountpoints in the legacy
Unix format. Each line is one mount:

    <device>     <mountpoint> <fstype> <options> <dump> <pass>

`#` starts a comment. Blank lines are skipped.

On Hamnix, `/etc/fstab` is informational only — the live mount
table is the per-process namespace, manipulated by hamsh's
`bind` and `mount` builtins. The fstab is consulted by the
installer for the initial setup, and it documents what `bind`
recipes the boot scripts assemble.

## FIELDS

- `<device>` — block device (`/dev/vda`) or virtual source
  (`procfs`, `tmpfs`, `#distro`).
- `<mountpoint>` — absolute path where the source should appear.
- `<fstype>` — `ext4`, `fat`, `proc`, `tmpfs`, `9p`.
- `<options>` — `rw`/`ro` plus mount flags.
- `<dump>` / `<pass>` — historic; ignored on Hamnix.

## SEE ALSO

mount(1) (hamsh builtin), bind(1) (hamsh builtin), hamsh(1)
