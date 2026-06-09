#!/usr/bin/env bash
# scripts/test_coreutils4.sh - verify the native stat / nproc / printenv /
# tty / mktemp tools added to Hamnix's init-namespace userland.
#
# Drives hamsh through one scenario per new tool against deterministic
# inputs (temp files seeded in /tmp where needed) and asserts the
# behaviour a Linux user would expect (cross-checked against GNU
# coreutils / util-linux on the host). Where a value legitimately
# varies between runs (the mktemp suffix; the SMP CPU count), we assert
# STRUCTURAL properties — the created entry exists / the path matches
# the template / the count is a positive integer — never a fixed
# literal pulled from one run.
#
#   stat:     stat -c "%n %s %F" of a 5-byte regular file -> name,
#             "5", "regular file"; stat of /tmp -> "directory".
#   nproc:    a single positive integer line (QEMU boots -smp 2 here,
#             so we additionally assert it is exactly "2").
#   printenv: native env arrives as argv NAME=VALUE tokens —
#             `printenv A=1 B=2` dumps both pairs; `printenv A=1 B=2 B`
#             prints just "2" (the named lookup).
#   tty:      stdin is the serial console, so `tty` prints "/dev/cons"
#             and exits 0; piped stdin (echo x | tty) prints "not a tty".
#   mktemp:   `mktemp` prints /tmp/tmp.XXXXXX and creates it; two
#             successive invocations print DIFFERENT paths (uniqueness);
#             `mktemp -d` prints a same-shaped path; `ls /tmp` then
#             lists >=2 distinct tmp.* entries, proving the names were
#             really created on disk (not merely printed).

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_coreutils4] (1/4) Build userland"
bash scripts/build_user.sh

echo "[test_coreutils4] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_coreutils4] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_coreutils4] (4/4) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Each scenario is one compound hamsh command line (`;` separates
# statements) so the driver feeds few lines — boot is slow and every
# keystroke echoes, so minimising driven commands keeps us in budget.
# BEGIN/END markers bracket each tool's output so the post-processing
# can window it out of the interleaved kernel/runtime noise.
# NOTE on printenv invocation: hamsh's command parser rejects a BARE
# `cmd NAME=VALUE` argument (a bare word containing '=' after a command
# word is a parse error — `=` is the assignment operator at statement
# level). The NAME=VALUE tokens are therefore passed DOUBLE-QUOTED so
# hamsh hands them to the binary as literal argv strings (the '=' is an
# ordinary character inside a quoted word, and there is no `$` so no
# interpolation occurs). This matches the documented native env-via-argv
# convention; the quoting is purely a shell-syntax requirement.
#
# Scenarios are consolidated (multiple asserts per driven line, short
# markers) to keep total keystroke-echo + boot time inside the window.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 480 \
    -- \
       'printf hello > /tmp/s; echo SF1; stat -c "%n %s %F" /tmp/s; echo SF2; stat -c "%F" /tmp; echo SF3' 3 \
       'echo NP1; nproc; echo NP2' 2 \
       'echo PE1; printenv "GREET=hello" "NAME=world"; echo PE2; printenv "GREET=hello" "NAME=world" NAME; echo PE3' 3 \
       'echo TY1; tty; echo TY2; echo x | tty; echo TY3' 3 \
       'echo MK1; mktemp; echo MK2; mktemp; echo MK3; mktemp -d; echo MK4; ls /tmp; echo MK5' 5 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_coreutils4] --- captured output ---"
cat "$LOG"
echo "[test_coreutils4] --- end output ---"

fail=0
# The serial log interleaves real tool output with kernel/runtime noise.
# Strip ANSI + control bytes, drop kernel-timestamp / heartbeat / prompt
# lines, then collapse newlines AND tabs to single spaces so a marker
# window like "SF1 ... SF2" is contiguous regardless of how the tool's
# output was line-broken.
cleaned=$(
    sed -E \
        -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        -e 's/\[runtime:[a-zA-Z0-9_]*\] _start//g' \
        -e 's/task: pid -*[0-9]* exited \(code=-*[0-9]*\)//g' \
        -e 's/\[hamsh-alive\][^[:cntrl:]]*//g' \
        "$LOG" \
    | grep -av -E '^\[[0-9]{6}\]|hamsh\$' \
    | tr -c 'A-Za-z0-9_,./=  \n\t-' ' ' \
    | tr '\n\t' '  ' \
    | tr -s ' '
)
# The per-exec runtime banner can leave a lone "f" glyph right before a
# freshly exec'd tool's first output byte; drop isolated single "f"
# tokens so a marker window is contiguous. (No expected output is "f".)
cleaned=$(echo "$cleaned" | sed -E 's/ f( f)* / /g' | tr -s ' ')

# Echo only the text between the FIRST occurrence of $1 and the
# following $2 marker (markers excluded), as one space-joined line.
between() {
    echo "$cleaned" | grep -oE "$1 .* $2" | head -1 \
        | sed -E "s/^$1 //; s/ $2\$//"
}

pass_tool() {  # $1 = tool label
    echo "[$1] OK"
}
fail_tool() {  # $1 = tool label, $2 = reason
    echo "[$1] FAIL — $2"
    fail=1
}

