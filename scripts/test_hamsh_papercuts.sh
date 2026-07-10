#!/usr/bin/env bash
# scripts/test_hamsh_papercuts.sh — hamsh interactive-error polish.
#
# A failing builtin must SHOW its diagnosis at the prompt: `cd` to a
# missing directory pulls the kernel's errstr (§16) and run_builtin
# prints `cd: <errstr>` — a bare failing builtin reports cleanly, exactly
# as a failed external prints "command not found" — and the shell
# survives to run the next command.
#
# (Arrow-key history line editing moved to scripts/test_hamsh_lineedit.sh.)
#
# INPUT IS PROMPT-GATED + OUTPUT-ADAPTIVE via scripts/_hamsh_drive.sh: the
# old fixed-sleep feeder could drop the first command under host load and
# false-red. The `cd:` error is printed BY the shell on its own output
# line (not part of any typed input), so a plain egrep of the log is
# unambiguous; the survival marker is checked as genuine command output.
set -uo pipefail
trap '' PIPE

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_hamsh_papercuts
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"

bash scripts/build_user.sh >/dev/null || verdict_inconclusive "$TAG" "build_user failed"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || verdict_inconclusive "$TAG" "build_initramfs failed"
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

hamsh_send 'cd /nope/nope/nope'
hamsh_send_await 'echo PAPERCUT_SURVIVED' 'PAPERCUT_SURVIVED' "$CMD_WAIT" || true
hamsh_send 'exit'
sleep 2

# The survival sentinel is the observation everything hangs off; absent ->
# starved guest, not a bug.
if ! hamsh_ran "$LOG" "PAPERCUT_SURVIVED"; then
    verdict_inconclusive "$TAG" \
        "the post-error survival sentinel never printed within ${CMD_WAIT}s" \
        "— the guest was starved before the fixture ran. Re-run quiet."
fi

fail=0
# The `cd:` error text is printed by the shell on its own output line and
# is not present verbatim in the typed `cd /nope/...` input.
if grep -a -E -q "cd: .*chdir" "$LOG"; then
    echo "[$TAG] OK: failing cd surfaces the kernel errstr"
else
    echo "[$TAG] WRONG: cd error message not propagated"
    fail=1
fi
echo "[$TAG] OK: shell survived the failed builtin (PAPERCUT_SURVIVED)"

if [ "$fail" -ne 0 ]; then
    echo "[$TAG] --- captured (stripped) ---" >&2
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | tr -d '\000' | tail -30 >&2
    verdict_fail "$TAG" "a failing builtin did not surface the kernel errstr"
fi
verdict_pass "$TAG" "failing cd surfaces the kernel errstr; shell survives the failed builtin"
