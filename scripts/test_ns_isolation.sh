#!/usr/bin/env bash
# scripts/test_ns_isolation.sh — V2 per-process namespace regression.
#
# Builds tests/test_ns_isolation.ad, drops it into the cpio initramfs,
# boots Hamnix in QEMU, and greps the serial log for the PASS marker.
# The fixture exercises the full V2 contract end-to-end:
#
#   * parent binds /myalias -> /etc
#   * parent rforks RFPROC|RFFDG|RFNAMEG|RFENVG
#   * child sees inherited binding (proves ns_clone deep-copied),
#     then unmounts + re-binds /myalias -> /bin, then opens
#     /myalias/cat (proves the divergent view is live).
#   * parent (after waitpid) re-opens /myalias/inittab -- proves the
#     parent's row was NEVER touched by the child's bind.
#
# Pipeline matches scripts/test_p9mount.sh: build hamsh + the
# test ELF, plant /init=hamsh, rebuild kernel, boot, drive over
# serial stdio.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_ns_isolation.elf

echo "[test_ns_isolation] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_ns_isolation] (2/5) Build tests/test_ns_isolation.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_ns_isolation.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_ns_isolation] (3/5) Plant /init = hamsh + /bin/test_ns_isolation in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_ns_isolation] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ns_isolation] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Marker-gated feeder (same proven shape as test_distrofs_persist.sh /
    # test_9p_concurrency.sh): a freshly-booted hamsh sometimes drops the
    # FIRST serial command line (it never echoes), and fixed sleeps race a
    # slowing boot. Gate on the shell-ready marker, then RE-SEND the
    # command until its echo shows up in the log — keyed on the echo
    # (immediate on receipt), NOT the fixture marker, so a slow but
    # received run is never double-driven.
    for _ in $(seq 1 40); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf '/bin/test_ns_isolation\n'
    for _ in $(seq 1 10); do
        sleep 1.5
        grep -q "bin/test_ns_isolation" "$LOG" 2>/dev/null && break
        printf '/bin/test_ns_isolation\n'
    done
    # Wait for the fixture to finish (PASS or a FAIL line), then exit.
    for _ in $(seq 1 40); do
        grep -Eq '\[ns_isolation\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf 'exit\n'
    sleep 1
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

echo "[test_ns_isolation] --- captured output ---"
cat "$LOG"
echo "[test_ns_isolation] --- end output ---"

fail=0

if grep -F -q "[ns_isolation] start" "$LOG"; then
    echo "[test_ns_isolation] OK: fixture ran"
else
    echo "[test_ns_isolation] MISS: fixture banner missing"
    fail=1
fi

if grep -F -q "[ns_isolation] parent bind /myalias -> /etc ok" "$LOG"; then
    echo "[test_ns_isolation] OK: parent bind"
else
    echo "[test_ns_isolation] MISS: parent bind"
    fail=1
fi

if grep -F -q "[ns_isolation] child inherited /myalias/inittab ok" "$LOG"; then
    echo "[test_ns_isolation] OK: ns_clone deep-copied parent's bindings"
else
    echo "[test_ns_isolation] MISS: child inheritance broken"
    fail=1
fi

if grep -F -q "[ns_isolation] child bind /myalias -> /bin ok" "$LOG"; then
    echo "[test_ns_isolation] OK: child re-bind in private namespace"
else
    echo "[test_ns_isolation] MISS: child bind failed"
    fail=1
fi

if grep -F -q "[ns_isolation] child /myalias/cat ok (private bind live)" "$LOG"; then
    echo "[test_ns_isolation] OK: child's bind resolves to /bin"
else
    echo "[test_ns_isolation] MISS: child bind not honoured"
    fail=1
fi

if grep -F -q "[ns_isolation] child PASS" "$LOG"; then
    echo "[test_ns_isolation] OK: child reached PASS"
else
    echo "[test_ns_isolation] MISS: child did not PASS"
    fail=1
fi

if grep -F -q "[ns_isolation] parent /myalias/inittab ok post-child" "$LOG"; then
    echo "[test_ns_isolation] OK: parent's view preserved after child"
else
    echo "[test_ns_isolation] MISS: parent's binding lost!"
    fail=1
fi

if grep -F -q "[ns_isolation] parent /myalias/cat missing (expected)" "$LOG"; then
    echo "[test_ns_isolation] OK: child's bind did not leak to parent"
else
    echo "[test_ns_isolation] MISS: child's bind leaked to parent (isolation broken!)"
    fail=1
fi

if grep -F -q "[ns_isolation] PASS" "$LOG"; then
    echo "[test_ns_isolation] OK: fixture reached PASS"
else
    echo "[test_ns_isolation] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ns_isolation] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_ns_isolation] PASS"
