#!/usr/bin/env bash
# scripts/test_init_rescue.sh — PID-1 rescue-shell fallback verification.
#
# DEFECT under test: historically, if /bin/hamsh was missing or corrupt,
# user/init.ad (PID 1) wrote "FATAL" and returned 1 — PID 1 exited and
# the box was a brick with zero diagnosis. The fix gives init a recovery
# path: try fallback shells, then drop to a self-contained built-in
# RESCUE LOOP reading /dev/cons (ls/cat/echo/exec-abs-path builtins).
#
# This test SIMULATES a broken primary shell by building a cpio that
# does NOT contain /bin/hamsh (every build/user/*hamsh*.elf is held back
# from the initramfs build). The kernel still loads /init (the
# rescue-capable shim) into PID 1; its /bin/hamsh exec must fail, every
# fallback shell exec must fail (none are present), and init must drop
# into the rescue prompt. We then feed it commands over the serial
# console and assert:
#   * the rescue banner + WHY-it-fired message prints (not a silent hang),
#   * the rescue prompt "rescue> " appears,
#   * a builtin (`echo`) executes and echoes back,
#   * `ls /` lists at least the /init entry (proves cat-of-dir works),
# i.e. a human at the console gets a usable prompt instead of a dead box.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

bash scripts/build_user.sh >/dev/null

