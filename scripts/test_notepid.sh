#!/usr/bin/env bash
# scripts/test_notepid.sh — Plan 9 single-target (one pid) note delivery.
#
# Boots the kernel once with /etc/notepid-test planted
# (ENABLE_NOTEPID_TEST=1); init/main.ad at boot:37.npid calls
# notepid_selftest() (sys/src/9/port/sysnote.ad), which PROVES that a note
# posted to ONE pid via post_note_to_pid reaches EXACTLY that target and no
# other task — the cross-task single-target path that /proc/<pid>/note now
# drives (replacing the old "not yet implemented" log+drop).
#
# The self-test (NO QEMU injection — it drives the single-target path
# directly):
#   * claims TWO inert live task slots (STATE_STOPPED), stamping each a
#     KNOWN distinct pid,
#   * calls the REAL post_note_to_pid(target_pid, "interrupt") path,
#   * asserts the TARGET slot got note_pending=1 with the note string,
#   * asserts the NON-target witness did NOT receive (single-target
#     isolation),
#   * asserts the return value equals count (success),
#   * asserts a post to a non-existent pid honestly returns -ESRCH.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_notepid] PASS
# Fail marker:  [test_notepid] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_notepid] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_notepid] (2/3) Build kernel with /etc/notepid-test marker"
INIT_ELF=build/user/init.elf ENABLE_NOTEPID_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_notepid] (3/3) Boot QEMU and run the single-target self-test"
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

echo "[test_notepid] --- single-target self-test output ---"
grep -E "\[notepid\]" "$LOG" || true
echo "[test_notepid] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_notepid] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -qF "[notepid] FAIL" "$LOG"; then
    echo "[test_notepid] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_notepid] PASS: $label"
    else
        echo "[test_notepid] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"               "[notepid] single-target delivery self-test start"
check "return value == count"       "[notepid] return value == count OK"
check "target received the note"    "[notepid] target received the note OK"
check "non-target isolated"         "[notepid] non-target witness correctly isolated OK"
check "missing pid -ESRCH"          "[notepid] missing pid returned -ESRCH OK"
check "single-target self-test PASS" "[notepid] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_notepid] FAIL"
    exit 1
fi

echo "[test_notepid] PASS — a note posted to ONE pid reaches EXACTLY that target and no other task, returns count on success, and honestly returns -ESRCH for a missing pid"
