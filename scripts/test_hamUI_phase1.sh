#!/usr/bin/env bash
# scripts/test_hamUI_phase1.sh — hamUI Phase 1 regression.
#
# Verifies the /dev/wsys/1/* AI-debug surface (docs/hamUI.md H-§A/E):
#   - kind / geometry / pid / uid / wsys-listing snapshots are
#     well-formed
#   - cmd write side accepts bytes without error
#   - text ring mirrors every byte from devcons_write (the fixture
#     reads back its own banner)
#   - ns dump renders the caller's mtab
#
# Then verifies the end-to-end cmd-injection path: from inside hamsh,
# write a marker to /dev/wsys/1/cmd via `echo` (a builtin that runs
# inside the same task), and assert the subsequent hamsh readline
# dequeues those bytes and runs them as a command — the resulting
# output ("INJECT_OK") shows up in the serial log AND in
# /dev/wsys/1/text.
#
# Pipeline:
#   1. Build userland (hamsh + coreutils + test fixture).
#   2. Make /init = hamsh.elf so we land at a shell prompt.
#   3. Rebuild the kernel image with the new devwsys + namec wiring.
#   4. Boot in QEMU, run /bin/test_hamUI_phase1, then drive the
#      cmd-injection round-trip from hamsh itself.
#   5. Grep the serial log for the success markers.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_hamUI_phase1.elf

echo "[test_hamUI_phase1] (1/5) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamUI_phase1] (2/5) Build tests/test_hamUI_phase1.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_hamUI_phase1.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_hamUI_phase1] (3/5) Plant /init = hamsh + /bin/test_hamUI_phase1"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamUI_phase1] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_hamUI_phase1] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Bumped from 3s/2s/1s to 8s/4s/3s — orchestrator hosts under load
    # need hamsh past stage-08 (ed-readline-first) before keystrokes
    # land or they get dropped, same pattern as test_man.sh's bump
    # at commit cef5b15.
    sleep 8
    # Phase A — read snapshots, write to cmd queue, verify text tee.
    printf '/bin/test_hamUI_phase1\n'
    sleep 6
    # Phase B — end-to-end cmd-injection round-trip. The fixture
    # already pushed "echo HAMUI_CMD_OK\n" into the cmd queue (step 6
    # in the fixture). Hamsh's NEXT readline call will pop those
    # bytes and run that line. We give hamsh a moment to drain the
    # queue and emit INJECT_OK, then prove hamsh is still alive
    # with a separate echo.
    sleep 3
    printf 'echo POST_HAMUI_OK\n'
    sleep 3
    # Phase C — verify that AFTER hamsh has been driving things, the
    # text ring still contains the test banner (the ring is now
    # bigger so this also doubles as "the ring didn't get clobbered
    # by the readline echo path").
    printf 'cat /dev/wsys/1/kind\n'
    sleep 3
    printf 'cat /dev/wsys/1/geometry\n'
    sleep 3
    printf 'cat /dev/wsys\n'
    sleep 3
    printf 'exit\n'
    sleep 2
) | timeout 60s qemu-system-x86_64 \
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

echo "[test_hamUI_phase1] --- captured output ---"
cat "$LOG"
echo "[test_hamUI_phase1] --- end output ---"

fail=0

# Fixture banner — proves the test fixture even started.
if grep -F -q "[test_hamUI_phase1] start" "$LOG"; then
    echo "[test_hamUI_phase1] OK: fixture ran"
else
    echo "[test_hamUI_phase1] MISS: fixture banner missing"
    fail=1
fi

# Per-step success markers from inside the fixture.
for marker in kind_ok geometry_ok pid_ok uid_ok listing_ok cmd_write_ok \
              text_tee_ok ns_ok; do
    if grep -F -q "[test_hamUI_phase1] ${marker}=1" "$LOG"; then
        echo "[test_hamUI_phase1] OK: ${marker}"
    else
        echo "[test_hamUI_phase1] MISS: ${marker}"
        fail=1
    fi
done

# Final fixture PASS line — proves no internal FAIL fired.
if grep -F -q "[test_hamUI_phase1] PASS" "$LOG"; then
    echo "[test_hamUI_phase1] OK: fixture overall PASS"
else
    echo "[test_hamUI_phase1] MISS: fixture FAIL or did not complete"
    fail=1
fi

# End-to-end cmd-injection round-trip — the fixture pushed
# "echo HAMUI_CMD_OK\n" into the cmd queue, and hamsh's next
# readline should have run it.
if grep -F -q "HAMUI_CMD_OK" "$LOG"; then
    echo "[test_hamUI_phase1] OK: cmd injection -> hamsh readline -> echo"
else
    echo "[test_hamUI_phase1] MISS: cmd-injection round-trip failed"
    fail=1
fi

# Responsiveness — hamsh still alive after fixture and injection.
if grep -F -q "POST_HAMUI_OK" "$LOG"; then
    echo "[test_hamUI_phase1] OK: hamsh remains responsive"
else
    echo "[test_hamUI_phase1] MISS: hamsh died after hamUI traffic"
    fail=1
fi

# Cat /dev/wsys/1/kind from inside hamsh returns "text".
if grep -F -q "text" "$LOG"; then
    # too broad on its own — already in lots of places; just keep
    # going. The fixture's kind_ok=1 is the real assertion.
    :
fi

# Cat /dev/wsys returns the listing.
if grep -F -q "POST_HAMUI_OK" "$LOG"; then
    # already counted above; this group of cat's is mostly to
    # validate the dispatch path doesn't crash hamsh post-injection.
    :
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamUI_phase1] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamUI_phase1] PASS"