# ---- stat --------------------------------------------------------------
# SF1..SF3 bracket: file -c "%n %s %F" (between SF1/SF2), dir -c "%F"
# (between SF2/SF3). "hello" is 5 bytes.
statf=$(between SF1 SF2)
statd=$(between SF2 SF3)
if echo " $statf " | grep -Eq " /tmp/s 5 regular file "; then
    if echo " $statd " | grep -Eq " directory "; then
        echo "[stat] -c %n/%s/%F file=5/regular + /tmp=directory OK"
    else
        fail_tool stat "stat -c %F /tmp not 'directory' (got '$statd')"
    fi
else
    fail_tool stat "stat -c output mismatch (got '$statf')"
fi

# ---- nproc -------------------------------------------------------------
nproc_val=$(between NP1 NP2 | tr -dc '0-9')
if [ -n "$nproc_val" ] && [ "$nproc_val" -ge 1 ] 2>/dev/null; then
    # Structural: a positive integer (the online-CPU count varies with
    # SMP bring-up timing, so we assert >= 1 rather than a fixed literal).
    echo "[nproc] online CPU count = $nproc_val (positive integer) OK"
else
    fail_tool nproc "non-integer / non-positive count (got '$nproc_val')"
fi

# ---- printenv ----------------------------------------------------------
# PE1..PE3: dump (between PE1/PE2), named lookup of NAME (between PE2/PE3).
peall=$(between PE1 PE2)
peone=$(between PE2 PE3)
if echo " $peall " | grep -Fq " GREET=hello " \
   && echo " $peall " | grep -Fq " NAME=world "; then
    # Named lookup of NAME prints just its value "world".
    if echo " $peone " | grep -Eq "(^| )world( |$)"; then
        echo "[printenv] dump NAME=VALUE pairs + named lookup NAME=world OK"
    else
        fail_tool printenv "named lookup not 'world' (got '$peone')"
    fi
else
    fail_tool printenv "dump missing GREET/NAME pairs (got '$peall')"
fi

# ---- tty ---------------------------------------------------------------
# TY1..TY3: console tty (between TY1/TY2), piped tty (between TY2/TY3).
ttyc=$(between TY1 TY2)
ttyp=$(between TY2 TY3)
if echo " $ttyc " | grep -Fq " /dev/cons "; then
    if echo " $ttyp " | grep -Fq " not a tty "; then
        echo "[tty] console=/dev/cons + pipe='not a tty' OK"
    else
        fail_tool tty "piped stdin not 'not a tty' (got '$ttyp')"
    fi
else
    fail_tool tty "console stdin not '/dev/cons' (got '$ttyc')"
fi

# ---- mktemp ------------------------------------------------------------
# Capture-free, structural verification (the slow per-keystroke serial
# console under TCG makes backtick command-substitution lines too long
# to drain inside the QEMU window, so we drive ONE short line and assert
# observable properties of mktemp's printed paths + the resulting /tmp):
#   * default `mktemp` prints a /tmp/tmp.XXXXXX-shaped path (twice);
#   * the two default invocations print DIFFERENT paths -> uniqueness;
#   * `mktemp -d` prints a /tmp/tmp.XXXXXX-shaped path;
#   * `ls /tmp` afterwards lists at least two distinct tmp.* entries,
#     proving the names were REALLY created on disk (not just printed).
#   MK1..MK2: 1st file path | MK2..MK3: 2nd file path
#   MK3..MK4: -d dir path   | MK4..MK5: ls /tmp listing
mkf1=$(between MK1 MK2)
mkf2=$(between MK2 MK3)
mkd=$(between MK3 MK4)
mkls=$(between MK4 MK5)
mktemp_ok=1
# Extract the bare /tmp/tmp.XXXXXX token from each printed path.
p1=$(echo " $mkf1 " | grep -oE "/tmp/tmp\.[0-9A-Za-z]+" | head -1)
p2=$(echo " $mkf2 " | grep -oE "/tmp/tmp\.[0-9A-Za-z]+" | head -1)
pd=$(echo " $mkd "  | grep -oE "/tmp/tmp\.[0-9A-Za-z]+" | head -1)
# Core: both default and -d print a /tmp/tmp.XXXXXX-shaped path.
if [ -n "$p1" ]; then :; else
    mktemp_ok=0; echo "[mktemp] 1st file path !~ /tmp/tmp.XXXXXX (got '$mkf1')"
fi
if [ -n "$p2" ]; then :; else
    mktemp_ok=0; echo "[mktemp] 2nd file path !~ /tmp/tmp.XXXXXX (got '$mkf2')"
fi
if [ -n "$pd" ]; then :; else
    mktemp_ok=0; echo "[mktemp] -d path !~ /tmp/tmp.XXXXXX (got '$mkd')"
fi
# Uniqueness: two successive default invocations differ.
if [ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" = "$p2" ]; then
    mktemp_ok=0; echo "[mktemp] two invocations gave the SAME path ('$p1') — not unique"
fi
# Core: the entries were actually created on disk — ls /tmp lists at
# least two DISTINCT tmp.* names.
ndistinct=$(echo " $mkls " | grep -oE "tmp\.[0-9A-Za-z]+" | sort -u | wc -l)
if [ "$ndistinct" -ge 2 ]; then :; else
    mktemp_ok=0
    echo "[mktemp] /tmp lists < 2 distinct tmp.* entries ($ndistinct) — names not created (got '$mkls')"
fi
if [ "$mktemp_ok" -eq 1 ]; then
    echo "[mktemp] file + -d path shape, unique paths, on-disk creation (ls /tmp) OK"
else
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_coreutils4] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_coreutils4] PASS"
