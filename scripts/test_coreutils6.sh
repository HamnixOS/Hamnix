#!/usr/bin/env bash
# scripts/test_coreutils6.sh - verify the native csplit / numfmt / pr /
# tsort / dircolors tools added to Hamnix's init-namespace userland.
#
# Drives hamsh through one scenario per new tool against deterministic
# inputs seeded in /tmp, asserting the exact bytes a Linux user would
# expect (cross-checked against GNU coreutils on the host).
#
#   csplit:    csplit /tmp/cs /B/  -> xx00 = "A", xx01 = "B\nC"
#   numfmt:    --to=iec 1024 -> "1.0K"; --to=si 1000 -> "1.0K";
#              --from=iec 1K -> "1024"; --to=iec-i 1048576 -> "1.0Mi";
#              --suffix=B --to=si 2000 -> "2.0KB"
#   pr:        pr -t /tmp/pr        -> body unchanged (no header/trailer)
#              pr -t -n /tmp/pr     -> each line prefixed with "N<TAB>"
#   tsort:     tsort /tmp/ts (edges 3->2, 2->1) -> "3 2 1"
#              tsort cycle (1->2, 2->1) -> loop reported on stderr
#   dircolors: dircolors            -> "LS_COLORS=..." with di=01;34
#
# Whitespace in tool output is rendered via `tr " \t" ".>"` before
# catting so the serial-log cleaner (which squeezes space runs) cannot
# destroy space/tab-count assertions.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_coreutils6] (1/4) Build userland"
bash scripts/build_user.sh

echo "[test_coreutils6] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_coreutils6] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_coreutils6] (4/4) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# qemu_drive WAITS for hamsh's prompt, then sends each command with a
# post-delay. The whole QEMU run is self-bounded by an internal timeout
# (no outer timeout wrapper). PASS is gated on log markers below.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 480 \
    -- \
       'echo WARMUP' 2 \
       'printf "A\nB\nC\n" > /tmp/cs; printf "l1\nl2\nl3\n" > /tmp/pr; echo SEEDA' 3 \
       'printf "3 2\n2 1\n" > /tmp/ts; printf "1 2\n2 1\n" > /tmp/tc; echo SEEDB' 3 \
       'echo CSP_BEGIN; csplit -f /tmp/xx /tmp/cs /B/; echo X0; cat /tmp/xx00; echo X1; cat /tmp/xx01; echo CSP_END' 4 \
       'echo NF1_BEGIN; numfmt "--to=iec" 1024; echo NF1_END; echo NF2_BEGIN; numfmt "--to=si" 1000; echo NF2_END' 4 \
       'echo NF3_BEGIN; numfmt "--from=iec" "1K"; echo NF3_END; echo NF4_BEGIN; numfmt "--to=iec-i" 1048576; echo NF4_END' 4 \
       'echo NF5_BEGIN; numfmt "--suffix=B" "--to=si" 2000; echo NF5_END' 3 \
       'echo PRT_BEGIN; pr -t /tmp/pr; echo PRT_END' 3 \
       'echo PRN_BEGIN; pr -t -n /tmp/pr | tr " \t" ".>"; echo PRN_END' 4 \
       'echo TS_BEGIN; tsort /tmp/ts; echo TS_END' 3 \
       'echo TC_BEGIN; tsort /tmp/tc 2>/tmp/tcerr; echo TC_MID; cat /tmp/tcerr; echo TC_END' 4 \
       'echo DC_BEGIN; dircolors; echo DC_END' 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_coreutils6] --- captured output ---"
cat "$LOG"
echo "[test_coreutils6] --- end output ---"

