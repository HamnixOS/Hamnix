# sys/src/9/port/

This directory holds Layer 1 (Plan 9-shape) syscall bodies. The path
mirrors 9front's `/sys/src/9/port/` so a reader who knows the Plan 9
tree can find the analogue at a glance. As of Phase B / M16.93 the
only resident is `error.ad` (the `errstr` machinery); subsequent
phases land `sysproc.ad` (rfork/exec/wait/exit), `chan.ad` (bind/
mount/unmount), `sysfile.ad` (open/read/write/close/seek/stat/create)
alongside it. See `docs/architecture.md` and `docs/native-api.md` for
the layered model and the per-call contracts.
