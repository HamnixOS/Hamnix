#!/usr/bin/env bash
# scripts/test_hamsh_complete.sh — hamsh interactive Tab completion.
#
# The interactive line editor (user/hamsh.ad :: ed_readline / _ed_complete)
# completes the token under the cursor when Tab (0x09) is pressed:
#
#   * FIRST word (command position) — completes against the builtin
#     verbs plus every executable in /bin, /sbin, /usr/bin.
#   * a later word (argument)       — completes a partial path against
#     file/dir names in the current namespace; a directory match gets a
#     trailing '/'.
#
# Behaviour is the readline standard: Tab extends the token to the
# longest common prefix; a unique match completes fully (trailing ' ');
# an ambiguous prefix with no further common prefix arms a second Tab
# which LISTS the candidates.
#
# This test drives the editor over the serial console with raw bytes
# (Tab = \011) and asserts the COMPLETED command is what runs.
#
# Non-interactive rc/init mode does NOT use the editor, so this test
# (hamsh booted directly as /init, no rc) exercises only the
# interactive completion path.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_complete] (1/3) Build userland (incl. hamsh)"
bash scripts/build_user.sh >/dev/null

echo "[test_hamsh_complete] (2/3) Swap /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamsh_complete] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Wait for the shell to reach its prompt before sending input.
    sleep 4

    # --- Test 1: command-name completion (unique match) -------------
    # Type `ech` in the command position, then Tab. `ech` is a unique
    # prefix among the available commands (/bin/echo) so it completes
    # to `echo ` (with the trailing space). Then type the marker and
    # Enter -> the completed `echo cmdcomplete_ok` runs.
    printf 'ech'
    sleep 1
    printf '\011'
    sleep 1
    printf 'cmdcomplete_ok\n'
    sleep 2

    # --- Test 2: path completion in an argument position ------------
    # `echo /bin/upt` then Tab: the token `/bin/upt` is an argument
    # (not the first word), so path completion lists /bin and matches
    # the leaf `upt`. `/bin/uptime` is the unique match, so the token
    # completes to `/bin/uptime `. Enter -> `echo /bin/uptime` runs and
    # echoes the completed path back as its output.
    printf 'echo /bin/upt'
    sleep 1
    printf '\011'
    sleep 1
    printf '\n'
    sleep 2

    # --- Test 3: ambiguous prefix + Tab-Tab lists candidates --------
    # `ba` in the command position matches three commands: banner,
    # base64, basename. Their longest common prefix is just `ba`, so a
    # first Tab makes no progress (arms), and a SECOND consecutive Tab
    # LISTS the candidates and repaints the prompt + `ba` on the line.
    # Backspace twice clears `ba` so the line is empty for `exit`.
    printf 'ba'
    sleep 1
    printf '\011'
    sleep 1
    printf '\011'
    sleep 2
    printf '\177\177'
    sleep 1

    printf 'exit\n'
    sleep 1
) | timeout 40s qemu-system-x86_64 \
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

echo "[test_hamsh_complete] --- captured output ---"
cat "$LOG"
echo "[test_hamsh_complete] --- end output ---"

fail=0

# Command OUTPUT (vs. input echo) is the discriminator: the kernel
# console prefixes every output line with a `[NNNNNN]` timestamp, while
# the line editor's redraw always re-paints the `hamsh$ ` prompt first.
# A line matching `^[NNNNNN] <marker>` is genuine command output.
ran() { grep -E -q "^\[[0-9]+\] $1( |\$|\r)" "$LOG"; }

# Test 1: command completion — `ech`+Tab completed to `echo`, so the
# command `echo cmdcomplete_ok` ran and produced the marker output.
if ran "cmdcomplete_ok"; then
    echo "[test_hamsh_complete] OK: command completion -> echo ran"
else
    echo "[test_hamsh_complete] MISS: command completion failed"
    fail=1
fi

# Test 2: path completion — `/bin/upt`+Tab completed to `/bin/uptime`,
# so `echo /bin/uptime` ran and echoed the completed path.
if ran "/bin/uptime"; then
    echo "[test_hamsh_complete] OK: path completion -> /bin/uptime"
else
    echo "[test_hamsh_complete] MISS: path completion failed"
    fail=1
fi

# Test 3: ambiguous `ba`+Tab+Tab listed the candidate commands. The
# listing prints each candidate on its own line; those lines carry NO
# `[NNNNNN]` timestamp (they are written by the editor, not a command),
# so a plain grep for the names suffices. All three must appear.
if grep -E -q '(^|[^a-z])banner([^a-z]|$)' "$LOG" \
   && grep -E -q '(^|[^a-z])base64([^a-z]|$)' "$LOG" \
   && grep -E -q '(^|[^a-z])basename([^a-z]|$)' "$LOG"; then
    echo "[test_hamsh_complete] OK: ambiguous Tab-Tab listed candidates"
else
    echo "[test_hamsh_complete] MISS: ambiguous candidate list missing"
    fail=1
fi

# The shell must have survived all the completion editing and exited.
if grep -F -q "no live tasks" "$LOG"; then
    echo "[test_hamsh_complete] OK: shell exited cleanly after completion"
else
    echo "[test_hamsh_complete] MISS: shell did not exit cleanly"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_hamsh_complete] DIAG: kernel reported a CPU exception"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_complete] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hamsh_complete] PASS"
