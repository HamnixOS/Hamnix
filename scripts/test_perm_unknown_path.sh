#!/usr/bin/env bash
# scripts/test_perm_unknown_path.sh — F10-2 #455 acceptance gate.
#
# Proves the chan_permission_check dispatcher's default-deny trap fires
# for paths the namespace can't bind. Pre-F10-2 the dispatcher's
# `_path_owning_server` defaulted to cpio (server 1) on no-match, then
# admitted on `_perm_check_cpio` returning 0 for an absent name. Post-
# F10-2 there is no such silent grant: an unbound path returns ENOENT
# at the namespace gate (F10-1), and a path that bypassed the namespace
# gate and reaches an unknown server letter returns EPERM.
#
# This test is the userland-visible expression of that contract: a
# fabricated /never/bound/foobar path returns a negative fd, and so
# does a fabricated #Z/anything (unknown server letter).
#
# Pipeline mirrors scripts/test_ns_enoent.sh: build hamsh + the test
# ELF, plant /init = hamsh in the cpio, rebuild the kernel image, boot
# QEMU, drive the test via hamsh, grep the serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_perm_unknown_path.elf

echo "[test_perm_unknown_path] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_perm_unknown_path] (2/5) Build tests/test_perm_unknown_path.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_perm_unknown_path.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_perm_unknown_path] (3/5) Plant /init = hamsh + /bin/test_perm_unknown_path in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_perm_unknown_path] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_perm_unknown_path] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Same marker-gated feeder shape proven by test_ns_enoent.sh: wait
    # for the shell-ready marker, then RE-SEND the command until its
    # echo lands in the log (keyed on the echo — immediate on receipt
    # — NOT the fixture marker, so a slow but received run is never
    # double-driven).
    for _ in $(seq 1 40); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf '/bin/test_perm_unknown_path\n'
    for _ in $(seq 1 10); do
        sleep 1.5
        grep -q "bin/test_perm_unknown_path" "$LOG" 2>/dev/null && break
        printf '/bin/test_perm_unknown_path\n'
    done
    # Wait for the fixture to finish (PASS or a FAIL line), then exit.
    for _ in $(seq 1 40); do
        grep -Eq '\[perm_unknown\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
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

echo "[test_perm_unknown_path] --- captured output ---"
cat "$LOG"
echo "[test_perm_unknown_path] --- end output ---"

fail=0

check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_perm_unknown_path] OK: $label"
    else
        echo "[test_perm_unknown_path] MISS: $label ($marker)"
        fail=1
    fi
}

check "[perm_unknown] start" \
      "fixture ran"
check "[perm_unknown] fabricated /never/bound/foobar/quux denied" \
      "F10-1+F10-2: unbound absolute path returns a negative fd"
check "[perm_unknown] fabricated #Z/anything denied" \
      "unknown server letter returns a negative fd"
check "[perm_unknown] fabricated /no/such/binary/forever denied" \
      "fabricated executable name returns a negative fd"
check "[perm_unknown] PASS" \
      "fixture reached PASS"

if grep -a -F -q "[perm_unknown] FAIL" "$LOG"; then
    echo "[test_perm_unknown_path] MISS: fixture FAIL line present:"
    grep -a -F "[perm_unknown] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_perm_unknown_path] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_perm_unknown_path] PASS — F10-2 #455 default-deny verified end-to-end: unbound paths and unknown server letters never silently grant"
