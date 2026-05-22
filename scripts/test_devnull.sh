#!/usr/bin/env bash
# scripts/test_devnull.sh — M16.68 verification.
#
# Exercises /dev/null as both a write SINK and a read EOF source via
# the shell:
#   /bin/echo SINK_MARK > /dev/null  — sink consumes everything; the
#                                      marker never reaches stdout
#   /bin/echo VISIBLE_MARK           — control: an un-redirected write
#                                      DOES reach stdout
#   cat /dev/null                    — immediate EOF, no output
#
# Asserts that:
#   1. An external command redirected to /dev/null produces no output
#   2. The same command WITHOUT the redirect does reach stdout (so the
#      absence in (1) is the redirect working, not the command failing)
#   3. cat /dev/null prints nothing and the shell survives it
#
# WHY /bin/echo, NOT the `echo` builtin: the shell's `echo` is an
# in-process builtin whose redirect handling is intentionally minimal
# (see user/hamsh.ad — `_builtin_dispatch`: builtins run at prompt
# scope; `> file` is wired only for SPAWNED children via
# _wire_redirects). `> /dev/null` on a builtin is therefore a no-op by
# design — testing it would test the builtin limitation, not /dev/null.
# `/bin/echo` is the external coreutils tool; its stdout IS rebound to
# /dev/null by _wire_redirects, exercising the real sink path.
#
# WHY hamsh_ran, NOT a plain grep: hamsh's interactive line editor
# echoes every keystroke, so the typed `/bin/echo SINK_MARK ...` line
# lands in the serial log too. hamsh_ran (scripts/_hamsh_log.sh) drops
# the prompt-prefixed input-echo lines and inspects genuine command
# output only — so the SINK_MARK assertion measures /dev/null, not the
# editor repainting the command as it was typed.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # Redirect an EXTERNAL command's stdout to /dev/null — the sink
    # should absorb it; SINK_MARK must not surface as command output.
    printf '/bin/echo SINK_MARK_XYZ > /dev/null\n'
    sleep 1
    # Control: the same command with NO redirect DOES reach stdout.
    # Proves the absence above is the /dev/null sink, not echo failing.
    printf '/bin/echo VISIBLE_MARK_XYZ\n'
    sleep 1
    # Reading /dev/null should produce nothing (immediate EOF).
    printf 'cat /dev/null\n'
    sleep 1
    # Sentinel: the shell survived the cat /dev/null read.
    printf '/bin/echo POST_CAT_XYZ\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0
# 1. SINK_MARK_XYZ must NOT appear in genuine command output — the
#    `> /dev/null` redirect rebound the external echo's /fd/1 to the
#    sink. (hamsh_ran ignores the prompt-echoed input line.)
if hamsh_ran "$LOG" "SINK_MARK_XYZ"; then
    echo "[test_devnull] MISS: SINK_MARK_XYZ leaked through /dev/null"
    fail=1
else
    echo "[test_devnull] OK: /dev/null absorbed redirected stdout"
fi
# 2. Control: the un-redirected echo DID reach stdout.
if hamsh_ran "$LOG" "VISIBLE_MARK_XYZ"; then
    echo "[test_devnull] OK: un-redirected echo reached stdout"
else
    echo "[test_devnull] MISS: control echo did not reach stdout"
    fail=1
fi
# 3. The shell survived cat /dev/null (immediate EOF, no output).
if hamsh_ran "$LOG" "POST_CAT_XYZ"; then
    echo "[test_devnull] OK: shell survived cat /dev/null"
else
    echo "[test_devnull] MISS: shell died on cat /dev/null"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devnull] --- captured output ---"
    cat "$LOG"
    echo "[test_devnull] --- end output ---"
    echo "[test_devnull] FAIL"
    exit 1
fi
echo "[test_devnull] PASS"
