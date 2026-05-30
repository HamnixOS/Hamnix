#!/usr/bin/env bash
# scripts/test_hamfm.sh — the native TUI file manager user/hamfm.ad, e2e.
#
# hamfm is a full-screen TUI exactly like vi: when hamsh spawns it, fd
# 0/1/2 are bound to the raw console (no kernel line-cooking, no echo),
# and hamfm reads one keystroke at a time with sys_read_nb + sys_yield,
# repainting the whole screen with ANSI escapes on every state change.
# This test boots hamsh directly as /init (so that raw-console path is
# live), drives hamfm over the serial console with scripted keystrokes,
# and asserts deterministic markers in the captured screen output.
#
# COVERAGE (the four required assertions)
#   (a) LIST a directory: launch `hamfm /`; the root listing shows the
#       known directory `bin/` and `etc/` (dirs render with a trailing
#       '/'; the directory test is sys_listdir, mirroring user/find.ad).
#   (b) DESCEND into a subdir: from `/`, move the cursor to `etc` (init
#       -> bin -> etc) and Enter; the /etc listing shows the known file
#       `hostname`.
#   (c) VIEW a file inline: in /etc, move the cursor to `hostname`
#       (debian_version -> fstab -> group -> host.conf -> hostname) and
#       Enter; hamfm reads the file in-process (NO child spawn) and the
#       file's content `hamnix` (etc/hostname) appears on screen.
#   (d) CLEAN quit: `q` returns to the shell, which exits cleanly with
#       no kernel PANIC / TRAP / BUG.
#
# The orchestrator reads the explicit `[test_hamfm] PASS` / `FAIL` line,
# not the exit code.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamfm] (1/3) Build userland (incl. hamfm + hamsh)"
bash scripts/build_user.sh >/dev/null

echo "[test_hamfm] (2/3) Swap /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamfm] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Generous settle before the FIRST command: keystrokes typed before
    # hamsh finishes its first-prompt startup get EATEN under loaded
    # interactive QEMU.
    sleep 6

    # --- Launch hamfm on the root directory (assertion a) ------------
    printf '/bin/hamfm /\n'
    # hamfm must fully take over the raw console from hamsh before the
    # navigation keys arrive; otherwise hamsh eats them. Settle long.
    sleep 5

    # Root listing order (alphabetical-ish, dirs + files):
    #   0:init 1:bin/ 2:etc/ 3:usr/ 4:var/ 5:lib/ 6:motd 7:version
    # Move the cursor down to `etc` (init -> bin -> etc): two 'j'.
    printf 'j'
    sleep 1
    printf 'j'
    sleep 1
    # Enter: descend into /etc (assertion b — /etc listing appears).
    printf '\n'
    sleep 3

    # /etc listing order:
    #   0:debian_version 1:fstab 2:group 3:host.conf 4:hostname ...
    # Move the cursor down to `hostname`: four 'j'.
    printf 'j'
    sleep 1
    printf 'j'
    sleep 1
    printf 'j'
    sleep 1
    printf 'j'
    sleep 1
    # Enter: VIEW /etc/hostname inline (assertion c — `hamnix` appears).
    printf '\n'
    sleep 3
    # Any key returns to the listing.
    printf ' '
    sleep 1
    # Quit hamfm back to the shell (assertion d).
    printf 'q'
    sleep 2

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

echo "[test_hamfm] --- captured output ---"
cat "$LOG"
echo "[test_hamfm] --- end output ---"

fail=0

# (a) Root directory listing showed the known dirs bin/ and etc/.
if grep -F -a -q "bin/" "$LOG"; then
    echo "[test_hamfm] OK: root listing showed 'bin/' (dir)"
else
    echo "[test_hamfm] MISS: 'bin/' not found in root listing"
    fail=1
fi
if grep -F -a -q "etc/" "$LOG"; then
    echo "[test_hamfm] OK: root listing showed 'etc/' (dir)"
else
    echo "[test_hamfm] MISS: 'etc/' not found in root listing"
    fail=1
fi

# (b) Descending into /etc worked — a file known to live there appears.
if grep -F -a -q "hostname" "$LOG"; then
    echo "[test_hamfm] OK: descended into /etc (saw 'hostname')"
else
    echo "[test_hamfm] MISS: '/etc/hostname' entry not found after descend"
    fail=1
fi

# (c) Viewing /etc/hostname inline showed its content ('hamnix').
if grep -F -a -q "hamnix" "$LOG"; then
    echo "[test_hamfm] OK: file view showed /etc/hostname content 'hamnix'"
else
    echo "[test_hamfm] MISS: file content 'hamnix' not shown by VIEW mode"
    fail=1
fi

# (d) Shell survived and exited cleanly.
if grep -F -a -q "no live tasks" "$LOG"; then
    echo "[test_hamfm] OK: shell exited cleanly after browsing"
else
    echo "[test_hamfm] MISS: shell did not exit cleanly"
    fail=1
fi

# No kernel fault of any kind.
if grep -E -a -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_hamfm] DIAG: kernel reported a fault"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamfm] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hamfm] PASS"
