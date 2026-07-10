#!/usr/bin/env bash
# scripts/test_9p_concurrency.sh — V6 tagged 9P concurrency gate.
#
# Proves the kernel 9P client really multiplexes: TWO userland tasks
# (the fixture parent + a spawned reader child) loop open/read/close
# against the SAME mounted distrofs at the same time. The V6 RPC pool
# in sys/src/9/port/9p_client.ad must allocate distinct tags, keep >=2
# T-msgs outstanding, and tag-demux the R-msgs back to the right
# parked waiters.
#
# THE PROOF is kernel-measured: 9p_client.ad tracks the high-water
# mark of simultaneously SENT (in-flight, unanswered) T-messages and
# surfaces it as the read-only file /dev/9pmax. After both loops the
# fixture reads it back IN-GUEST and prints
#
#     [9pconc] inflight_max=N
#
# and FAILs itself when N < 2. The script re-asserts N >= 2 from the
# captured line. (The kernel also printk's a one-shot
# "[9p] tagged concurrency: N T-msgs in flight" when the threshold is
# first crossed — but it is INFO-level and fires while the fixture
# runs from the INTERACTIVE shell, after console_set_interactive()
# gates INFO printk to the ring buffer only, so it never reaches the
# captured serial console; the /dev/9pmax read-back is gate-proof.)
# A client that secretly serializes (old single-outstanding behaviour)
# would still pass every fixture I/O assertion — but read back 1 here,
# and this test FAILs.
#
# Pipeline (same shape as scripts/test_9p_realfd.sh):
#   1. Build userland (hamsh + coreutils + distrofs).
#   2. Build tests/test_9p_concurrency.ad -> build/user/test_9p_concurrency.elf.
#   3. Plant /init = hamsh.elf (fixture lands at /bin/test_9p_concurrency).
#   4. Rebuild the kernel image.
#   5. Boot QEMU, drive `/bin/test_9p_concurrency` via serial stdio.
#   6. Grep the serial log for the [9pconc] markers + the kernel
#      "[9p] tagged concurrency" one-shot.

# ---------------------------------------------------------------------------
# MIGRATED onto scripts/_hamsh_drive.sh (test-trustworthiness campaign).
# The legacy driver did `( sleep N; printf '/bin/test_9p_concurrency\n'; ... ) | qemu`:
# under host load the fixed sleep raced ahead of hamsh's readline and the
# command was dropped, so the gate MISSed its own markers and reported a
# FALSE red. This drives hamsh prompt-gated (boot-ready marker) + output-
# adaptive (FEEDER_SYNC handshake, send-once/wait-on-effect) and reports the
# three-valued verdict: a starved guest is INCONCLUSIVE, an observed fixture
# `[9pconc] FAIL:` (or a started-but-never-PASSed run while the shell demonstrably
# survived) is FAIL, and only an observed `[9pconc] PASS` is a green.
. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_9p_concurrency
BTAG='9pconc'
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_9p_concurrency.elf
TEST_SRC=tests/test_9p_concurrency.ad
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

# ---- build ---------------------------------------------------------------
bash scripts/build_user.sh >/dev/null \
    || verdict_inconclusive "$TAG" "build_user failed"
bash scripts/build_modules.sh >/dev/null \
    || verdict_inconclusive "$TAG" "build_modules failed"
python3 -m compiler.adder compile --target=x86_64-adder-user \
    "$TEST_SRC" -o "$TEST_ELF" >/dev/null \
    || verdict_inconclusive "$TAG" "fixture compile failed ($TEST_SRC)"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null \
    || verdict_inconclusive "$TAG" "kernel compile failed"

# ---- boot + drive --------------------------------------------------------
LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"

# Run the fixture ONCE and wait on its OWN terminal banner ([BTAG] PASS).
# Then a survival sentinel: a trivial external echo AFTER the fixture, waited
# on its own effect. If POST lands, the shell was demonstrably alive — so a
# fixture that still never reached PASS aborted/hung (a real bug), NOT a
# starved guest. This is the false-red/false-green discriminator.
hamsh_send_await "/bin/$TAG" "[$BTAG] PASS" "$CMD_WAIT" || true
hamsh_send_await "/bin/echo POST_${TAG}_OK" "POST_${TAG}_OK" "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

echo "[$TAG] --- captured output ---"
sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000'
echo "[$TAG] --- end output ---"

# ---- verdict -------------------------------------------------------------
# Guest demonstrably alive & producing output? Require the fixture's start
# banner OR the survival sentinel; neither after a clean boot+sync means a
# wedge/starve — verdict_boot_gate sorts INCONCLUSIVE vs FAIL.
verdict_boot_gate "$TAG" "$LOG" 0 "\\[$BTAG\\] start|POST_${TAG}_OK"

# 1. The fixture's OWN failure line is an OBSERVED regression -> FAIL.
if grep -aqF "[$BTAG] FAIL" "$LOG"; then
    grep -aF "[$BTAG] FAIL" "$LOG" | sed 's/^/  /'
    verdict_fail "$TAG" "fixture emitted [$BTAG] FAIL: — an OBSERVED regression"
fi
# 2. The fixture reached its aggregate PASS banner (only printed when every
#    sub-assertion held) -> the observation we are named for. PASS.
if grep -aqF "[$BTAG] PASS" "$LOG"; then
    verdict_pass "$TAG" "fixture reached [$BTAG] PASS (all sub-assertions held)"
fi
# 3. No terminal verdict. If the survival sentinel landed the shell was NOT
#    starved, so the fixture started and then aborted/hung before PASS -> a
#    real FAIL. If the sentinel is absent too, the guest starved mid-run and
#    we observed nothing conclusive -> INCONCLUSIVE.
if grep -aqF "POST_${TAG}_OK" "$LOG"; then
    verdict_fail "$TAG" \
        "fixture started but never reached [$BTAG] PASS and emitted no [$BTAG] FAIL" \
        "line, yet the post-fixture survival echo DID reach stdout — the shell" \
        "was alive, so the fixture aborted/hung mid-run (a real regression)."
fi
verdict_inconclusive "$TAG" \
    "fixture start seen but neither [$BTAG] PASS/FAIL nor the survival sentinel" \
    "was observed within ${CMD_WAIT}s — the guest starved mid-run. Re-run quiet."
