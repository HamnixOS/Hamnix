#!/usr/bin/env bash
# scripts/test_hamsh_complete.sh — hamsh interactive Tab completion, end
# to end over the serial console.
#
# The interactive line editor (user/hamsh.ad :: ed_readline / _ed_complete)
# completes the token under the cursor when Tab (0x09) is pressed. The pure
# matching kernel (lib/hamcomplete.ad) is unit-tested QEMU-free by
# scripts/test_hamsh_complete_host.sh; THIS gate proves the whole on-device
# path — /bin scan + dirread wiring + the editor redraw:
#
#   * FIRST word (command position) — completes against the builtin verbs
#     plus every executable in /bin, /sbin, /usr/bin.
#   * a later word (argument)       — completes a partial path against
#     file/dir names in the namespace; a directory match gets a trailing '/'.
#
# Readline standard: Tab extends the token to the longest common prefix; a
# unique match completes fully (trailing ' ' for a command, '/' for a dir);
# an ambiguous prefix with no further common prefix arms a second Tab which
# LISTS the candidates.
#
# ROBUSTNESS: this gate is prompt-gated + output-adaptive via
# scripts/_hamsh_drive.sh — it waits for the ready marker (never a fixed
# sleep), does the FEEDER_SYNC handshake that absorbs hamsh's first-serial-
# line drop, and asserts on GUEST-produced command OUTPUT (not the typed-
# input echo). A completed command's output is the discriminator: `ech`+Tab
# only runs `echo` if completion produced the verb, so the echo'd marker
# appears as a bare output line ONLY when completion actually happened.
#
# Non-interactive rc/init mode does NOT use the editor, so this test
# (hamsh booted directly as /init, no rc) exercises only the interactive
# completion path.

set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_complete
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

echo "[$TAG] (1/3) Build userland (incl. hamsh)"
bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
echo "[$TAG] (2/3) Swap /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"
echo "[$TAG] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null \
    || verdict_inconclusive "$TAG" "kernel compile failed"

LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG"
}
trap cleanup EXIT

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh:stage-07] loop-enter" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"

# raw <bytes> — write raw bytes (Tab \t, Enter \n, DEL \177) to the guest's
# stdin FIFO WITHOUT a trailing newline. `hamsh_send` always appends \n, so
# a partial-token-plus-Tab needs this lower-level send.
raw() { printf '%b' "$1" >&3 2>/dev/null || true; }

# await_out <exact-line> <secs> — bounded wait until some command printed a
# line whose WHOLE content equals <exact-line> (input echo dropped, ANSI +
# kernel chatter stripped by hamsh_out_eq). Adaptive: costs only as long as
# the guest needs.
await_out() {
    local text="$1" secs="$2" i
    for i in $(seq 1 "$secs"); do
        hamsh_out_eq "$LOG" "$text" && return 0
        hamsh_alive || return 1
        sleep 1
    done
    return 1
}

# await_listed <name> <secs> — bounded wait until <name> appears as a
# command-output line (the ambiguous-Tab candidate listing).
await_listed() {
    local name="$1" secs="$2" i
    for i in $(seq 1 "$secs"); do
        hamsh_ran "$LOG" "$name" && return 0
        hamsh_alive || return 1
        sleep 1
    done
    return 1
}

# --- Test 1: command-name completion (unique match) -----------------
# `ech`+Tab is a unique command prefix (the `echo` builtin / /bin/echo dedup
# to one candidate) so it completes to `echo ` (trailing space). Typing the
# marker then Enter runs `echo CMP_CMD_OK`, which prints CMP_CMD_OK on its
# own output line. Had completion NOT fired, the line would be
# `echCMP_CMD_OK` -> a "command not found" error, never a bare CMP_CMD_OK.
raw 'ech\t'
sleep 1
raw 'CMP_CMD_OK\n'
await_out 'CMP_CMD_OK' "$CMD_WAIT" || true

# --- Test 2: path FILE completion in an argument position -----------
# `echo /bin/upt`+Tab: the argument token splits into dir `/bin` + leaf
# `upt`; /bin is listed and `uptime` is the unique leaf match, so the token
# completes to `/bin/uptime ` and `echo /bin/uptime` prints /bin/uptime.
raw 'echo /bin/upt\t'
sleep 1
raw '\n'
await_out '/bin/uptime' "$CMD_WAIT" || true

# --- Test 3: path DIR completion gets a trailing '/' ----------------
# `echo /bi`+Tab: leaf `bi` under `/` uniquely matches the `bin` DIRECTORY,
# so completion appends a trailing '/', giving `/bin/`. `echo /bin/` prints
# /bin/ — the trailing slash is the directory-decoration proof.
raw 'echo /bi\t'
sleep 1
raw '\n'
await_out '/bin/' "$CMD_WAIT" || true

# --- Test 4: ambiguous prefix + Tab-Tab lists candidates ------------
# `ba` in command position matches banner, base64, basename (common prefix
# `ba` only). A first Tab makes no progress (arms); a SECOND consecutive Tab
# LISTS the candidates on their own lines and repaints the prompt. Backspace
# twice clears `ba`.
raw 'ba\t\t'
await_listed 'banner' "$CMD_WAIT" || true
await_listed 'base64' "$CMD_WAIT" || true
await_listed 'basename' "$CMD_WAIT" || true
raw '\177\177'
sleep 1

# Survival sentinel — the shell must still take a normal command after all
# the completion editing.
hamsh_send_await 'echo GATE_DONE' 'GATE_DONE' "$CMD_WAIT" || true
hamsh_send 'exit'

echo "[$TAG] --- command-output lines ---"
hamsh_outlines "$LOG" | tail -40
echo "[$TAG] --- end output ---"

fail=0

if hamsh_out_eq "$LOG" "CMP_CMD_OK"; then
    echo "[$TAG] OK: command completion (ech+Tab -> echo) ran"
else
    echo "[$TAG] WRONG: command completion did not complete ech->echo"; fail=1
fi

if hamsh_out_eq "$LOG" "/bin/uptime"; then
    echo "[$TAG] OK: path file completion (/bin/upt+Tab -> /bin/uptime)"
else
    echo "[$TAG] WRONG: path file completion failed"; fail=1
fi

if hamsh_out_eq "$LOG" "/bin/"; then
    echo "[$TAG] OK: path dir completion (/bi+Tab -> /bin/ with trailing slash)"
else
    echo "[$TAG] WRONG: path dir completion (trailing slash) failed"; fail=1
fi

if hamsh_ran "$LOG" "banner" && hamsh_ran "$LOG" "base64" \
   && hamsh_ran "$LOG" "basename"; then
    echo "[$TAG] OK: ambiguous Tab-Tab listed all candidates"
else
    echo "[$TAG] WRONG: ambiguous candidate list incomplete"; fail=1
fi

if hamsh_ran "$LOG" "GATE_DONE"; then
    echo "[$TAG] OK: shell survived the completion editing"
else
    echo "[$TAG] WRONG: shell did not survive to GATE_DONE"; fail=1
fi

if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[$TAG] WRONG: kernel reported a CPU exception"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- full serial tail ---" >&2
    tail -60 "$LOG" >&2
    verdict_fail "$TAG" "a Tab-completion assertion was VIOLATED"
fi
verdict_pass "$TAG" "command + path (file & dir) completion, LCP, and ambiguous Tab-Tab listing all work on-device"
