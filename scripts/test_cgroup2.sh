#!/usr/bin/env bash
# scripts/test_cgroup2.sh — cgroup v2 (/sys/fs/cgroup) for the Linux namespace.
#
# The Linux-ABI shim gains a mostly-read-only, structurally-correct cgroup v2
# (unified hierarchy) pseudo-filesystem at /sys/fs/cgroup (fs/procfs.ad render
# helpers, routed through the real VFS open dispatch in fs/vfs.ad). This is
# Linux-namespace furniture so stock Debian/systemd userland that probes
# /sys/fs/cgroup at startup (systemd, systemd-detect-virt, container tools)
# finds the interface files it expects. Native per-namespace resource control
# stays Plan-9-shape (sys/src/9/port/devnscap.ad, #174) and is NOT routed here.
#
# This fixture proves the full contract via a boot self-test (no userland
# interaction):
#
#   1. scripts/build_initramfs.py honours ENABLE_CGROUP2_TEST=1: it plants
#      /etc/cgroup2-test (the gate marker).
#   2. init/main.ad at boot:37.cg2 detects the marker and runs
#      cgroup2_vfs_selftest() (fs/vfs.ad), which drives the REAL open()/read()
#      VFS path (vfs_open -> is_cgroup_path -> _open_cgroup -> FD_BUFFER_MARK
#      read) and asserts:
#        * /sys/fs/cgroup/cgroup.controllers contains "memory" AND "pids";
#        * /sys/fs/cgroup/cgroup.procs is non-empty and carries a pid (digit);
#        * /sys/fs/cgroup/memory.current parses as a number;
#        * /sys/fs/cgroup/pids.max reads the literal "max" (uncapped root);
#        * /sys/fs/cgroup/cgroup.type reads "domain".
#   3. We boot the kernel (the _build_lock.sh qemu shim wraps the 64-bit ELF in
#      a BIOS GRUB ISO automatically) and grep the serial log for
#      `[CGROUP2] PASS`.
#
# Render-on-open only — no scratch disk is attached. Default boots ship NO
# /etc/cgroup2-test file, so the self-test is a no-op skip everywhere else.
#
# Pass marker:  [test_cgroup2] PASS   (kernel prints [CGROUP2] PASS)
# Fail marker:  [test_cgroup2] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${CGROUP2_BOOT_TIMEOUT:-120}"

echo "[test_cgroup2] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_cgroup2] (2/3) Build kernel with /etc/cgroup2-test marker"
INIT_ELF=build/user/init.elf ENABLE_CGROUP2_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_cgroup2] (3/3) Boot QEMU and run the cgroup2 self-test"
set +e
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_cgroup2] --- cgroup2 self-test output ---"
grep -a -E "\[CGROUP2\]|\[boot:37.cg2\]" "$LOG" || true
echo "[test_cgroup2] --- end ---"

fail=0

# rc=124 is the expected timeout kill (kernel halts without powering off
# qemu); rc=0 a clean shutdown. Anything else is a real QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_cgroup2] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -a -qF "[CGROUP2] FAIL" "$LOG"; then
    echo "[test_cgroup2] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[CGROUP2] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -qF "[CGROUP2] PASS" "$LOG"; then
    echo "[test_cgroup2] FAIL: '[CGROUP2] PASS' not found in serial log." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_cgroup2] --- full log ---"
    cat "$LOG"
    echo "[test_cgroup2] FAIL"
    exit 1
fi

echo "[test_cgroup2] PASS — cgroup v2 (/sys/fs/cgroup) root interface files" \
     "rendered + read through the real VFS dispatch (qemu rc=$rc)"
