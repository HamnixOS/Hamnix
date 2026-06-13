#!/usr/bin/env bash
# scripts/test_notedrain.sh — §3 deferred trap-return note drain.
#
# Boots the kernel once with /etc/notedrain-test planted
# (ENABLE_NOTEDRAIN_TEST=1); init/main.ad at boot:37.ndrain calls
# notedrain_selftest() (sys/src/9/port/sysnote.ad), which PROVES the
# deferred trap-return note-delivery hook closes the §3 Signals TODO item:
# note_pending parked on cross-task targets by post_note_to_group +
# post_note_to_pid is consumed at trap-return — either retarget the
# saved-user-RIP slot at the installed handler (Plan 9 notify/noted), or
# take the DEFAULT action (terminate) when no handler is installed.
#
# The self-test builds an RFNOTEG cohort (3 children in group A with
# installed user-handler RIPs, 1 isolation witness in group B, 1 group-A
# child with NO handler for the default-action arm), runs the REAL
# post_note_to_group walker, then simulates each child's trap-return via
# the production _drain_slot primitive. Asserts:
#   * post_note_to_group hit EXACTLY 4 RFNOTEG members (3 + 1 default).
#   * The group-B witness was NEVER enqueued — RFNOTEG isolation.
#   * Each handler-bearing child's drain returned NOTE_DRAIN_HANDLER and
#     rewrote the fake saved-RIP at the installed handler.
#   * The default-action child's drain returned NOTE_DRAIN_DEFAULT and
#     cleared note_pending.
#   * The runtime gate (notes_enabled) defaults OFF and arms on request.
#
# Pass marker:  [test_notedrain] PASS
# Fail marker:  [test_notedrain] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_notedrain] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_notedrain] (2/3) Build kernel with /etc/notedrain-test marker"
INIT_ELF=build/user/init.elf ENABLE_NOTEDRAIN_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_notedrain] (3/3) Boot QEMU and run the trap-return drain self-test"
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

echo "[test_notedrain] --- trap-return drain self-test output ---"
grep -E "\[notedrain\]" "$LOG" || true
echo "[test_notedrain] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_notedrain] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[notedrain] FAIL" "$LOG"; then
    echo "[test_notedrain] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_notedrain] PASS: $label"
    else
        echo "[test_notedrain] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"                "[notedrain] deferred trap-return drain self-test start"
check "group-B isolated"             "[notedrain] group-B witness isolated from group-A post OK"
check "all 3 RFNOTEG members drained" "[notedrain] all 3 RFNOTEG members drained to handler OK"
check "group-B witness NOP drain"    "[notedrain] group-B witness drain was NOP OK"
check "default-action arm"           "[notedrain] default-action drain returns DEFAULT + clears pending OK"
check "runtime gate default-OFF"     "[notedrain] runtime gate default-OFF OK"
check "runtime gate arms"            "[notedrain] runtime gate arms when requested OK"
check "trap-return drain PASS"       "[notedrain] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_notedrain] FAIL"
    exit 1
fi

echo "[test_notedrain] PASS — deferred trap-return note drain consumes group-wide enqueued notes, runs handlers, isolates non-members, and default-terminates handler-less targets"
