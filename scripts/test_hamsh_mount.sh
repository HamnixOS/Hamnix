#!/usr/bin/env bash
# scripts/test_hamsh_mount.sh — HAMSH_SPEC §18 stage 10 acceptance.
#
# Mount handles + union mounts + introspection (§14), end to end
# against a REAL 9P server:
#
#   1. `/bin/p9srv_demo post stage10srv &` — spawn the 9P server in
#      the background. In `post` mode it creates a socketpair,
#      publishes one end on the kernel /srv table as `stage10srv`,
#      and serves 9P over the other.
#   2. `m = mount /srv/stage10srv /n/r as remote` — the `mount … as L`
#      EXPRESSION. mount only ever consumes a srvfd; here it resolves
#      the `/srv/<name>` path through sys_srv_open to a srvfd, runs
#      Tversion+Tattach, records a SRV-kind mount, and stamps the
#      label `remote`. The result is a VT_MOUNT handle bound in `m`.
#   3. `cat /n/r/hello` — reads the real file the 9P server exports
#      ("p9demo says hi\n"), proving the mount carries live 9P traffic.
#   4. `cat /proc/self/ns` — the mount appears, rendered with its
#      label (` as remote`).
#   5. A union sibling — `bind -a /n/r2 /n/r` — stacks at the path;
#      `cat /proc/self/ns` shows the ` -a` union flag.
#   6. `unmount $m` — unmount BY HANDLE. The VT_MOUNT handle
#      interpolates to its label, so the SRV mount is peeled out
#      while the union bind survives. `cat /proc/self/ns` confirms.
#
# Driven prompt-synced via _qemu_drive.sh (waits for the readiness
# marker before the first byte — the 16550 RX FIFO drops input shoved
# in before the shell's read loop is live).

. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_mount] (1/3) Build userland (hamsh + p9srv_demo)"
bash scripts/build_user.sh >/dev/null

echo "[test_hamsh_mount] (2/3) Plant /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamsh_mount] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 100 \
    -- "/bin/p9srv_demo post stage10srv &"               5 \
       "echo STAGE10_GO"                                 2 \
       "m = mount /srv/stage10srv /n/r as remote"        4 \
       "echo MOUNT_STATUS reports \${ status }"          2 \
       "cat /n/r/hello"                                  3 \
       "bind -a /n/r2 /n/r"                              2 \
       "echo STAGE10_DUMP_ONE"                           1 \
       "cat /proc/self/ns"                               2 \
       "echo STAGE10_DUMP_TWO"                           1 \
       "unmount \$m"                                     2 \
       "cat /proc/self/ns"                               2 \
       "echo STAGE10_DONE"                               1 \
       "exit"                                            1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_hamsh_mount] --- captured output ---"
cat "$LOG"
echo "[test_hamsh_mount] --- end output ---"

fail=0

# The 9P server posted itself to /srv.
if grep -F -q "[p9demo] posted to /srv" "$LOG"; then
    echo "[test_hamsh_mount] OK: 9P server posted to /srv"
else
    echo "[test_hamsh_mount] MISS: 9P server did not post to /srv"
    fail=1
fi

# The mount expression succeeded (status 0) — a real Tversion+Tattach
# over the socketpair-backed /srv connection.
if grep -F -q "MOUNT_STATUS reports 0" "$LOG"; then
    echo "[test_hamsh_mount] OK: mount /srv/<name> expression succeeded"
else
    echo "[test_hamsh_mount] MISS: mount expression did not succeed"
    fail=1
fi

# Live 9P traffic: cat read the file the server exports.
if grep -F -q "p9demo says hi" "$LOG"; then
    echo "[test_hamsh_mount] OK: read a real file through the 9P mount"
else
    echo "[test_hamsh_mount] MISS: could not read through the 9P mount"
    fail=1
fi

# The FIRST /proc/self/ns dump (after mount + union bind) carries
# the labelled SRV mount AND the union sibling with its -a flag.
dump1=$(sed -n '/STAGE10_DUMP_ONE/,/STAGE10_DUMP_TWO/p' "$LOG")
if echo "$dump1" | grep -F -q 'as remote'; then
    echo "[test_hamsh_mount] OK: SRV mount shows its label in /proc/self/ns"
else
    echo "[test_hamsh_mount] MISS: SRV mount label not shown"
    fail=1
fi
if echo "$dump1" | grep -E -q 'bind /n/r2 /n/r -a'; then
    echo "[test_hamsh_mount] OK: union -a flag rendered in /proc/self/ns"
else
    echo "[test_hamsh_mount] MISS: union flag not rendered"
    fail=1
fi

# The SECOND dump is AFTER unmount-by-handle: the labelled SRV mount
# is peeled out, the union sibling bind survives.
dump2=$(sed -n '/STAGE10_DUMP_TWO/,/STAGE10_DONE/p' "$LOG")
if echo "$dump2" | grep -F -q 'as remote'; then
    echo "[test_hamsh_mount] MISS: labelled SRV mount survived unmount-by-handle"
    fail=1
else
    echo "[test_hamsh_mount] OK: unmount by handle removed the labelled SRV mount"
fi
if echo "$dump2" | grep -E -q 'bind /n/r2 /n/r -a'; then
    echo "[test_hamsh_mount] OK: union sibling survived the targeted unmount"
else
    echo "[test_hamsh_mount] MISS: union sibling disturbed by unmount-by-handle"
    fail=1
fi

# The shell survived the whole stage.
if grep -F -q "STAGE10_DONE" "$LOG"; then
    echo "[test_hamsh_mount] OK: shell survived stage 10"
else
    echo "[test_hamsh_mount] MISS: shell did not survive"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_mount] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hamsh_mount] PASS"
