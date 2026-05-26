# sys/src/9/port/

This directory holds Layer 1 (Plan 9-shape) syscall bodies. The path
mirrors 9front's `/sys/src/9/port/` so a reader who knows the Plan 9
tree can find the analogue at a glance.

Resident files (as of the FS-discovery wave, 2026-05-26):

- `error.ad` — the `errstr` per-process error string machinery
  (M16.93).
- `chan.ad` — Chan / Pgrp / mtab / namespace primitives + the named
  file-server stack + `#by-id/<partuuid>` aliases + bind-freeze.
- `dev.ad` — the device-letter directory (`#c`, `#p`, `#s`, `#/`,
  `#d`) and `is_reserved_word()` for sentinel validation.
- `namec.ad` — `namec()` + `devtab` dispatch as the universal open
  path; resolves paths through the process's mount table to a Chan.
- `sysproc.ad` — `rfork` / `exec` / `wait` / `exits`.
- `syschan.ad` — `bind` / `mount` / `unmount` syscall bodies on top
  of `mnttab_bind` / `mnttab_mount`.
- `sysfile.ad` — `open` / `read` / `write` / `close` / `seek` /
  `create` / `stat` / `fstat` / `dup` / `pipe`.
- `sysnote.ad` — Plan 9-style notes (`/proc/<pid>/note`).
- `devcons.ad`, `devtime.ad`, `devrandom.ad`, `devpid.ad`,
  `devproc.ad`, `devmouse.ad`, `devsrv.ad`, `devfd.ad`,
  `devmeminfo.ad`, `devcpuinfo.ad`, `devuptime.ad`, `devloadavg.ad`,
  `devstat.ad`, `devhostname.ad`, `devversion.ad`, `devdiskstats.ad`,
  `devmounts.ad`, `devmountrpc.ad` — per-device cdev bodies serving
  the `#X` letter namespace.
- `9p_client.ad` — kernel-side 9P client (Tversion/Tattach/Twalk/
  Topen/Tread/Twrite/Tclunk) over a posted srvfd.

See `docs/architecture.md` for the layered model, `docs/native-api.md`
for the per-call contracts, and `docs/9p.md` for the 9P2000 wire
format.
