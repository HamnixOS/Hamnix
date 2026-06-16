# Userland & Desktop Environment

> **⚠ DE rearchitecting (2026-06-15):** the desktop is being gutted and
> rebuilt on the **scene-file** model — windows publish a human-readable
> display-list file (`/dev/wsys/<wid>/scene`) that the compositor reads,
> z-orders, and rasterizes; server-side window decorations. The design of
> record is [../de_scene_file_arch.md](../de_scene_file_arch.md). The
> pixel-pushing description below documents the *legacy* stack still in
> the tree until the rewrite lands.
>
> **Source of truth:** `user/` (all `.ad`), `user/x11/`,
> `sys/src/9/port/devwsys.ad`, `drivers/video/fb_cdev.ad`
> **Last verified against source:** 2026-06-10
> (the new window-system design lives in [../de_scene_file_arch.md](../de_scene_file_arch.md);
> the shell in [hamsh.md](hamsh.md))

## Purpose

The native (Adder) userland: ~160 binaries — the coreutils, the system
daemons, and the **hamUI desktop environment** (a file-server-per-window
compositor with a MATE/GNOME2-style panel). These are Layer 3/5 programs
that run in init's default Plan-9 namespace (NOT the Linux distro
namespace; that's where apt/dpkg/bash live — see
[../distro-namespaces.md](../distro-namespaces.md)).

## Key files

### Desktop environment

| Path | Role |
|--|--|
| `user/hamUId.ad` | the compositor/window-manager daemon: reads `/dev/wsys/<N>/...` per window, rasterizes layers, renders the MATE-style panel/taskbar, handles window management (move/resize/maximize/snap/minimize/workspaces, Alt-Tab MRU, window-shade, keep-below), mouse + scroll-wheel routing into the focused window |
| `sys/src/9/port/devwsys.ad` | the kernel `/dev/wsys` file server backing each window (per-window damage tracking, draw-listing cache) |
| `drivers/video/fb_cdev.ad` | `/dev/fb` framebuffer the compositor presents into (dirty-rect) |
| `user/hamfm.ad` | TUI file manager (panel "Applications" entry) |
| `user/vi.ad` | modal text editor |
| `user/x11/` | first-slice native X11 server over `/net/tcp` (`x11srv.ad`, `x11proto.ad`) + demos |

### System daemons / services

| Path | Role |
|--|--|
| `user/init.ad` + `user/init.lds` | PID-1 init shim plumbing |
| `user/service.ad` / `user/initctl.ad` | service supervisor + `service`/`initctl` CLI; runlevels |
| `user/distrofs.ad` | the 9P daemon that serves the Linux **distro namespace** (`#distro`) |
| `user/sshd.ad` | SSH server (talks `/net/tcp`) |
| `user/httpd.ad` + `user/httpd_worker.ad` + `user/httpdconf.ad` | concurrent HTTP server (per-connection workers, vhosts, CGI) |
| `user/crond.ad` + `user/crontab.ad` | cron daemon + CLI |
| `user/ntpd.ad` | NTP client (syncs wall clock via `/net/udp`) |
| `user/getty.ad` | TTY login spawner |
| `user/hpm.ad` | native package manager (see [../packages.md](../packages.md)) |
| `user/man.ad`, `user/help.ad` | man pages + help |
| `user/install_rootfs_from_manifest.ad` | installer helper |

### Coreutils + survival tools

~120 small binaries: `ls`, `cat`, `cp`, `find`, `grep`, `awk`, `sed`-like
tools, `du`, `df`, `ps`, `top`, `dmesg`, `tar`, `gzip`/`gunzip`, `curl`,
`wget`, `dd_blk`, `ping`, `ifconfig`, `route`, `date`, `cal`, `column`,
`tree`, `hxd` (hex viewer), `hdu` (disk usage), `hlog` (log viewer), and
the rest. Network clients share `user/http9.ad` (HTTP/9P client glue).

## Architecture & data structures

- **File-server-per-window UI**: each window is a directory
  `/dev/wsys/<N>/` with files `text`, `output`, `cmd`, `ns`, `pid`,
  `uid`, `kind`, `geometry`, and a layered draw tree under `draw/`
  (served by `sys/src/9/port/devwsys.ad`). `hamUId.ad` is a userland
  renderer: it reads the per-window markup/framebuffer layers
  (`read_layer_markup`, `read_layer_fb`, `parse_color`, `raster_rect`,
  `raster_text`, `raster_glyph`, `raster_image_fb`) and composites them
  into `/dev/fb`. (Legacy; the new protocol is in [../de_scene_file_arch.md](../de_scene_file_arch.md).)
- **AI-debuggability**: because windows are files, an agent can
  `cat /dev/wsys/N/text` to read screen content and
  `echo cmd > /dev/wsys/N/cmd` to drive a window from a serial console.
- **Services**: `user/service.ad` is the supervisor (restart-on-crash,
  persistent logs at `/var/log/svc/<name>.log`), driven by `runlevel:`
  bitmasks in service declarations and the `service`/`initctl` CLIs. Boot
  is `/etc/rc.boot` (plain hamsh).

## Entry points

Each binary has a `main`. DE-specific entry points in `user/hamUId.ad`:
`font_init`, `target_clear`/`layerbuf_clear`, `layer_put`, the `raster_*`
family, `read_layer_markup`/`read_layer_fb`/`read_layer_opacity`,
`parse_listing` (window draw-list parse), `build_path` (wsys path build).

## Invariants & gotchas

- **Two app languages only**: Adder (these binaries) and hamsh (scripts).
  No third Python-like tier. Do not reimplement Linux userland (apt,
  dpkg, bash, coreutils-GNU) in Adder — that's the Debian distro
  namespace's job ([../distro-namespaces.md](../distro-namespaces.md)).
- DE performance is dirty-rect/damage-clipped: the compositor consumes
  binary RECT dirty-rect present from `/dev/fbctl` and caches per-window
  backbuffers. Naive full-frame redraws regress to ~1fps (documented).
- Native programs use **ctl-file writes** for process/resource control
  (`echo pri -5 > /proc/PID/ctl`), not Linux syscalls — those are only in
  the Linux ABI shim.

## Related docs

- [../de_scene_file_arch.md](../de_scene_file_arch.md) — the scene-file `/dev/wsys` window architecture (current design of record).
- [hamsh.md](hamsh.md) — the shell / PID-1 language.
- [networking.md](networking.md) — `/net` that sshd/httpd/curl/ntpd use.
- [../packages.md](../packages.md), [../distro-namespaces.md](../distro-namespaces.md).
