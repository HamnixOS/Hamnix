#!/usr/bin/env bash
# scripts/test_lex_digit_idents.sh — regression for the Adder lexer's
# digit-leading-identifier rule. Tokens like `9P2000`, `9foo`, `100abc`
# now lex as IDENT, while every existing numeric literal form
# (0x1F, 0b1010, 0o755, 123, 9.5, 9e5, 1.5e-3, 1_000_000) still lexes
# as NUMBER.
#
# Two-layer test:
#   1. Host-side unit test (compiler/lexer_test.py) — runs the
#      tokenizer directly on the 18 representative source strings and
#      checks each emits the expected TOKEN_KIND + value. This catches
#      lexer bugs without paying for a QEMU boot.
#   2. Userland fixture (tests/test_lex_digit_idents.ad) — compiles to
#      a userland ELF and runs under hamsh inside QEMU, proving the
#      whole pipeline (lexer + parser + codegen + linker + loader)
#      stays consistent with the lexer change. Uses `9P2000` and
#      `9foo` as live identifiers and asserts each holds the value it
#      was initialized with.
#
# Shape borrowed from scripts/test_9p_codec.sh: boot once, drive via
# hamsh stdin, grep stdout for the per-fixture PASS banner.
#
# PASS criterion (host side):  `[lexer_test] PASS` in lexer_test.py stdout.
# PASS criterion (kernel side): `[lex_digit_idents] PASS` in serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_lex_digit_idents.elf

echo "[lex_digit_idents] (1/6) Host-side lexer unit tests"
if ! python3 compiler/lexer_test.py; then
    echo "[lex_digit_idents] FAIL: host-side lexer_test.py failed"
    exit 1
fi

echo "[lex_digit_idents] (2/6) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[lex_digit_idents] (3/6) Build tests/test_lex_digit_idents.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_lex_digit_idents.ad \
    -o "$TEST_ELF" >/dev/null

echo "[lex_digit_idents] (4/6) Plant /init = hamsh + /bin/test_lex_digit_idents in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[lex_digit_idents] (5/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[lex_digit_idents] (6/6) Boot QEMU + drive /bin/test_lex_digit_idents via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Same pacing as scripts/test_9p_codec.sh.
    sleep 3
    printf '/bin/test_lex_digit_idents\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[lex_digit_idents] --- captured output ---"
cat "$LOG"
echo "[lex_digit_idents] --- end output ---"

fail=0

if grep -F -q "[lex_digit_idents] start" "$LOG"; then
    echo "[lex_digit_idents] OK: fixture ran"
else
    echo "[lex_digit_idents] MISS: fixture banner missing"
    fail=1
fi

if grep -F -q "[lex_digit_idents] FAIL" "$LOG"; then
    echo "[lex_digit_idents] MISS: per-assertion FAIL line(s) present:"
    grep -F "[lex_digit_idents] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[lex_digit_idents] OK: no per-assertion FAIL lines"
fi

if grep -F -q "[lex_digit_idents] PASS" "$LOG"; then
    echo "[lex_digit_idents] OK: fixture reached PASS"
else
    echo "[lex_digit_idents] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[lex_digit_idents] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[lex_digit_idents] PASS"