# --- simulate a broken/missing primary shell ------------------------
# Move every hamsh ELF out of build/user/ so the initramfs build plants
# NO /bin/hamsh (and no fallback shell) in the cpio. /init itself (the
# rescue-capable shim) is still embedded. A trap restores them and
# rebuilds a clean default initramfs so the rest of the suite is
# unaffected.
STASH=$(mktemp -d)
LOG=$(mktemp)
restore() {
    for f in "$STASH"/*.elf; do
        [ -e "$f" ] || continue
        mv -f "$f" build/user/ 2>/dev/null || true
    done
    rmdir "$STASH" 2>/dev/null || true
    rm -f "$LOG"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap restore EXIT

shopt -s nullglob
moved=0
for f in build/user/*hamsh*.elf; do
    mv -f "$f" "$STASH"/
    moved=$((moved+1))
done
shopt -u nullglob
if [ "$moved" -eq 0 ]; then
    echo "[test_init_rescue] WARN: no hamsh ELF found to stash (build_user changed?)"
fi

# Default /init = build/user/init.elf (the rescue-capable shim).
python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

set +e
# NOTE: -smp 1. A rescue console is inherently single-threaded — PID 1 is
# the ONLY user task and just blocks on a /dev/cons read. Running it on a
# single CPU sidesteps the unrelated AP steal-window race (memory #413:
# an AP can steal a not-yet-saved task at a schedule() boundary) that can
# otherwise #GP the box when the sole user task blocks under -smp 2. The
# rescue path itself is SMP-agnostic; the single CPU just keeps THIS test
# deterministic. Normal multi-CPU boot is covered by scripts/test_rc.sh.
# Input is driven through a FIFO so it can be gated on the boot output
# (the "rescue> " prompt) rather than a fixed sleep — boot timing varies
# wildly under concurrent build load, and a fixed sleep races the prompt.
# The freshly-spawned rescue console can also drop the FIRST serial line
# (the documented hamsh first-command-drop), so each command is RE-SENT
# until its own marker appears in the log.
FIFO=$(mktemp -u)
mkfifo "$FIFO"
# Start QEMU FIRST, reading the FIFO as stdin, in the background. QEMU's
# open-for-read blocks until a writer appears, but it is backgrounded so
# the script proceeds. THEN open the write end on fd 3 — by now a reader
# (QEMU) exists so the open returns immediately (no deadlock). Holding
# fd 3 open also keeps QEMU's stdin from seeing EOF.
timeout 40s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QPID=$!
exec 3>"$FIFO"

wait_for() {  # wait_for <pattern> <max_seconds>
    local pat="$1" max="$2" i=0
    while [ "$i" -lt "$max" ]; do
        grep -F -q "$pat" "$LOG" 2>/dev/null && return 0
        kill -0 "$QPID" 2>/dev/null || return 1
        sleep 1
        i=$((i+1))
    done
    return 1
}
send_until() {  # send_until <line> <marker> <retries>
    local line="$1" marker="$2" retries="$3" k=0
    while [ "$k" -lt "$retries" ]; do
        grep -F -q "$marker" "$LOG" 2>/dev/null && return 0
        printf '%s\n' "$line" >&3
        sleep 2
        k=$((k+1))
    done
    grep -F -q "$marker" "$LOG" 2>/dev/null
}

# Gate on the rescue prompt, then exercise the builtins (re-sending each
# until its marker lands).
if wait_for "rescue> " 35; then
    # `echo` proves the prompt reads a line and runs a builtin. Its marker
    # (RESCUE_ECHO_OK) is unique, so send_until keys on it directly.
    send_until 'echo RESCUE_ECHO_OK' 'RESCUE_ECHO_OK' 6
    # `ls /` proves the directory-listing builtin works. Its output has no
    # unique token (the bare entry "bin" also appears in boot noise), so we
    # can't key send_until on it. Instead send `ls /` a few times
    # (idempotent), then send a UNIQUE trailing echo and wait for THAT —
    # once LSDONE lands, the preceding `ls /` was definitely consumed and
    # its listing is in the log. The assertion below then matches a
    # WHOLE-LINE "bin" (which only the per-entry "NAME\n" listing emits).
    k=0
    while [ "$k" -lt 4 ]; do printf 'ls /\n' >&3; sleep 1; k=$((k+1)); done
    send_until 'echo LSDONE' 'LSDONE' 6
fi

# Let any final output flush, then tear QEMU down.
sleep 1
exec 3>&-
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
rm -f "$FIFO"
set -e

fail=0
# init detected the primary exec failed and announced recovery.
if grep -F -q "entering recovery: trying fallback shells" "$LOG"; then
    echo "[test_init_rescue] OK: init announced recovery after primary exec failed"
else
    echo "[test_init_rescue] MISS: init did not announce recovery"
    fail=1
fi
# The rescue banner printed (explains WHY + that this is the rescue shell).
if grep -F -q "RESCUE SHELL — the normal boot path FAILED." "$LOG"; then
    echo "[test_init_rescue] OK: rescue banner printed (clear WHY message)"
else
    echo "[test_init_rescue] MISS: rescue banner not seen"
    fail=1
fi
# The rescue prompt appeared.
if grep -F -q "rescue> " "$LOG"; then
    echo "[test_init_rescue] OK: rescue prompt appeared"
else
    echo "[test_init_rescue] MISS: rescue prompt 'rescue> ' not seen"
    fail=1
fi
# A builtin (echo) ran and echoed back.
if grep -F -q "RESCUE_ECHO_OK" "$LOG"; then
    echo "[test_init_rescue] OK: rescue 'echo' builtin executed"
else
    echo "[test_init_rescue] MISS: rescue 'echo' builtin produced no output"
    fail=1
fi
# `ls /` listed the directory: the rescue ls builtin emits one "NAME\n"
# per entry, so a WHOLE-LINE "bin" appears only in that listing (boot-log
# lines that contain "bin" are never the bare token alone).
if grep -F -x -q "bin" "$LOG"; then
    echo "[test_init_rescue] OK: rescue 'ls /' listed directory contents"
else
    echo "[test_init_rescue] MISS: rescue 'ls /' produced no listing"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_init_rescue] --- captured ---"
    cat "$LOG"
    echo "[test_init_rescue] --- end ---"
    echo "[test_init_rescue] FAIL"
    exit 1
fi
echo "[test_init_rescue] PASS"
