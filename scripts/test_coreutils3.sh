#!/usr/bin/env bash
# scripts/test_coreutils3.sh - verify the native paste / comm / split /
# realpath / truncate tools added to Hamnix's init-namespace userland.
#
# Drives hamsh through one scenario per new tool against deterministic
# inputs seeded in /tmp, and asserts the exact output a Linux user would
# expect (cross-checked against GNU coreutils on the host):
#
#   paste:    paste a.txt b.txt        -> "a<TAB>1", "b<TAB>2", "c<TAB>3"
#             paste -d, a.txt b.txt    -> "a,1" "b,2" "c,3"
#             paste -s a.txt           -> "a<TAB>b<TAB>c" on one line
#   comm:     comm c1 c2 (sorted)      -> col1 "apple", col3 "banana"/"cherry",
#                                         col2 "date" (TAB-indented)
#             comm -12 c1 c2           -> only common: "banana" "cherry"
#   split:    split -l 2 big sp_       -> sp_aa/sp_ab/sp_ac with 2/2/1 lines
#             split -b 4 b bb_         -> bb_aa="0123" bb_ab="4567" bb_ac="89"
#   realpath: realpath /a/b/../c/./d   -> "/a/c/d" (lexical canonical)
#             cd /tmp; realpath x/../y -> "/tmp/y"
#   truncate: truncate -s 5 (grow "XY")  -> 5 bytes, tail zero-filled
#             truncate -s 3 (shrink 8)    -> "ABC", 3 bytes

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_coreutils3] (1/4) Build userland"
bash scripts/build_user.sh

echo "[test_coreutils3] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_coreutils3] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_coreutils3] (4/4) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Each scenario is a single compound command line (hamsh `;` separates
# statements) so the driver feeds far fewer lines — boot is slow and
# every keystroke echoes, so minimising the number of driven commands
# keeps the run inside the timeout.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 180 \
    -- \
       'printf "a\nb\nc\n" > /tmp/pa.txt; printf "1\n2\n3\n" > /tmp/pb.txt; echo PASTE_COL_BEGIN; paste /tmp/pa.txt /tmp/pb.txt; echo PASTE_COL_END' 3 \
       'echo PASTE_D_BEGIN; paste -d "," /tmp/pa.txt /tmp/pb.txt; echo PASTE_D_END; echo PASTE_S_BEGIN; paste -s /tmp/pa.txt; echo PASTE_S_END' 3 \
       'printf "apple\nbanana\ncherry\n" > /tmp/c1.txt; printf "banana\ncherry\ndate\n" > /tmp/c2.txt; echo COMM_BEGIN; comm /tmp/c1.txt /tmp/c2.txt; echo COMM_END' 3 \
       'echo COMM12_BEGIN; comm -12 /tmp/c1.txt /tmp/c2.txt; echo COMM12_END' 2 \
       'printf "L1\nL2\nL3\nL4\nL5\n" > /tmp/big.txt; split -l 2 /tmp/big.txt /tmp/sp_; echo SPAA_BEGIN; cat /tmp/sp_aa; echo SPAA_END; echo SPAB_BEGIN; cat /tmp/sp_ab; echo SPAB_END; echo SPAC_BEGIN; cat /tmp/sp_ac; echo SPAC_END' 3 \
       'printf "0123456789" > /tmp/b.txt; split -b 4 /tmp/b.txt /tmp/bb_; echo BBAA_BEGIN; cat /tmp/bb_aa; echo; echo BBAA_END; echo BBAB_BEGIN; cat /tmp/bb_ab; echo; echo BBAB_END; echo BBAC_BEGIN; cat /tmp/bb_ac; echo; echo BBAC_END' 3 \
       'echo RP_ABS_BEGIN; realpath /a/b/../c/./d; echo RP_ABS_END; cd /tmp; echo RP_REL_BEGIN; realpath x/../y; echo RP_REL_END; cd /' 3 \
       'printf "XY" > /tmp/t.txt; truncate -s 5 /tmp/t.txt; echo TGROW_BEGIN; cat /tmp/t.txt | wc; echo TGROW_END' 3 \
       'printf "ABCDEFGH" > /tmp/t2.txt; truncate -s 3 /tmp/t2.txt; echo TSHRINK_BEGIN; cat /tmp/t2.txt; echo; cat /tmp/t2.txt | wc; echo TSHRINK_END' 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_coreutils3] --- captured output ---"
cat "$LOG"
echo "[test_coreutils3] --- end output ---"

fail=0
# The serial log interleaves real tool output with kernel/runtime noise:
#   - "[NNNNNN] ..." timestamped kernel lines (aslr, task-exit, etc.)
#   - "[runtime:NAME] _start" per-exec banners (may PREFIX the first
#     bytes of a tool's own output on the same line)
#   - "[hamsh-alive] ..." heartbeat ticks
#   - hamsh's per-keystroke echo (lots of "^[[K"/"hamsh$" fragments)
#   - stray non-printable runtime glyphs
# We delete those whole lines / fragments, strip ANSI + control bytes,
# then collapse newlines AND tabs to single spaces so a marker window
# like "SPAA_BEGIN L1 L2 SPAA_END" is contiguous regardless of how the
# real output was line-broken (paste/comm also emit TABs).
cleaned=$(
    sed -E \
        -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        -e 's/\[runtime:[a-zA-Z0-9_]*\] _start//g' \
        -e 's/task: pid -*[0-9]* exited \(code=-*[0-9]*\)//g' \
        -e 's/\[hamsh-alive\][^[:cntrl:]]*//g' \
        "$LOG" \
    | grep -av -E '^\[[0-9]{6}\]|hamsh\$' \
    | tr -c 'A-Za-z0-9_,./ \n\t-' ' ' \
    | tr '\n\t' '  ' \
    | tr -s ' '
)
# The per-exec runtime banner leaves a lone "f" glyph right before a
# freshly exec'd tool's first output byte (the rest of the banner is
# control bytes already squeezed out above). Drop isolated single "f"
# tokens so a marker window like "BBAA_BEGIN 0123 BBAA_END" is
# contiguous. (No expected tool output is a bare "f".)
cleaned=$(echo "$cleaned" | sed -E 's/ f( f)* / /g' | tr -s ' ')

