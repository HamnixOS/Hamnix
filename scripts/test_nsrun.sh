#!/usr/bin/env bash
# scripts/test_nsrun.sh — smoke for the nsrun shim launcher
# (user/nsrun.ad).
#
# nsrun runs a program in a FRESH private namespace whose /var is
# served by a live distrofs 9P daemon. This test proves BOTH halves of
# the Plan 9 invariant with one fixture binary (tests/test_nsrun.ad)
# run two ways from hamsh:
#
#   A. `/bin/nsrun /bin/test_nsrun write`
#      nsrun spawns distrofs, clones the namespace, mounts distrofs at
#      /var, then exec's the fixture in "write" mode. The fixture
#      creates + writes + reads back /var/lib/dpkg/nsrun_probe — a
#      path the initramfs does NOT ship — so a successful round trip
#      proves the ops landed on the distrofs daemon.
#
#   B. `/bin/test_nsrun probe`   (bare — NO nsrun)
#      In the plain shell namespace. /var here is the initramfs view
#      (ships /var/www/* but nothing under /var/lib/dpkg/). The fixture
#      asserts /var/lib/dpkg/nsrun_probe is NOT openable — proving the
#      write from run A did not leak into the parent's namespace.
#
# Pipeline (same shape as scripts/test_9p_realfd.sh):
#   1. Build userland (hamsh + coreutils + distrofs + nsrun).
#   2. Build tests/test_nsrun.ad -> build/user/test_nsrun.elf.
#   3. Plant /init = hamsh.elf.
#   4. Rebuild the kernel image.
#   5. Boot QEMU, drive both invocations over serial, exit.
#   6. Grep the serial log for the markers.
#
# MARKERS asserted (from user/nsrun.ad + tests/test_nsrun.ad):
#   [nsrun] distrofs daemon spawned
#   [nsrun] private namespace cloned
#   [nsrun] distrofs mounted at /var
#   [nsrun] exec target in namespace
#   [nsrun_test] mode=write
#   [nsrun_test] write OK
#   [nsrun_test] payload OK         (round trip byte-exact, run A)
#   [nsrun_test] mode=probe
#   [nsrun_test] isolation OK       (parent /var/lib/dpkg empty, run B)

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_nsrun.elf

echo "[test_nsrun] (1/5) Build userland (hamsh + coreutils + distrofs + nsrun)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_nsrun] (2/5) Build tests/test_nsrun.ad -> $TEST_ELF"
mkdir -p build/user
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_nsrun.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_nsrun] (3/5) Plant /init = hamsh + /bin/test_nsrun in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_nsrun] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_nsrun] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # Run A: round trip inside the nsrun-built distrofs namespace.
    printf '/bin/nsrun /bin/test_nsrun write\n'
    sleep 5
    # Run B: bare isolation probe in the plain shell namespace.
    printf '/bin/test_nsrun probe\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 35s qemu-system-x86_64 \
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

echo "[test_nsrun] --- captured output ---"
cat "$LOG"
echo "[test_nsrun] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_nsrun] OK: $label"
    else
        echo "[test_nsrun] MISS: $label ($marker)"
        fail=1
    fi
}

# Any per-assertion FAIL line means a round-trip / isolation check broke.
if grep -F -q "[nsrun_test] FAIL:" "$LOG"; then
    echo "[test_nsrun] MISS: per-assertion FAIL line(s) present:"
    grep -F "[nsrun_test] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_nsrun] OK: no per-assertion FAIL lines"
fi

# nsrun launcher steps (run A).
check_marker "[nsrun] distrofs daemon spawned"   "nsrun spawned distrofs"
check_marker "[nsrun] private namespace cloned"  "nsrun rfork(RFNAMEG)"
check_marker "[nsrun] distrofs mounted at /var"  "nsrun mounted distrofs"
check_marker "[nsrun] exec target in namespace"  "nsrun exec'd the target"
# Round trip inside the namespace (run A).
check_marker "[nsrun_test] mode=write"  "fixture ran in write mode"
check_marker "[nsrun_test] write OK"    "create+write on distrofs /var"
check_marker "[nsrun_test] payload OK"  "byte-exact round trip on distrofs"
# Isolation in the parent namespace (run B).
check_marker "[nsrun_test] mode=probe"   "fixture ran bare in probe mode"
check_marker "[nsrun_test] isolation OK" "parent /var/lib/dpkg untouched"

# Exactly two PASS lines expected: one per run.
pass_count=$(grep -F -c "[nsrun_test] PASS" "$LOG" || true)
if [ "$pass_count" -ge 2 ]; then
    echo "[test_nsrun] OK: both fixture runs reached PASS ($pass_count)"
else
    echo "[test_nsrun] MISS: expected 2 PASS lines, saw $pass_count"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_nsrun] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_nsrun] PASS"
