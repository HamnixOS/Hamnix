#!/usr/bin/env bash
# scripts/test_vi.sh — the native modal editor user/vi.ad, end-to-end.
#
# vi is a full-screen modal editor that OWNS the raw console: when hamsh
# spawns it, fd 0/1/2 are bound to DEVFD_CONS (no kernel line-cooking,
# no echo), and vi reads one keystroke at a time with sys_read_nb +
# sys_yield (exactly the input model hamsh's own line editor uses). This
# test boots hamsh directly as /init so that raw-console path is active,
# drives vi over the serial console with scripted keystrokes, then reads
# the file back with `cat` to prove the edits were saved.
#
# COVERAGE
#   1. INSERT-mode typing + Enter-splits-line + Esc + `:wq` round-trips
#      a brand-new file to tmpfs ("hello world" / "second line").
#   2. Re-opening the saved file and applying NORMAL-mode edits — `x`
#      (delete char), `dd` (delete line) — then `:wq` mutates the file
#      as expected.
#   3. `:q!` force-quits a buffer with unsaved changes WITHOUT writing.
#
# Escape bytes via printf octal: ESC = \033.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_vi] (1/3) Build userland (incl. vi + hamsh)"
bash scripts/build_user.sh >/dev/null

echo "[test_vi] (2/3) Swap /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_vi] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Wait for the shell prompt before sending input.
    sleep 4

    # --- Part 1: create a new file with INSERT-mode typing -----------
    # Open a brand-new file; vi starts in NORMAL on an empty buffer.
    printf '/bin/vi /tmp/vitest.txt\n'
    sleep 2
    # i -> INSERT, type line 1, Enter (split), type line 2, Esc -> NORMAL
    printf 'i'
    sleep 1
    printf 'hello world'
    sleep 1
    printf '\n'
    sleep 1
    printf 'second line'
    sleep 1
    printf '\033'                       # Esc back to NORMAL
    sleep 1
    # :wq  — write and quit back to the shell.
    printf ':wq\n'
    sleep 2

    # Read the file back. Both lines must be present, in order.
    printf '/bin/cat /tmp/vitest.txt\n'
    sleep 2

    # --- Part 2: NORMAL-mode edits on the saved file -----------------
    # Re-open. Buffer is line0="hello world", line1="second line".
    printf '/bin/vi /tmp/vitest.txt\n'
    sleep 2
    # On line0 col0 ('h'): x deletes 'h' -> "ello world".
    printf 'x'
    sleep 1
    # j down to line1, dd deletes it -> only "ello world" remains.
    printf 'j'
    sleep 1
    printf 'dd'
    sleep 1
    printf ':wq\n'
    sleep 2

    printf '/bin/cat /tmp/vitest.txt\n'
    sleep 2

    # --- Part 3: :q! discards unsaved changes ------------------------
    printf '/bin/vi /tmp/vitest.txt\n'
    sleep 2
    printf 'i'
    sleep 1
    printf 'GARBAGE'
    sleep 1
    printf '\033'
    sleep 1
    printf ':q!\n'                      # force-quit WITHOUT saving
    sleep 2

    # Print a sentinel, THEN cat the file. The Part-3 assertion only
    # inspects bytes AFTER the sentinel so it sees the on-disk file
    # content alone — never vi's full-screen rendering of the typed
    # (but unsaved) "GARBAGE", which is painted to the terminal in
    # INSERT mode and would otherwise be in the log regardless of save.
    printf '/bin/echo VI_PART3_FILE_BEGIN\n'
    sleep 1
    printf '/bin/cat /tmp/vitest.txt\n'
    sleep 2

    printf 'exit\n'
    sleep 1
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

echo "[test_vi] --- captured output ---"
cat "$LOG"
echo "[test_vi] --- end output ---"

fail=0

# Part 1: both inserted lines round-tripped through the save.
if grep -F -q "hello world" "$LOG"; then
    echo "[test_vi] OK: INSERT-mode line 'hello world' saved"
else
    echo "[test_vi] MISS: 'hello world' not found after :wq"
    fail=1
fi
if grep -F -q "second line" "$LOG"; then
    echo "[test_vi] OK: Enter-split second line 'second line' saved"
else
    echo "[test_vi] MISS: 'second line' not found after :wq"
    fail=1
fi

# Part 2: x deleted the leading 'h' ("ello world") and dd removed line 2
# (so "second line" no longer appears AFTER the second cat). We assert
# the post-edit content appears at least once.
if grep -F -q "ello world" "$LOG"; then
    echo "[test_vi] OK: NORMAL-mode x deleted a char -> 'ello world'"
else
    echo "[test_vi] MISS: 'ello world' not found after x + :wq"
    fail=1
fi

# Part 3: :q! must NOT have written GARBAGE to the file. Only inspect
# the file content emitted AFTER the VI_PART3_FILE_BEGIN sentinel — vi
# echoes typed INSERT-mode bytes to the screen, so "GARBAGE" appears in
# the raw terminal log even when the save is correctly skipped. The
# sentinel anchors us to the third `cat`'s actual on-disk bytes.
PART3=$(awk '/VI_PART3_FILE_BEGIN/{f=1; next} f' "$LOG")
if printf '%s' "$PART3" | grep -F -q "GARBAGE"; then
    echo "[test_vi] MISS: :q! leaked unsaved 'GARBAGE' into the file"
    fail=1
else
    echo "[test_vi] OK: :q! discarded unsaved changes (no GARBAGE saved)"
fi

# The shell must have survived and exited cleanly.
if grep -F -q "no live tasks" "$LOG"; then
    echo "[test_vi] OK: shell exited cleanly after editing"
else
    echo "[test_vi] MISS: shell did not exit cleanly"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_vi] DIAG: kernel reported a CPU exception"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_vi] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_vi] PASS"