# between BEGIN END  -> echoes only the text between the FIRST BEGIN and
# the following END marker in $cleaned (markers excluded).
between() {
    echo "$cleaned" | grep -oE "$1 .* $2" | head -1
}

check() {
    local needle="$1" label="$2"
    if echo "$cleaned" | grep -F -q "$needle"; then
        echo "[test_coreutils3] OK: $label"
    else
        echo "[test_coreutils3] MISS: $label — '$needle' not seen"
        fail=1
    fi
}

# ---- paste -------------------------------------------------------------
# Column mode: TAB between fields (collapsed to a single space here).
if echo "$cleaned" | grep -Fq "PASTE_COL_BEGIN a 1 b 2 c 3 PASTE_COL_END"; then
    echo "[paste] column-merge a.txt b.txt -> a<TAB>1/b<TAB>2/c<TAB>3 OK"
else
    echo "[paste] column-merge MISS"; fail=1
fi
# -d, custom delimiter (no TAB, survives collapsing intact).
if echo "$cleaned" | grep -Fq "PASTE_D_BEGIN a,1 b,2 c,3 PASTE_D_END"; then
    echo "[paste] -d, custom delimiter OK"
else
    echo "[paste] -d, custom delimiter MISS"; fail=1
fi
# -s serial: all three lines joined on ONE row (a<TAB>b<TAB>c).
if echo "$cleaned" | grep -Fq "PASTE_S_BEGIN a b c PASTE_S_END"; then
    echo "[paste] -s serial join OK"
else
    echo "[paste] -s serial join MISS"; fail=1
fi

# ---- comm --------------------------------------------------------------
# Default 3-col: apple only-in-1, banana/cherry common (2 tabs), date
# only-in-2 (1 tab). TABs collapse to spaces so the BEGIN..END window is:
#   COMM_BEGIN apple banana cherry date COMM_END
if echo "$cleaned" | grep -Fq "COMM_BEGIN apple banana cherry date COMM_END"; then
    echo "[comm] 3-column compare OK"
else
    echo "[comm] 3-column compare MISS"; fail=1
fi
# -12: suppress col1+col2, only common lines remain.
if echo "$cleaned" | grep -Fq "COMM12_BEGIN banana cherry COMM12_END"; then
    echo "[comm] -12 common-only OK"
else
    echo "[comm] -12 common-only MISS"; fail=1
fi

# ---- split -------------------------------------------------------------
check "SPAA_BEGIN L1 L2 SPAA_END"  "split -l 2 piece aa = L1/L2"
check "SPAB_BEGIN L3 L4 SPAB_END"  "split -l 2 piece ab = L3/L4"
check "SPAC_BEGIN L5 SPAC_END"     "split -l 2 piece ac = L5"
check "BBAA_BEGIN 0123 BBAA_END"   "split -b 4 piece aa = 0123"
check "BBAB_BEGIN 4567 BBAB_END"   "split -b 4 piece ab = 4567"
check "BBAC_BEGIN 89 BBAC_END"     "split -b 4 piece ac = 89"
if [ "$fail" -eq 0 ]; then echo "[split] -l and -b piece split OK"; fi

# ---- realpath ----------------------------------------------------------
if echo "$cleaned" | grep -Fq "RP_ABS_BEGIN /a/c/d RP_ABS_END"; then
    echo "[realpath] absolute canonical /a/b/../c/./d -> /a/c/d OK"
else
    echo "[realpath] absolute canonical MISS"; fail=1
fi
if echo "$cleaned" | grep -Fq "RP_REL_BEGIN /tmp/y RP_REL_END"; then
    echo "[realpath] relative-to-cwd x/../y -> /tmp/y OK"
else
    echo "[realpath] relative-to-cwd MISS"; fail=1
fi

# ---- truncate ----------------------------------------------------------
# Grow "XY" (2 bytes) to 5 -> `cat | wc` reports "0 1 5" (5 bytes,
# trailing 3 are NUL = non-whitespace, so one word, no newline).
if echo "$cleaned" | grep -Eq "TGROW_BEGIN 0 1 5 TGROW_END"; then
    echo "[truncate] grow XY to 5 bytes (zero-filled tail) OK"
else
    echo "[truncate] grow MISS"; fail=1
fi
# Shrink "ABCDEFGH" to 3 -> content "ABC", `cat | wc` reports "0 1 3".
if echo "$cleaned" | grep -Eq "TSHRINK_BEGIN ABC 0 1 3 TSHRINK_END"; then
    echo "[truncate] shrink ABCDEFGH to 3 bytes (ABC) OK"
else
    echo "[truncate] shrink MISS"; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_coreutils3] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_coreutils3] PASS"
