#!/usr/bin/env bash
# scripts/test_coreutils5.sh - verify the native join / expand / unexpand
# / shuf / factor tools added to Hamnix's init-namespace userland.
#
# Drives hamsh through one scenario per new tool against deterministic
# inputs seeded in /tmp, asserting the exact bytes a Linux user would
# expect (cross-checked against GNU coreutils on the host) — except for
# shuf, which is nondeterministic, where we assert STRUCTURAL properties:
# the output is a permutation of the input (same multiset), -n 2 yields
# exactly two lines, and -i 1-5 yields the five integers in some order.
#
#   join:     join a b  (sorted, key=field1) -> "1 a x", "2 b y", "3 c z"
#             join -1 2 -2 1 ...              -> key on file1 field 2
#             join -t "," csv1 csv2           -> comma-separated join
#   expand:   expand a<TAB>b (tabstop 8)      -> "a" + 7 spaces + "b"
#             expand -t 4 a<TAB>b             -> "a" + 3 spaces + "b"
#   unexpand: unexpand "    x" (4 spaces, ts8)-> still 4 spaces (no boundary)
#             unexpand -t4 "    x"            -> one TAB + "x"
#             unexpand -a "a        b"        -> "a" + TAB + "b" (col 1->8)
#   shuf:     permutation multiset == input; -n 2 -> 2 lines; -i 1-5 -> {1..5}
#   factor:   factor 12 -> "12: 2 2 3"; 7 -> "7: 7"; 1 -> "1:"; stdin too
#
# To keep the cleaner (which collapses runs of spaces) from destroying
# space-count assertions for expand/unexpand, we render spaces as '.' and
# tabs as '>' via `tr` before catting.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_coreutils5] (1/4) Build userland"
bash scripts/build_user.sh

echo "[test_coreutils5] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_coreutils5] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_coreutils5] (4/4) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# hamsh lexes a bare comma as a special token, so any comma separator arg
# is QUOTED (e.g. join -t ","). Tabs in seeded inputs come from printf \t.
# hamsh redraws the WHOLE line on each keystroke over the serial link, so
# per-command cost grows with BOTH line length and line count. We tune to
# the same envelope as test_coreutils3 (~10 lines, ~120 chars each):
# short, deterministic inputs and a couple of tools per scenario line.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 480 \
    -- \
       'printf "1 a\n2 b\n3 c\n" > /tmp/j1; printf "1 x\n2 y\n3 z\n" > /tmp/j2; printf "a 1\nb 2\nc 3\n" > /tmp/jf1; echo SEEDA' 3 \
       'printf "1,a\n2,b\n" > /tmp/c1; printf "1,x\n2,y\n" > /tmp/c2; printf "a\tb\n" > /tmp/tb; printf "    x\n" > /tmp/s4; echo SEEDB' 3 \
       'printf "a       b\n" > /tmp/md; printf "L1\nL2\nL3\nL4\n" > /tmp/sh; echo SEEDC' 3 \
       'echo JOIN_BEGIN; join /tmp/j1 /tmp/j2; echo JOIN_END; echo JOINF_BEGIN; join -1 2 -2 1 /tmp/jf1 /tmp/j1; echo JOINF_END' 4 \
       'echo JOINC_BEGIN; join -t "," /tmp/c1 /tmp/c2; echo JOINC_END' 3 \
       'echo EXP8_BEGIN; expand /tmp/tb | tr " \t" ".>"; echo EXP8_END; echo EXP4_BEGIN; expand -t 4 /tmp/tb | tr " \t" ".>"; echo EXP4_END' 4 \
       'echo UNE8_BEGIN; unexpand /tmp/s4 | tr " \t" ".>"; echo UNE8_END; echo UNE4_BEGIN; unexpand -t 4 /tmp/s4 | tr " \t" ".>"; echo UNE4_END' 4 \
       'echo UNEA_BEGIN; unexpand -a /tmp/md | tr " \t" ".>"; echo UNEA_END' 3 \
       'echo SHUF_BEGIN; shuf /tmp/sh | sort; echo SHUF_END; echo SHN_BEGIN; shuf -n 2 /tmp/sh | wc; echo SHN_END' 4 \
       'echo SHI_BEGIN; shuf -i "1-5" | sort; echo SHI_END; echo SHE_BEGIN; shuf -e alpha beta gamma | sort; echo SHE_END' 4 \
       'echo FAC_BEGIN; factor 12; factor 7; factor 1; factor 0; factor 97; echo FAC_END' 3 \
       'echo FACS_BEGIN; printf "12 13 20\n" | factor; echo FACS_END' 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_coreutils5] --- captured output ---"
cat "$LOG"
echo "[test_coreutils5] --- end output ---"

