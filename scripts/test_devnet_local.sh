#!/usr/bin/env bash
# scripts/test_devnet_local.sh — /net local-address renderer reports the
# REAL host IP instead of the old hardcoded 0.0.0.0 placeholder.
#
# Boots the kernel once with /etc/devnet-local-test planted
# (ENABLE_DEVNET_LOCAL_TEST=1); init/main.ad at boot:37.dnl calls
# devnet_local_selftest() (drivers/net/devnet.ad). The self-test sets a
# known host IP (10.0.2.15, the QEMU user-net default) via the existing
# ip_set_our_ip setter, clones a /net/tcp connection, pins its local
# port, renders the connection's /net/tcp/<n>/local file through the
# REAL devnet_local_render path, and asserts the rendered text:
#   * CONTAINS the real host IP "10.0.2.15!" (the local end now follows
#     the single host IP, set by DHCP / static ifconfig)
#   * does NOT contain the old "0.0.0.0!" placeholder
#
# This is the Plan-9-shaped analogue of Linux /proc/net/tcp's local
# address column — the local end of every conn is the host's single IP.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_devnet_local] PASS
# Fail marker:  [test_devnet_local] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_devnet_local] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_devnet_local] (2/3) Build kernel with /etc/devnet-local-test marker"
INIT_ELF=build/user/init.elf ENABLE_DEVNET_LOCAL_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_devnet_local] (3/3) Boot QEMU and run the /net local-address self-test"
set +e
timeout 180s qemu-system-x86_64 \
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

echo "[test_devnet_local] --- self-test output ---"
grep -E "\[DEVNET_LOCAL\]" "$LOG" || true
echo "[test_devnet_local] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_devnet_local] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Any explicit internal failure is fatal.
if grep -qF "[DEVNET_LOCAL] FAIL" "$LOG"; then
    echo "[test_devnet_local] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

# The rendered local address must carry the real host IP, not 0.0.0.0.
if grep -qF "10.0.2.15!" "$LOG"; then
    echo "[test_devnet_local] PASS: local address rendered real host IP 10.0.2.15!"
else
    echo "[test_devnet_local] FAIL: rendered local address missing real host IP '10.0.2.15!'" >&2
    fail=1
fi

if grep -qF "0.0.0.0!" "$LOG"; then
    echo "[test_devnet_local] FAIL: rendered local address still shows the 0.0.0.0 placeholder" >&2
    fail=1
fi

if ! grep -qF "[DEVNET_LOCAL] PASS" "$LOG"; then
    echo "[test_devnet_local] FAIL: missing [DEVNET_LOCAL] PASS banner" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devnet_local] FAIL"
    exit 1
fi

echo "[test_devnet_local] PASS — /net local-address renderer reports the real host IP (10.0.2.15) instead of the 0.0.0.0 placeholder"
