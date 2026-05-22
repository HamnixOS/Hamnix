#!/usr/bin/env bash
# scripts/test_9p_mount.sh — V1 in-kernel 9P client smoke test.
#
# Builds the kernel with init/p9_smoke.ad wired into start_kernel,
# boots under QEMU, and greps the serial log for `[p9smoke] PASS`.
# The smoke test runs entirely in-kernel before sched_init: a tiny
# responder backed by two kernel pipe slots serves a single-file FS
# (/hello → "world\n"), the V1 9P client (sys/src/9/port/p9_client.ad)
# does Tversion + Tattach + Twalk("hello") + Topen + Tread + Tclunk,
# and we assert the returned bytes match.
#
# Shape mirrors scripts/run_x86_bare.sh — `[p9smoke] PASS` is the
# success marker; `[p9smoke] FAIL: <what>` surfaces the first failure.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# Higher-half kernel boot shim: routes a `qemu -kernel <elf64>` call
# through a BIOS GRUB ISO (QEMU's -kernel rejects 64-bit ELFs). This
# script does not source _build_lock.sh, so source the shim directly.
. "$PROJ_ROOT/scripts/_kernel_iso.sh"

mkdir -p build
ELF=build/hamnix-kernel.elf

echo "[test_9p_mount] (1/3) Build userland (so the cpio archive is sane)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null

echo "[test_9p_mount] (2/3) Compile init/main.ad -> $ELF"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_9p_mount] (3/3) Boot QEMU + scan serial for [p9smoke] PASS"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
timeout 20s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_9p_mount] --- captured output ---"
cat "$LOG"
echo "[test_9p_mount] --- end output ---"

fail=0

if grep -F -q "[p9smoke] start" "$LOG"; then
    echo "[test_9p_mount] OK: smoke fixture ran"
else
    echo "[test_9p_mount] MISS: smoke fixture banner missing"
    fail=1
fi

if grep -F -q "[p9smoke] FAIL:" "$LOG"; then
    echo "[test_9p_mount] MISS: smoke fixture reported FAIL:"
    grep -F "[p9smoke] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
fi

if grep -F -q "[p9smoke] PASS" "$LOG"; then
    echo "[test_9p_mount] OK: [p9smoke] PASS observed"
else
    echo "[test_9p_mount] MISS: [p9smoke] PASS absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_9p_mount] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_9p_mount] PASS"
