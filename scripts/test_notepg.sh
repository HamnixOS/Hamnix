#!/usr/bin/env bash
# scripts/test_notepg.sh — Phase G: Plan 9 note-group WIDE delivery.
#
# Boots the kernel once with /etc/notepg-test planted
# (ENABLE_NOTEPG_TEST=1); init/main.ad at boot:37.npg calls
# notegroup_selftest() (sys/src/9/port/sysnote.ad), which PROVES that a
# note posted to a note GROUP fans out to EVERY live member of that group
# and skips non-members and dead tasks — Plan 9's process-group
# signalling, the defining feature of note groups.
#
# The self-test (NO QEMU injection — it drives the group walk directly):
#   * claims a controlled population of inert task slots:
#       - three LIVE members in note group A (STATE_STOPPED),
#       - one member in a DIFFERENT group B (isolation witness),
#       - one DEAD member (STATE_EXITED) in group A (corpse witness),
#   * calls the REAL post_note_to_group(A, "hangup") walker,
#   * asserts EXACTLY the three live group-A members got note_pending=1
#     with the note string in their note_msg buffer,
#   * asserts the group-B witness did NOT receive (cross-group isolation),
#   * asserts the dead group-A member did NOT receive (no delivery to a
#     corpse),
#   * asserts the returned recipient count is EXACTLY 3.
#
# Proving the walk enqueues onto every matching live member while skipping
# a same-group dead task and a different-group live task pins the
# load-bearing logic: WHO a group-wide note reaches.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_notepg] PASS
# Fail marker:  [test_notepg] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_notepg] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_notepg] (2/3) Build kernel with /etc/notepg-test marker"
INIT_ELF=build/user/init.elf ENABLE_NOTEPG_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_notepg] (3/3) Boot QEMU and run the note-group self-test"
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

echo "[test_notepg] --- note-group self-test output ---"
grep -E "\[notepg\]" "$LOG" || true
echo "[test_notepg] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_notepg] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -qF "[notepg] FAIL" "$LOG"; then
    echo "[test_notepg] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_notepg] PASS: $label"
    else
        echo "[test_notepg] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"                  "[notepg] note-group wide-delivery self-test start"
check "all 3 live members received"    "[notepg] all 3 live group-A members received OK"
check "group-B witness isolated"       "[notepg] group-B witness correctly isolated OK"
check "dead group-A member skipped"    "[notepg] dead group-A slot correctly skipped OK"
check "recipient count == 3"           "[notepg] recipient count == 3 OK"
check "note-group self-test PASS"      "[notepg] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_notepg] FAIL"
    exit 1
fi

echo "[test_notepg] PASS — a note posted to a note group fans out to EXACTLY the live members of that group (3 of 3) and skips a same-group dead task and a different-group live task"
