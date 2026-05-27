# hpm - the Hamnix package manager

## NAME

hpm - install, list, and search Hamnix packages

## SYNOPSIS

    hpm refresh
    hpm list
    hpm search <pattern>
    hpm show <name>[@<ver>]
    hpm install <name>[@<ver>]
    hpm remove <name>
    hpm update
    hpm channels                    # list configured channels

## DESCRIPTION

`hpm` is Hamnix's native package manager (see docs/packages.md).
It speaks the simple `index.json` repo format and downloads
tarballs over HTTPS via the kernel's `/net` file tree (TLS).

Repos are configured by URL. The default is
`https://255.one/`. Override with `--repo=<url>` or
`HPM_REPO=<url>`. Channels (main / non-free / non-free-firmware)
live under `/var/lib/hpm/channels`.

`hpm install` requires hostowner credentials — package
installation is the canonical privileged operation, gated through
the `newshell` elevation idiom.

## FILES

- `/tmp/hpm/index.json` — refreshed index cache (tmpfs, volatile)
- `/var/lib/hpm/installed.json` — installed-package database
- `/var/lib/hpm/channels` — enabled channel list

## EXAMPLES

    hpm refresh
    hpm search editor
    hpm show ed
    newshell hostowner -c 'hpm install ed'

## SEE ALSO

newshell(1), man(1)
