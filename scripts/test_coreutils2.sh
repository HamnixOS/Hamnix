#!/usr/bin/env bash
# scripts/test_coreutils2.sh - verify the native uniq / nl / tac /
# fold / cksum tools added to Hamnix's init-namespace userland.
#
# Drives hamsh through one pipeline per new tool against deterministic
# input and asserts the exact output a Linux user would expect:
#
#   printf "a\na\nb\nb\nb\n" | uniq -c   -> "2 a" and "3 b"
#   seq 3 | tac                          -> "3" "2" "1" (reversed order)
#   seq 2 | nl                           -> "1\t1" and "2\t2"
#   printf "abcdef\n" | fold -w 3        -> "abc" then "def"
#   printf "hello\n" | cksum             -> "3015617425 6" (POSIX CRC)
#
# The cksum value is cross-checked against GNU coreutils:
#   $ printf 'hello\n' | cksum  ->  3015617425 6

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_coreutils2] (1/4) Build userland"
bash scripts/build_user.sh

echo "[test_coreutils2] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_coreutils2] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_coreutils2] (4/4) Boot QEMU"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 35 \
    -- 'printf "a\na\nb\nb\nb\n" | uniq -c' 2 \
       "seq 3 | tac" 2 \
       "seq 2 | nl" 2 \
       'printf "abcdef\n" | fold -w 3' 2 \
       'printf "hello\n" | cksum' 2 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_coreutils2] --- captured output ---"
cat "$LOG"
echo "[test_coreutils2] --- end output ---"

fail=0
# Strip kernel exit-log lines + collapse whitespace so multi-token
# assertions don't depend on exact serial line breaks.
# Convert newlines AND tabs to spaces (nl emits a TAB between the
# number field and the line content) before collapsing runs of space.
cleaned=$(sed 's/task: pid -*[0-9]* exited (code=-*[0-9]*)//g' "$LOG" | tr '\n\t' '  ' | tr -s ' ')

check() {
    local needle="$1" label="$2"
    if echo "$cleaned" | grep -F -q "$needle"; then
        echo "[test_coreutils2] OK: $label ('$needle')"
    else
        echo "[test_coreutils2] MISS: $label — '$needle' not seen"
        fail=1
    fi
}

# uniq -c: run of 2 'a' then run of 3 'b'.
check "2 a" "uniq -c counted the 'a' run"
check "3 b" "uniq -c counted the 'b' run"

# tac: reversed order. The cleaned (whitespace-collapsed) stream should
# show 3 before 2 before 1 — assert the contiguous reversed triple.
if echo "$cleaned" | grep -Eq "3 2 1"; then
    echo "[test_coreutils2] OK: tac reversed seq 3 -> 3 2 1"
else
    echo "[test_coreutils2] MISS: tac did not reverse (no '3 2 1')"
    fail=1
fi

# nl: number-TAB-content. Serial TABs survive; match on the visible
# "1<tab>1" / "2<tab>2" pairs (collapsed whitespace makes the field
# padding + TAB show up as a single space).
check "1 1" "nl numbered first line"
check "2 2" "nl numbered second line"

# fold -w 3: "abcdef" wraps to "abc" then "def".
check "abc def" "fold -w 3 wrapped abcdef"

# cksum: POSIX CRC32 + byte count, matches GNU coreutils for "hello\n".
check "3015617425 6" "cksum produced the POSIX CRC for hello"

if [ "$fail" -ne 0 ]; then
    echo "[test_coreutils2] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_coreutils2] PASS"
