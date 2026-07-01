#!/usr/bin/env bash
# scripts/test_hamsh_assign.sh — POSIX `VAR=value` assignment syntax.
#
# hamsh historically only understood a SPACED `=` as assignment, and it
# parsed the RHS as an arithmetic expression. That made the standard
# shell forms fail:
#
#   * `HOME=/home/live`  — the tokenizer split on `=` and then parsed
#     `/home/live` as division, yielding empty/garbage (or aborted the
#     whole rc script). A bad assignment in etc/rc.de-user aborted DE
#     startup and left the shell at the wrong uid.
#   * `export HOME=/home/live` — parse error (the `=` had no builtin
#     handling at statement scope), aborting the sourced rc script.
#
# The fix (user/hamsh.ad): a `=` GLUED to the LHS name (no surrounding
# space) lexes as OP_ASSIGN_LIT and its RHS is a LITERAL command word,
# not an expression — so `/`, `:`, `.` are literal, `'...'` is literal,
# `"..."` still interpolates `$vars`, and `$VAR` expands. A SPACED `=`
# (`n = 10 * 4`) keeps the arithmetic-expression semantics (covered by
# test_hamsh_values.sh). `export VAR=value` assigns AND exports.
#
# Strategy: boot hamsh as /init, drive its serial, echo back the values
# and assert them. NB: a freshly-booted hamsh drops the FIRST serial
# command line, so we send a warm-up marker line first.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_assign] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null

echo "[test_hamsh_assign] (2/3) Plant /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamsh_assign] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # Each case is SELF-CONTAINED on ONE serial line (assign ; echo),
    # so a per-line serial drop can't decouple a set from its read.
    # The first line a fresh hamsh sees is dropped, so lead with a
    # harmless warm-up marker (re-sent) before the real cases.
    printf 'echo WARMUP_MARKER\n'
    sleep 2
    printf 'echo WARMUP_MARKER\n'
    sleep 2
    # 1. bare POSIX assignment: literal PATH RHS (no arithmetic).
    printf 'DIR=/home/live ; echo GOT_DIR $DIR\n'
    sleep 2
    # 2. PATH-list value: glued ':' stays literal, no division.
    printf 'P=/bin:/sbin:/usr/bin ; echo GOT_P $P\n'
    sleep 2
    # 3. export VAR=value — assign AND export in one statement.
    printf 'export EV=exported_val ; echo GOT_EV $EV\n'
    sleep 2
    # 4. double-quoted RHS still interpolates $vars.
    printf 'DIR=/home/live ; Q="dir is $DIR" ; echo GOT_Q $Q\n'
    sleep 2
    # 5. single-quoted RHS is literal (no interpolation).
    printf "L='raw dollar' ; echo GOT_L \$L\n"
    sleep 2
    # 6. spaced `=` still does arithmetic (regression guard).
    printf 'n = 10 * 4 + 2 ; echo GOT_N $n\n'
    sleep 2
    # Re-send case 1 (a fresh hamsh drops its FIRST serial line, so the
    # opening bare `VAR=/path` case can be lost; re-send is idempotent).
    printf 'DIR=/home/live ; echo GOT_DIR $DIR\n'
    sleep 2
    printf 'echo ALL_DONE_MARKER\n'
    sleep 2
    printf 'exit\n'
    sleep 2
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
set -e

echo "[test_hamsh_assign] --- captured output ---"
cat "$LOG"
echo "[test_hamsh_assign] --- end output ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_hamsh_assign] OK: $2"
    else
        echo "[test_hamsh_assign] MISS ('$1'): $2"
        fail=1
    fi
}

check "GOT_DIR /home/live"          "VAR=/path is a literal string (no division)"
check "GOT_P /bin:/sbin:/usr/bin"   "PATH-list RHS with glued ':' is literal"
check "GOT_EV exported_val"         "export VAR=value assigns the value"
check "GOT_Q dir is /home/live"     "double-quoted RHS interpolates \$vars"
check "GOT_L raw dollar"            "single-quoted RHS is literal (no interp)"
check "GOT_N 42"                    "spaced '=' still evaluates arithmetic"

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_assign] FAIL"
    exit 1
fi
echo "[test_hamsh_assign] PASS"
