#!/usr/bin/env bash
# scripts/test_symlink_user.sh — task #445: native symlink through the
# REAL userland syscall path.
#
# WHY THIS GATE EXISTS
#
# SYS_SYMLINK (305) was silently dead for months: a later msync commit
# (d6ae0a60) re-took number 305 for SYS_MSYNC, and the dispatcher's
# MSYNC arm sits before the SYMLINK arm — so every userland
# sys_symlink() actually ran msync, whose page-alignment check on the
# target-string pointer returned -EINVAL. `ln -s` could never create a
# symlink. CI never noticed because the in-kernel tmpfs_link_selftest
# calls vfs_symlink() DIRECTLY, bypassing the syscall number entirely.
# (Fix: SYS_MSYNC renumbered 305 → 314; VFS §links owns 305/306.)
#
# This gate closes that hole by exercising the full chain a user hits:
#   hamsh → spawn /bin/ln (user/ln.ad) → user/runtime.S sys_symlink
#   (syscall nr 305) → kernel dispatcher SYS_SYMLINK arm → vfs_symlink
#   → tmpfs symlink slot → vfs_open symlink-follow on read-back.
#
# Mechanism (interactive hamsh over serial, modeled on test_ext4.sh):
#   1. Boot the kernel with hamsh as /init (the _build_lock.sh qemu
#      shim wraps the 64-bit ELF in a BIOS GRUB ISO automatically — a
#      raw `qemu -kernel` of the higher-half ELF always fails).
#   2. echo SYMUSER_PAYLOAD_445_OK > /tmp/symtgt.txt   (target file)
#   3. ln -s /tmp/symtgt.txt /tmp/symlnk445            (the syscall!)
#   4. cat /tmp/symlnk445                              (follow + read)
#
# STRICTNESS: the proof line is the payload appearing WITHOUT the
# "symtgt" substring on the same line. The only typed line containing
# the payload is the echo command, which also contains "symtgt.txt";
# `cat /tmp/symlnk445`'s command echo contains no payload. So a bare
# payload line can ONLY be cat's stdout — i.e. the symlink was created
# by the real SYS_SYMLINK syscall and followed on open. If symlink is
# broken, ln prints "ln: cannot create symlink", cat emits nothing,
# and the gate FAILs.
#
# Feeder discipline: gate every send on a serial marker, never a fixed
# sleep. A freshly-booted hamsh readline drops the FIRST serial command
# line (never echoes it), so each command is RE-SENT until its own
# marker appears in the log. qemu rc=124 (timeout) after the markers
# have landed is benign — we judge strictly by marker lines.
#
# Pass marker:  [test_symlink_user] PASS
# Fail marker:  [test_symlink_user] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
PAYLOAD="SYMUSER_PAYLOAD_445_OK"

echo "[test_symlink_user] (1/4) Build userland (ln + hamsh)"
bash scripts/build_user.sh >/dev/null

echo "[test_symlink_user] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_symlink_user] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_symlink_user] (4/4) Boot QEMU and drive ln -s via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# Re-send `$1` (a command line) up to $3 times until literal marker
# `$2` shows up in the serial log. The first line a freshly-booted
# readline receives is silently dropped, and under host load any
# command can land before the prompt — re-sending until the command's
# own serial echo (or output) appears is the only reliable discipline.
feed_until() {
    local cmd="$1" marker="$2" tries="${3:-20}"
    local i
    for i in $(seq 1 "$tries"); do
        printf '%s\n' "$cmd"
        sleep 1
        if grep -a -F -q "$marker" "$LOG" 2>/dev/null; then return 0; fi
    done
    return 0   # let the post-run grep assertions report the MISS
}

set +e
(
    # Gate on hamsh's readline coming up instead of a fixed sleep.
    for _ in $(seq 1 240); do
        if grep -aq "loop-enter" "$LOG" 2>/dev/null; then break; fi
        sleep 0.25
    done
    # Sync probe: re-send until keystrokes echo back.
    feed_until 'echo FEEDER_SYNC' 'FEEDER_SYNC'
    # (a) Create the symlink TARGET on tmpfs (writable). Marker: the
    #     command echo itself (contains "symtgt.txt").
    feed_until "echo $PAYLOAD > /tmp/symtgt.txt" 'symtgt.txt'
    # (b) THE syscall under test: ln -s → sys_symlink (nr 305).
    #     Marker: the command echo (contains "symlnk445"). Re-sends are
    #     harmless: a second ln over an existing link just errors.
    feed_until 'ln -s /tmp/symtgt.txt /tmp/symlnk445' 'symlnk445'
    # (c) Read THROUGH the link. Its stdout is the bare payload — the
    #     only payload line with no "symtgt" on it. Re-send until that
    #     proof line lands (cat is idempotent).
    for _ in $(seq 1 20); do
        printf 'cat /tmp/symlnk445\n'
        sleep 1
        if grep -a -F "$PAYLOAD" "$LOG" 2>/dev/null \
           | grep -v -e 'symtgt' -e 'echo' -e 'hamsh\$' | grep -q .; then break; fi
    done
    printf 'exit\n'
    sleep 1
) | timeout 150s qemu-system-x86_64 \
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

echo "[test_symlink_user] --- captured output ---"
cat "$LOG"
echo "[test_symlink_user] --- end output ---"

fail=0

# 1. The shell came up and echoed our sync probe.
if grep -a -F -q "FEEDER_SYNC" "$LOG"; then
    echo "[test_symlink_user] OK: shell interactive (FEEDER_SYNC echoed)"
else
    echo "[test_symlink_user] MISS: shell never echoed FEEDER_SYNC"
    fail=1
fi

# 2. THE proof: payload read back through the symlink. A bare payload
#    line can only be `cat /tmp/symlnk445` stdout: the only TYPED line
#    carrying the payload is the echo command, whose keystroke echo is
#    excluded by the 'symtgt'/'echo'/'hamsh$' filters (even if the
#    serial stream splits it, every fragment carries the redrawn
#    "hamsh$ echo ..." prefix); the cat command line carries no
#    payload. This fails if SYS_SYMLINK is dead (e.g. shadowed by a
#    colliding syscall number) or symlink-follow on open breaks.
if grep -a -F "$PAYLOAD" "$LOG" | grep -v -e 'symtgt' -e 'echo' -e 'hamsh\$' | grep -q .; then
    echo "[test_symlink_user] OK: read THROUGH /tmp/symlnk445 returned the payload"
else
    echo "[test_symlink_user] MISS: payload never came back through the symlink"
    if grep -a -F -q "ln: cannot create symlink" "$LOG"; then
        echo "[test_symlink_user]       (ln reported 'cannot create symlink' — SYS_SYMLINK path broken?)"
    fi
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_symlink_user] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_symlink_user] PASS (qemu rc=$rc is benign post-markers)"
