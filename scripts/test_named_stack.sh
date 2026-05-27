#!/usr/bin/env bash
# scripts/test_named_stack.sh — Phase 9 acceptance for the named
# file-server stack (docs/rootfs_partition.md "Future direction —
# Stack semantics" + "Inspection: /proc/fs").
#
# The full bind-freeze + hot-plug story needs:
#   * Two partitions both sentinel-declaring `home` (we'd need to
#     build a custom multi-partition disk image for this).
#   * A way to push/pop entries from the test rig (the block layer
#     does not yet emit unplug events).
#
# Until the multi-partition fixture lands, this test exercises the
# pieces we CAN reach from a normal boot:
#
#   1. The boot rootfs is sentinel-declared as `distro` — verify
#      /proc/fs/by-name/distro returns a non-empty stack with the
#      partuuid + sentinel + dir fields populated.
#   2. `bind '#distro' /n/distros` (from rc.boot) snapshots the
#      named-stack top at bind time — the binding shows up in
#      /proc/self/ns and stays put (bind-freeze).
#   3. /proc/fs/by-name/<unknown> returns an empty-stack line, not
#      ENOENT — the readout is always idempotent.
#
# The two-partitions-pushing-the-same-name scenario gates on a
# kernel-side debug hook (sysfile that calls name_push with caller-
# supplied args) which is not in scope for the FS-discovery pass.
# This test asserts the visible part of the contract.
#
# DRIVER: uses the shared _qemu_drive.sh harness — waits for hamsh's
# readiness marker before feeding commands. The previous fixed-sleep
# subshell driver was flaky on slower hosts: hamsh's input editor
# could still be in the rc.boot tail when the first `printf` arrived,
# so the early commands' characters were echoed but the trailing
# newline was eaten by a state transition and the command never ran.
# qemu_drive blocks on the `[hamsh] M16.35 shell ready` banner before
# sending a single byte, which makes the test deterministic regardless
# of host CPU load.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
ROOTFS_IMG=build/hamnix-rootfs.img

bash scripts/build_user.sh >/dev/null
# /init is the normal init shim (execs /bin/hamsh /etc/rc.boot). Do
# NOT override with HAMSH_ELF — that would skip rc.boot entirely
# (no argv[1] = /etc/rc.boot) and our by-name/distro stack would have
# nothing in the ambient namespace.
python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null
# Need the rootfs image for the named-stack to have something to
# discover (its `.hamnix-roots` sentinel declares `distro`).
python3 scripts/build_rootfs_img.py >/dev/null

LOG=$(mktemp /tmp/test-named-stack.XXXXXX.log)
# Preserve LOG on failure for post-mortem; clean up only on PASS.
# (Trap below is re-armed after we know the outcome.)
trap 'rm -f "$LOG"' EXIT

set +e
# The rootfs image is mounted via the virtio disk; the kernel's
# rootfs-autodiscover walk runs early in init and (per the captured
# boot log) registers `#distro` long before hamsh prints its banner,
# so by the time qemu_drive is allowed to send `cat /proc/fs/by-name/
# distro` the named-stack already has the entry we want to read.
QEMU_EXTRA_ARGS="-drive file=$ROOTFS_IMG,if=virtio,format=raw" \
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 90 \
    -- "echo NS_DISTRO_BEGIN"                      2 \
       "cat /proc/fs/by-name/distro"               3 \
       "echo NS_DISTRO_END"                        2 \
       "echo NS_UNKNOWN_BEGIN"                     2 \
       "cat /proc/fs/by-name/nopartition"          3 \
       "echo NS_UNKNOWN_END"                       2 \
       "echo NS_FREEZE_BEGIN"                      2 \
       "cat /proc/self/ns"                         3 \
       "echo NS_FREEZE_END"                        2 \
       "echo NS_DONE"                              2 \
       "exit"                                      1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_named_stack] --- captured ---"
cat "$LOG"
echo "[test_named_stack] --- end ---"

fail=0

# The shell came up at all.
if ! grep -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[test_named_stack] FAIL: hamsh never reached the interactive loop"
    # Preserve LOG for post-mortem.
    trap - EXIT
    echo "[test_named_stack] preserved log: $LOG"
    exit 1
fi

# /proc/fs/by-name/distro must include the partuuid + sentinel + dir
# fields. The sentinel value should be `distro` (from build_rootfs_img.py).
distro_block=$(sed -n '/NS_DISTRO_BEGIN/,/NS_DISTRO_END/p' "$LOG")
if echo "$distro_block" | grep -E -q 'partuuid='; then
    echo "[test_named_stack] OK: /proc/fs/by-name/distro renders partuuid"
else
    echo "[test_named_stack] MISS: distro stack missing partuuid"
    fail=1
fi
if echo "$distro_block" | grep -F -q "sentinel=\`distro\`"; then
    echo "[test_named_stack] OK: sentinel field carries the declared word"
else
    echo "[test_named_stack] MISS: sentinel word not rendered"
    fail=1
fi

# /proc/fs/by-name/<unknown> renders a graceful "(no stack ...)" line.
unknown_block=$(sed -n '/NS_UNKNOWN_BEGIN/,/NS_UNKNOWN_END/p' "$LOG")
if echo "$unknown_block" | grep -F -q "no stack"; then
    echo "[test_named_stack] OK: unknown name produces graceful readout"
else
    echo "[test_named_stack] MISS: unknown name didn't render gracefully"
    fail=1
fi

# bind-freeze: the rc.boot `bind '#distro' /n/distros` must be present
# in /proc/self/ns (this verifies the bind actually went through and
# the path is now reachable; the LIFO-stack-mutation aspect of the
# freeze contract gates on the multi-partition fixture mentioned in
# the header).
freeze_block=$(sed -n '/NS_FREEZE_BEGIN/,/NS_FREEZE_END/p' "$LOG")
if echo "$freeze_block" | grep -F -q "/n/distros"; then
    echo "[test_named_stack] OK: bind '#distro' /n/distros visible in ns"
else
    echo "[test_named_stack] MISS: distro bind not in /proc/self/ns"
    fail=1
fi

if [ $fail -ne 0 ]; then
    echo "[test_named_stack] FAIL (qemu rc=$rc)"
    # Preserve LOG for post-mortem.
    trap - EXIT
    echo "[test_named_stack] preserved log: $LOG"
    exit 1
fi
echo "[test_named_stack] PASS (qemu rc=$rc)"
