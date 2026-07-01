#!/usr/bin/env bash
# scripts/test_hamsh_expand.sh — QA-N20: UNQUOTED word text glued to a
# `$var` expansion (no whitespace) must fuse into ONE argv word.
#
# Before the fix, hitting `$` ended the current bareword and STARTED a
# new argv word, so `echo Kpre$s` (with s=world) printed `Kpre world`
# instead of `Kpreworld`. Double-quoted `"Kq$s"` already concatenated
# correctly. The fix (user/hamsh.ad) tracks token adjacency at lex time
# (tok_glued) and fuses a run of GLUED word-continuation tokens into a
# single ND_ARGCAT argv word — the `$`-adjacency analog of the QA-N7
# `=`-fusion. This covers glue on EITHER side and chained:
#   `pre$s`, `$s.txt`, `$s$s`, `p/$s/q`.
# SPACE-separated args stay separate (`echo a $s b` -> three words).
#
# Strategy: boot hamsh as /init, drive its serial, echo back the values
# and assert. NB: a freshly-booted hamsh drops the FIRST serial command
# line, so we send a warm-up marker line first.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_expand] (1/3) Build userland"
bash scripts/build_user.sh >/dev/null

echo "[test_hamsh_expand] (2/3) Plant /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamsh_expand] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # The first line a fresh hamsh sees is dropped, so lead with a
    # harmless warm-up marker (re-sent) before the real cases. Each case
    # is SELF-CONTAINED on ONE serial line (assign ; echo).
    printf 'echo WARMUP_MARKER\n'
    sleep 2
    printf 'echo WARMUP_MARKER\n'
    sleep 2
    # 1. text glued BEFORE a $var: Kpre$s -> Kpreworld.
    printf 's=world ; echo GOT_PRE Kpre$s\n'
    sleep 2
    # 2. $var glued to trailing text: K$s.txt -> Kworld.txt.
    printf 's=world ; echo GOT_MID K$s.txt\n'
    sleep 2
    # 3. two $vars glued: $s$s -> worldworld.
    printf 's=world ; echo GOT_DBL $s$s\n'
    sleep 2
    # 4. $var glued between path segments: p/$s/q -> p/world/q.
    printf 's=world ; echo GOT_PATH p/$s/q\n'
    sleep 2
    # 5. NON-REGRESSION: SPACE-separated args stay THREE words.
    printf 's=world ; echo GOT_SEP a $s b\n'
    sleep 2
    # 6. NON-REGRESSION: double-quoted "Kq$s" still concatenates.
    printf 's=world ; echo GOT_DQ "Kq$s"\n'
    sleep 2
    # 7. NON-REGRESSION: bare $s alone expands to the value.
    printf 's=world ; echo GOT_BARE $s\n'
    sleep 2
    # Re-send case 1 (a fresh hamsh drops its FIRST serial line).
    printf 's=world ; echo GOT_PRE Kpre$s\n'
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

echo "[test_hamsh_expand] --- captured output ---"
cat "$LOG"
echo "[test_hamsh_expand] --- end output ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_hamsh_expand] OK: $2"
    else
        echo "[test_hamsh_expand] MISS ('$1'): $2"
        fail=1
    fi
}

check "GOT_PRE Kpreworld"    "text glued before \$var concatenates (Kpre\$s)"
check "GOT_MID Kworld.txt"   "\$var glued to trailing text concatenates (K\$s.txt)"
check "GOT_DBL worldworld"   "two glued \$vars concatenate (\$s\$s)"
check "GOT_PATH p/world/q"   "\$var glued between path segments (p/\$s/q)"
check "GOT_SEP a world b"    "space-separated args stay three words (a \$s b)"
check "GOT_DQ Kqworld"       "double-quoted \"Kq\$s\" still concatenates"
check "GOT_BARE world"       "bare \$s alone expands"

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_expand] FAIL"
    exit 1
fi
echo "[test_hamsh_expand] PASS"
