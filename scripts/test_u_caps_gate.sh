#!/usr/bin/env bash
# scripts/test_u_caps_gate.sh — verify the linux_abi/u_caps.ad cap store
# actually GATES real kernel operations (was paper before; see
# docs/audit_gap_vs_linux_2026-06-13.md).
#
# Two gates are now real:
#   * CAP_NET_ADMIN (bit 12) — host-level admin writes against #I
#                              (/net/ipifc/ctl, /net/addr, /net/dns
#                              server pin) require it. Wired in
#                              drivers/net/devnet.ad's devnet_perm_check.
#   * CAP_SYS_ADMIN (bit 21) — mount(2) requires it. Wired in
#                              linux_abi/u_syscalls.ad's _u_mount.
#
# The in-kernel caps_selftest() (linux_abi/u_caps.ad, gated on
# /etc/caps-test) was extended to ALSO drop both bits, assert
# ucaps_self_has() flips 1->0 (the same query the gates use), then
# re-seed and assert it flips back. So this test boots the same image
# scripts/test_caps.sh boots and additionally greps for the gate-PASS
# markers.
#
# Pass markers:
#   [CAPS] PASS gate sees CAP_NET_ADMIN dropped
#   [CAPS] PASS gate sees CAP_SYS_ADMIN dropped
#   [CAPS] PASS gate restored CAP_NET_ADMIN + CAP_SYS_ADMIN
#   [CAPS] PASS
# Fail marker:
#   [CAPS] FAIL ...

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_CAPS_GATE_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_u_caps_gate] (1/3) Build userland + plant /etc/caps-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_CAPS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_u_caps_gate] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_u_caps_gate] (3/3) Boot QEMU"
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

echo "[test_u_caps_gate] --- caps gate output ---"
grep -a -E "\[CAPS\]" "$LOG" || true
echo "[test_u_caps_gate] --- end ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_u_caps_gate] OK: $label"
    else
        echo "[test_u_caps_gate] MISS: $label ($marker)" >&2
        fail=1
    fi
}

if grep -a -F -q "[CAPS] FAIL" "$LOG"; then
    echo "[test_u_caps_gate] FAIL: kernel reported an internal failure" >&2
    grep -a -F "[CAPS] FAIL" "$LOG" >&2 || true
    fail=1
fi

check_marker "[CAPS] PASS gate sees CAP_NET_ADMIN dropped" \
             "ucaps_self_has reflects CAP_NET_ADMIN drop"
check_marker "[CAPS] PASS gate sees CAP_SYS_ADMIN dropped" \
             "ucaps_self_has reflects CAP_SYS_ADMIN drop"
check_marker "[CAPS] PASS gate restored CAP_NET_ADMIN + CAP_SYS_ADMIN" \
             "restore re-seeds full caps and gate flips back"
check_marker "[CAPS] PASS" "overall self-test PASS banner"

if [ "$fail" -ne 0 ]; then
    echo "[test_u_caps_gate] --- full log ---"
    cat "$LOG"
    echo "[test_u_caps_gate] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u_caps_gate] PASS — ucaps_self_has gates real (qemu rc=$rc)"
