#!/usr/bin/env bash
# scripts/test_wsys_gen_waitfds.sh — gen-leaf + SYS_WAITFDS regression.
#
# Verifies two compositor-unblocking kernel features:
#
#   A. /dev/wsys/<N>/draw/<layer>/gen — read-only per-layer content
#      generation counter (bumped +1 per successful markup/fb write;
#      reading it never consumes the body).
#
#   B. SYS_WAITFDS(fds, nfds, timeout_ms) = 313 — native multi-fd
#      readiness wait parked on the kernel waitfds WaitQueue (real
#      sleep, jiffy-verified) with pipe / console / devwsys backends.
#
# All assertions run inside a userland fixture (/bin/test_wsys_gen_waitfds)
# driven by ONE typed hamsh command. Pipeline mirrors
# scripts/test_wsys_damage.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_wsys_gen_waitfds.elf

echo "[test_wgw] (1/5) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_wgw] (2/5) Build tests/test_wsys_gen_waitfds.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_wsys_gen_waitfds.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_wgw] (3/5) Plant /init = hamsh + /bin/test_wsys_gen_waitfds"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_wgw] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_wgw] (5/5) Boot QEMU + run the fixture via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 8
    printf '/bin/test_wsys_gen_waitfds\n'
    sleep 8
    printf 'exit\n'
    sleep 2
) | timeout 90s qemu-system-x86_64 \
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

echo "[test_wgw] --- captured output ---"
cat "$LOG"
echo "[test_wgw] --- end output ---"

fail=0

if grep -F -q "[test_wgw] start" "$LOG"; then
    echo "[test_wgw] OK: fixture ran"
else
    echo "[test_wgw] MISS: fixture banner missing"
    fail=1
fi

for marker in gen_layer_ok gen_zero_ok gen_bumps_ok gen_read_pure_ok \
              wf_index_ok wf_timeout_ok wf_timeout_blocked_ok \
              wf_wake_ok wf_blocked_ok; do
    if grep -F -q "[test_wgw] ${marker}=1" "$LOG"; then
        echo "[test_wgw] OK: ${marker}"
    else
        echo "[test_wgw] MISS: ${marker}"
        fail=1
    fi
done

if grep -F -q "[test_wgw] PASS" "$LOG"; then
    echo "[test_wgw] OK: fixture overall PASS"
else
    echo "[test_wgw] MISS: fixture FAIL or did not complete"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_wgw] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_wgw] PASS"
