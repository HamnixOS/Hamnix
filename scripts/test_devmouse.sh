#!/usr/bin/env bash
# scripts/test_devmouse.sh — M16.130 regression for /dev/mouse.
#
# Pipeline mirrors test_devtime.sh / test_devpid.sh:
#   1. Build userland (hamsh, coreutils).
#   2. Build the test fixture tests/test_devmouse.ad → /bin/test_devmouse
#      in the cpio (build_initramfs.py auto-globs build/user/*.elf).
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image so devmouse.ad + FD_MOUSE_MARK arms are
#      compiled in.
#   5. Boot in QEMU, drive `/bin/test_devmouse` over the serial stdio.
#
# PASS = the fixture opened /dev/mouse successfully without crashing,
# its read either returned 0 (ring empty under headless QEMU — the
# common case) or a well-formed "<dx> <dy> <buttons>\n" line, and
# hamsh remained responsive afterwards.
#
# We deliberately do NOT require a non-empty mouse event line:
# QEMU's `-nographic -no-reboot -monitor none` config provides no
# monitor socket to inject `mouse_move` over, so the auxmouse ring is
# typically empty for the duration of this test. A future QMP-driven
# overlay can exercise the full decode path.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_devmouse.elf

echo "[test_devmouse] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devmouse] (2/5) Build tests/test_devmouse.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devmouse.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_devmouse] (3/5) Plant /init = hamsh + /bin/test_devmouse in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devmouse] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devmouse] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_devmouse\n'
    sleep 2
    printf 'echo POST_MOUSE_OK\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 15s qemu-system-x86_64 \
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

echo "[test_devmouse] --- captured output ---"
cat "$LOG"
echo "[test_devmouse] --- end output ---"

fail=0
if grep -F -q "[test_devmouse] start" "$LOG"; then
    echo "[test_devmouse] OK: fixture ran"
else
    echo "[test_devmouse] MISS: fixture banner missing"
    fail=1
fi

# Core PASS marker — open succeeded.
if grep -F -q "[test_devmouse] opened /dev/mouse OK" "$LOG"; then
    echo "[test_devmouse] OK: /dev/mouse opened cleanly"
else
    echo "[test_devmouse] MISS: /dev/mouse open failed"
    fail=1
fi

# Read must not have errored out. Either "read=0" or a parsed line is
# fine; a "parse FAIL" or "read returned negative" line is not.
if grep -F -q "[test_devmouse] read returned negative" "$LOG"; then
    echo "[test_devmouse] MISS: devmouse_read returned a negative value"
    fail=1
fi
if grep -F -q "[test_devmouse] parse FAIL" "$LOG"; then
    echo "[test_devmouse] MISS: event line failed to parse"
    fail=1
fi

# Either path is acceptable; assert one of them showed up.
if grep -F -q "[test_devmouse] read=0 (ring empty, OK)" "$LOG" \
   || grep -F -q "[test_devmouse] parse OK" "$LOG"; then
    echo "[test_devmouse] OK: read path completed without error"
else
    echo "[test_devmouse] MISS: neither empty-ring nor parsed-line banner present"
    fail=1
fi

if grep -F -q "[test_devmouse] done" "$LOG"; then
    echo "[test_devmouse] OK: fixture reached completion"
else
    echo "[test_devmouse] MISS: fixture didn't reach 'done' banner"
    fail=1
fi

if grep -F -q "POST_MOUSE_OK" "$LOG"; then
    echo "[test_devmouse] OK: hamsh remains responsive"
else
    echo "[test_devmouse] MISS: hamsh died after /dev/mouse round-trip"
    fail=1
fi

# Regression guard — the auxmouse driver itself must still come up.
if grep -F -q "auxmouse: streaming enabled" "$LOG"; then
    echo "[test_devmouse] OK: auxmouse driver still initialises"
else
    echo "[test_devmouse] MISS: auxmouse_init regressed"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devmouse] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devmouse] PASS"
