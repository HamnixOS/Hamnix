#!/usr/bin/env bash
# scripts/test_ns_enoent.sh — F1-substrate acceptance (audit #444 /
# task #446): UNBOUND = ENOENT, per-Pgrp.
#
# Builds tests/test_ns_enoent.ad, drops it into the cpio initramfs,
# boots Hamnix in QEMU, and greps the serial log for the markers.
# The fixture proves the namespace substrate contract:
#
#   * a file the PARENT (default boot namespace) can open is ENOENT
#     in an RFCNAMEG child's EMPTY namespace — no silent fall-through
#     to a global cpio root (the old veneer's behavior);
#   * an explicit server-anchored bind (#r/etc at /onlyetc) makes
#     exactly that subtree visible — and nothing else (the original
#     path and /bin stay ENOENT);
#   * the child's empty namespace + bind are per-Pgrp: the parent's
#     default view is intact afterwards and /onlyetc never leaks.
#
# Pipeline matches scripts/test_ns_isolation.sh: build hamsh + the
# test ELF, plant /init=hamsh, rebuild kernel, boot, drive over
# serial stdio with the marker-gated feeder.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_ns_enoent.elf

echo "[test_ns_enoent] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_ns_enoent] (2/5) Build tests/test_ns_enoent.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_ns_enoent.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_ns_enoent] (3/5) Plant /init = hamsh + /bin/test_ns_enoent in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_ns_enoent] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ns_enoent] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Marker-gated feeder (same proven shape as test_distrofs_persist.sh):
    # gate on the shell-ready marker, then RE-SEND the command until its
    # echo shows up in the log — keyed on the echo (immediate on
    # receipt), NOT the fixture marker, so a slow but received run is
    # never double-driven.
    for _ in $(seq 1 40); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf '/bin/test_ns_enoent\n'
    for _ in $(seq 1 10); do
        sleep 1.5
        grep -q "bin/test_ns_enoent" "$LOG" 2>/dev/null && break
        printf '/bin/test_ns_enoent\n'
    done
    # Wait for the fixture to finish (PASS or a FAIL line), then exit.
    for _ in $(seq 1 40); do
        grep -Eq '\[ns_enoent\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
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

echo "[test_ns_enoent] --- captured output ---"
cat "$LOG"
echo "[test_ns_enoent] --- end output ---"

fail=0

check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_ns_enoent] OK: $label"
    else
        echo "[test_ns_enoent] MISS: $label ($marker)"
        fail=1
    fi
}

check "[ns_enoent] start" \
      "fixture ran"
check "[ns_enoent] parent /etc/inittab ok (default ns)" \
      "parent opens the probe file in the default boot namespace"
check "[ns_enoent] child empty-ns /etc/inittab ENOENT (expected)" \
      "UNBOUND = ENOENT: empty namespace does NOT fall through to a global root"
check "[ns_enoent] child bind /onlyetc <- #r/etc ok" \
      "server-anchored bind into the empty namespace"
check "[ns_enoent] child /onlyetc/inittab ok (explicit bind only)" \
      "the explicit bind (and only it) restores visibility"
check "[ns_enoent] child /etc/inittab still ENOENT post-bind (expected)" \
      "an unrelated bind does not resurrect a global root"
check "[ns_enoent] child /bin/cat ENOENT (expected)" \
      "never-bound subtree stays invisible"
check "[ns_enoent] child PASS" \
      "child reached PASS"
check "[ns_enoent] parent /etc/inittab ok post-child" \
      "parent's default namespace intact after the child (per-Pgrp)"
check "[ns_enoent] parent /onlyetc missing (expected)" \
      "child's bind did not leak to the parent"
check "[ns_enoent] PASS" \
      "fixture reached PASS"

# Any fixture FAIL line is a hard failure even if the PASS markers
# somehow also appeared.
if grep -a -F -q "[ns_enoent] FAIL" "$LOG"; then
    echo "[test_ns_enoent] MISS: fixture FAIL line present:"
    grep -a -F "[ns_enoent] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ns_enoent] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_ns_enoent] PASS — an empty (RFCNAMEG) namespace resolves NOTHING until bound: unbound = ENOENT with no global-root fall-through, and binds are per-Pgrp"
