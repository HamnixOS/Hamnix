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

### Source packages (Gentoo-style)

Native packages are SOURCE-PRIMARY with an optional binary cache.
A source package ships its Adder `.ad` source under `src/` plus a
`recipe`, and NO prebuilt binary. On `hpm install`, hpm stages the
tarball, reads the `recipe`, and compiles each `build` directive
ON-BOX with Hamnix's self-hosted Adder compiler (`/bin/adder_cc`),
then installs the freshly compiled binary at the package's target.

The `recipe` grammar:

    build <src-rel> <out-rel>   compile <src-rel> into files/<out-rel>,
                                then install at <target>/<out-rel>
    cache yes|no                (default yes) when a prebuilt
                                files/<out-rel> is shipped in the
                                tarball, reuse it instead of compiling

A package that ships a prebuilt `files/` tree and no `recipe` is
installed verbatim (the classic binary path), so binary packages
keep working unchanged. Debian-namespace `.deb` packages are out of
scope and remain prebuilt.

## FILES

- `/tmp/hpm/index.json` — refreshed index cache (tmpfs, volatile)
- `/var/lib/hpm/installed.json` — installed-package database
- `/var/lib/hpm/channels` — enabled channel list

## EXAMPLES

    hpm refresh
    hpm search editor
    hpm show ed
    newshell hostowner -c 'hpm install ed'
    # source package: compiled on-box from .ad source at install time
    newshell hostowner -c 'hpm install hello-src'

## SEE ALSO

newshell(1), man(1)