fail=0
# Clean the serial log the same way test_coreutils3 does: drop kernel
# timestamp lines, runtime banners, task-exit notices, hamsh heartbeat
# and per-keystroke echo, strip ANSI/control bytes, then collapse
# newlines+tabs to single spaces and squeeze runs. (Real space runs in
# expand/unexpand output were rendered to '.' on the guest first, so they
# survive the squeeze.)
cleaned=$(
    sed -E \
        -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        -e 's/\[runtime:[a-zA-Z0-9_]*\] _start//g' \
        -e 's/task: pid -*[0-9]* exited \(code=-*[0-9]*\)//g' \
        -e 's/\[hamsh-alive\][^[:cntrl:]]*//g' \
        "$LOG" \
    | grep -av -E '^\[[0-9]{6}\]|hamsh\$' \
    | tr -c 'A-Za-z0-9_,.>/ \n\t-' ' ' \
    | tr '\n\t' '  ' \
    | tr -s ' '
)
# Drop the lone "f" glyph the runtime banner leaves before a tool's first
# byte (same fixup as test_coreutils3).
cleaned=$(echo "$cleaned" | sed -E 's/ f( f)* / /g' | tr -s ' ')

check() {
    local needle="$1" label="$2"
    if echo "$cleaned" | grep -F -q "$needle"; then
        echo "[test_coreutils5] OK: $label"
    else
        echo "[test_coreutils5] MISS: $label — '$needle' not seen"
        fail=1
    fi
}

# ---- join --------------------------------------------------------------
# Default: key field1; output = key + rest-of-1 + rest-of-2.
if echo "$cleaned" | grep -Fq "JOIN_BEGIN 1 a x 2 b y 3 c z JOIN_END"; then
    echo "[join] default field-1 join OK"
else
    echo "[join] default field-1 join MISS"; fail=1
fi
# -1 2 -2 1: key = file1 field 2 (the digit) joined to file2 field 1.
# file1 "a 1"/"b 2"/"c 3" (rest = a/b/c), file2 "1 a"/"2 b"/"3 c"
# (rest = a/b/c) -> "1 a a", "2 b b", "3 c c".
if echo "$cleaned" | grep -Fq "JOINF_BEGIN 1 a a 2 b b 3 c c JOINF_END"; then
    echo "[join] -1 2 -2 1 custom fields OK"
else
    echo "[join] -1 2 -2 1 custom fields MISS"; fail=1
fi
# -t , : comma separator, output uses comma too.
if echo "$cleaned" | grep -Fq "JOINC_BEGIN 1,a,x 2,b,y JOINC_END"; then
    echo "[join] -t comma separator OK"
else
    echo "[join] -t comma separator MISS"; fail=1
fi

# ---- expand ------------------------------------------------------------
# "a<TAB>b" with tabstop 8: 'a' at col0, tab -> 7 spaces to col8, 'b'.
check "EXP8_BEGIN a.......b EXP8_END" "expand tabstop 8 (7 spaces)"
# tabstop 4: 'a' col0, tab -> 3 spaces to col4, 'b'.
check "EXP4_BEGIN a...b EXP4_END"     "expand -t 4 (3 spaces)"

# ---- unexpand ----------------------------------------------------------
# 4 leading spaces, tabstop 8: no tab boundary reached -> unchanged.
check "UNE8_BEGIN ....x UNE8_END"     "unexpand 4-space leading (ts8, unchanged)"
# tabstop 4: 4 spaces == one tab boundary -> single TAB.
check "UNE4_BEGIN >x UNE4_END"        "unexpand -t 4 (4 spaces -> TAB)"
# -a: 'a' at col0, then 7 spaces span cols 1..7 reaching the col-8 tab
# boundary exactly -> 'a' + one TAB + 'b' (no trailing spaces).
check "UNEA_BEGIN a>b UNEA_END"       "unexpand -a interior run -> TAB"

# ---- shuf (nondeterministic: assert structure, not order) --------------
# Permutation: piping through sort recovers the sorted multiset.
check "SHUF_BEGIN L1 L2 L3 L4 SHUF_END" "shuf permutation == input multiset"
# -n 2: wc reports 2 lines (format "2 2 6": 2 lines, 2 words, 6 bytes —
# we only assert the leading line count of 2).
if echo "$cleaned" | grep -Eq "SHN_BEGIN 2 [0-9]+ [0-9]+ SHN_END"; then
    echo "[test_coreutils5] OK: shuf -n 2 yields exactly 2 lines"
else
    echo "[test_coreutils5] MISS: shuf -n 2 line count"; fail=1
fi
# -i 1-5: the five integers in some order (sorted -> 1 2 3 4 5).
check "SHI_BEGIN 1 2 3 4 5 SHI_END"   "shuf -i 1-5 == {1,2,3,4,5}"
# -e ARGS: the three args as lines (sorted).
check "SHE_BEGIN alpha beta gamma SHE_END" "shuf -e args as lines"

# ---- factor ------------------------------------------------------------
# 12=2*2*3, 7 prime, 1 empty, 0 empty, 97 prime.
check "FAC_BEGIN 12 2 2 3 7 7 1 0 97 97 FAC_END" "factor argv (12/7/1/0/97)"
# stdin tokens: 12=2 2 3, 13 prime, 20=2 2 5.
check "FACS_BEGIN 12 2 2 3 13 13 20 2 2 5 FACS_END" "factor stdin tokens"

if [ "$fail" -ne 0 ]; then
    echo "[test_coreutils5] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_coreutils5] PASS"