fail=0
# Clean the serial log: drop kernel timestamp lines, runtime banners,
# task-exit notices, hamsh heartbeat and per-keystroke echo, strip ANSI,
# then collapse newlines+tabs to single spaces and squeeze runs. (Space
# runs that must survive were rendered to '.' / '>' on the guest first.)
cleaned=$(
    sed -E \
        -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        -e 's/\[runtime:[a-zA-Z0-9_]*\] _start//g' \
        -e 's/task: pid -*[0-9]* exited \(code=-*[0-9]*\)//g' \
        -e 's/\[hamsh-alive\][^[:cntrl:]]*//g' \
        "$LOG" \
    | grep -av -E '^\[[0-9]{6}\]|hamsh\$' \
    | tr -c 'A-Za-z0-9_,.>/;:= \n\t-' ' ' \
    | tr '\n\t' '  ' \
    | tr -s ' '
)
# Drop the lone "f" glyph the runtime banner leaves before a tool's first
# byte (same fixup as test_coreutils5).
cleaned=$(echo "$cleaned" | sed -E 's/ f( f)* / /g' | tr -s ' ')

check() {
    local needle="$1" label="$2"
    if echo "$cleaned" | grep -F -q "$needle"; then
        echo "[test_coreutils6] OK: $label"
    else
        echo "[test_coreutils6] MISS: $label — '$needle' not seen"
        fail=1
    fi
}

# ---- csplit ------------------------------------------------------------
# /tmp/cs = "A\nB\nC". Splitting on /B/ -> xx00 = "A", xx01 = "B\nC".
check "CSP_BEGIN X0 A X1 B C CSP_END" "csplit /B/ -> xx00=A, xx01=B C"

# ---- numfmt ------------------------------------------------------------
# The [runtime:numfmt] banner can glue a stray byte before each tool's
# first output byte, so we assert the converted value appears between its
# own BEGIN and END markers, tolerating intervening banner junk via a
# regex wildcard.
nfcheck() {
    local b="$1" val="$2" e="$3" label="$4"
    if echo "$cleaned" | grep -Eq "${b}[^A-Za-z0-9]*${val} ${e}"; then
        echo "[test_coreutils6] OK: $label"
    else
        echo "[test_coreutils6] MISS: $label — ${b}..${val}..${e} not seen"
        fail=1
    fi
}
# Escape regex metachars in the values we match.
nfcheck "NF1_BEGIN" "1\.0K"  "NF1_END" "numfmt --to=iec 1024 -> 1.0K"
nfcheck "NF2_BEGIN" "1\.0K"  "NF2_END" "numfmt --to=si 1000 -> 1.0K"
nfcheck "NF3_BEGIN" "1024"   "NF3_END" "numfmt --from=iec 1K -> 1024"
nfcheck "NF4_BEGIN" "1\.0Mi" "NF4_END" "numfmt --to=iec-i 1048576 -> 1.0Mi"
nfcheck "NF5_BEGIN" "2\.0KB" "NF5_END" "numfmt --suffix=B --to=si 2000 -> 2.0KB"

# ---- pr ----------------------------------------------------------------
# -t: header/trailer omitted, body unchanged.
check "PRT_BEGIN l1 l2 l3 PRT_END" "pr -t plain body"
# -t -n: each line gets "N<TAB>" (TAB rendered '>', number 5-wide right-
# justified so 4 leading spaces -> '....1>l1').
check "PRN_BEGIN ....1>l1 ....2>l2 ....3>l3 PRN_END" "pr -t -n numbered lines"

# ---- tsort -------------------------------------------------------------
# edges 3->2, 2->1 force the order 3, 2, 1.
check "TS_BEGIN 3 2 1 TS_END" "tsort linear chain ordering"
# cycle 1->2->1: a loop must be reported on stderr (GNU: "input contains
# a loop:"). The TC_MID marker precedes the captured stderr text.
check "TC_MID tsort: input contains a loop" "tsort reports a cycle on stderr"

# ---- dircolors ---------------------------------------------------------
# Emits a Bourne LS_COLORS assignment including the dir mapping di=01;34.
# (The [runtime:dircolors] banner glues a stray byte before the output,
# so we assert the assignment + a mapping as standalone substrings rather
# than anchored to the DC_BEGIN marker.)
check "LS_COLORS=" "dircolors emits LS_COLORS assignment"
if echo "$cleaned" | grep -Fq "di=01;34"; then
    echo "[test_coreutils6] OK: dircolors default DIR color di=01;34"
else
    echo "[test_coreutils6] MISS: dircolors di=01;34 mapping"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_coreutils6] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_coreutils6] PASS"
