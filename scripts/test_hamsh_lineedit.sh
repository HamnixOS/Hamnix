#!/usr/bin/env bash
# scripts/test_hamsh_lineedit.sh — hamsh interactive line editor.
#
# The interactive prompt now has a full cursor-aware line editor
# (user/hamsh.ad :: ed_readline). This test drives the editor over the
# serial console with raw ANSI escape sequences and asserts the edited
# command is what actually runs.
#
# COVERAGE
#   * Left arrow + mid-line insert — type a word missing a letter, move
#     the cursor back into it, type the missing letter, Enter; the
#     CORRECTED command must run.
#   * Delete key (ESC[3~) — type a word with an extra letter, jump the
#     cursor (Home then Right x N) to the extra letter, Delete it,
#     Enter; the CORRECTED command must run.
#   * End key (ESC[F) — after a Home-then-edit, End jumps to line end so
#     trailing text is appended correctly.
#   * Command history (Up arrow, ESC[A) — enter a command, then at the
#     next prompt press Up to recall it and Enter to run it AGAIN.
#   * Backspace remains cursor-aware (deletes the char before cursor).
#
# The escape bytes are emitted with printf's \NNN octal escapes:
#   ESC      = \033
#   Left     = \033[D     Right = \033[C
#   Up       = \033[A     Down  = \033[B
#   Home     = \033[H     End   = \033[F
#   Delete   = \033[3~
#   Backspace= \177  (DEL)
#
# Non-interactive rc/init mode does NOT use the line editor — it reads
# its script with a plain file read — so this test (which boots hamsh
# directly as /init, no rc) exercises only the interactive path.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_lineedit] (1/3) Build userland (incl. hamsh)"
bash scripts/build_user.sh >/dev/null

echo "[test_hamsh_lineedit] (2/3) Swap /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamsh_lineedit] (3/3) Rebuild kernel image"
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

    # --- Test 1: Left arrow + mid-line insert -----------------------
    # Type `echo helo_one` (the word should be `hello_one` — one `l`
    # missing). Cursor is at end (column 13). Move Left 5 times to land
    # between the single `l` and the `o` (echo hel|o_one), type the
    # missing `l`, then Enter -> the corrected `echo hello_one` runs.
    printf 'echo helo_one'
    sleep 1
    printf '\033[D\033[D\033[D\033[D\033[D'
    sleep 1
    printf 'l\n'
    sleep 1

    # --- Test 2: Delete key (ESC[3~) at a jumped cursor -------------
    # Type `echo helllo_two` (extra `l`: `hel` + `l` + `lo_two`).
    # Home to column 0, Right x 7 to land on an extra `l`
    # (`echo hel|llo_two`), Delete removes it -> `echo hello_two`.
    printf 'echo helllo_two'
    sleep 1
    printf '\033[H'
    sleep 1
    printf '\033[C\033[C\033[C\033[C\033[C\033[C\033[C'
    sleep 1
    printf '\033[3~'
    sleep 1
    printf '\n'
    sleep 1

    # --- Test 3: Home + edit + End + append -------------------------
    # Type `echo three`, Home, type `X` at the start (-> `Xecho three`
    # which is not a command), so instead: Home, then End jumps back to
    # the end and we append `_ok` -> `echo three_ok`. This proves End
    # works after Home.
    printf 'echo three'
    sleep 1
    printf '\033[H'
    sleep 1
    printf '\033[F'
    sleep 1
    printf '_ok\n'
    sleep 1

    # --- Test 4: Backspace is cursor-aware --------------------------
    # Type `echo fourZ`, Backspace removes the `Z` (char before the
    # cursor), append `_done` -> `echo four_done`.
    printf 'echo fourZ'
    sleep 1
    printf '\177'
    sleep 1
    printf '_done\n'
    sleep 1

    # --- Test 5: Command history (Up arrow) -------------------------
    # The previous line `echo four_done` is now the newest history
    # entry. Press Up to recall it, then Enter to run it AGAIN. The
    # command output `four_done` must therefore appear a SECOND time.
    printf '\033[A'
    sleep 1
    printf '\n'
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

echo "[test_hamsh_lineedit] --- captured output ---"
cat "$LOG"
echo "[test_hamsh_lineedit] --- end output ---"

fail=0

# Command OUTPUT (vs. input echo) is the discriminator. The `echo`
# builtin writes its argument on a line of its own; the kernel console
# prefixes every output line with a `[NNNNNN]` timestamp. The line
# editor's redraw, by contrast, always re-paints the `hamsh$ ` prompt
# first. So a line matching `^[NNNNNN] <marker>` is genuine command
# output — proof the EDITED command actually ran — whereas a line with
# `hamsh$` before the marker is only the input being echoed back.
#
# ran <marker>  -> 0 if <marker> appeared as echo command output.
ran() { grep -E -q "^\[[0-9]+\] $1( |\$|\r)" "$LOG"; }
# ran_count <marker> -> number of command-output lines for <marker>.
ran_count() { grep -E -c "^\[[0-9]+\] $1( |\$|\r)" "$LOG" || true; }

# Test 1: Left + mid-line insert — the CORRECTED `echo hello_one` ran,
# and the typo'd `helo_one` never ran as a command.
if ran "hello_one" && ! ran "helo_one"; then
    echo "[test_hamsh_lineedit] OK: Left arrow + mid-line insert -> hello_one"
else
    echo "[test_hamsh_lineedit] MISS: Left/insert did not yield hello_one"
    fail=1
fi

# Test 2: Delete at a jumped cursor — corrected `echo hello_two` ran,
# the typo'd `helllo_two` did not.
if ran "hello_two" && ! ran "helllo_two"; then
    echo "[test_hamsh_lineedit] OK: Home + Right + Delete -> hello_two"
else
    echo "[test_hamsh_lineedit] MISS: Delete did not yield hello_two"
    fail=1
fi

# Test 3: End after Home let us append `_ok` at the line end.
if ran "three_ok"; then
    echo "[test_hamsh_lineedit] OK: Home + End + append -> three_ok"
else
    echo "[test_hamsh_lineedit] MISS: End-after-Home append failed"
    fail=1
fi

# Test 4: cursor-aware Backspace removed exactly the char before cursor
# (`echo four_done` ran; the typo'd `fourZ_done` did not).
if ran "four_done" && ! ran "fourZ_done"; then
    echo "[test_hamsh_lineedit] OK: cursor-aware Backspace -> four_done"
else
    echo "[test_hamsh_lineedit] MISS: Backspace edit failed"
    fail=1
fi

# Test 5: Up-arrow recalled the previous command — `echo four_done`
# ran TWICE (original entry + the history recall), so `four_done`
# appears as command output at least twice.
hits=$(ran_count "four_done")
if [ "${hits:-0}" -ge 2 ]; then
    echo "[test_hamsh_lineedit] OK: Up arrow recalled history (four_done x$hits)"
else
    echo "[test_hamsh_lineedit] MISS: history recall failed (four_done x${hits:-0})"
    fail=1
fi

# The shell must have survived all the editing and exited cleanly.
if grep -F -q "no live tasks" "$LOG"; then
    echo "[test_hamsh_lineedit] OK: shell exited cleanly after editing"
else
    echo "[test_hamsh_lineedit] MISS: shell did not exit cleanly"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_hamsh_lineedit] DIAG: kernel reported a CPU exception"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_lineedit] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_hamsh_lineedit] PASS"
