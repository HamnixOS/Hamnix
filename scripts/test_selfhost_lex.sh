#!/usr/bin/env bash
# scripts/test_selfhost_lex.sh — self-hosting milestone: Adder lexer
# written in Adder, lexing Adder source, on the device.
#
# Pipeline:
#   1. Bootstrap check: Python compiler processes adder/compiler/lexer.ad
#      to assembly — proves the Adder-in-Adder lexer is valid Adder.
#   2. Build userland including the on-device self-test binary
#      (adder/compiler/lex_selftest.ad -> build/user/lex_selftest.elf).
#   3. Boot under QEMU with hamsh as /init, run /bin/lex_selftest, and
#      assert on the PASS sentinel.
#
# PASS criterion:
#   "[lex_selftest] PASS" appears in the serial log.
#
# The PASS line means: the Adder-in-Adder lexer correctly tokenized the
# embedded Adder snippet "def add(a: int32, b: int32) -> int32:\n..."
# into the expected 23-token stream, verified on device, in Adder code.
#
# Shape borrowed from scripts/test_lex_digit_idents.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
SELFTEST_ELF=build/user/lex_selftest.elf

# --- (1/6) Bootstrap: Python compiler -> ASM from lexer.ad -----------
echo "[selfhost_lex] (1/6) Bootstrap: compile lexer.ad to assembly"
python3 -m compiler.adder asm \
    --target=x86_64-bare-metal \
    adder/compiler/lexer.ad \
    -o /tmp/lexer_bootstrap.s
if grep -q "^lex_tokenize:" /tmp/lexer_bootstrap.s && \
   grep -q "^lex_init:" /tmp/lexer_bootstrap.s; then
    echo "[selfhost_lex] OK: lexer.ad assembles — lex_init + lex_tokenize symbols present"
else
    echo "[selfhost_lex] FAIL: lexer.ad assembly missing expected symbols"
    head -20 /tmp/lexer_bootstrap.s
    exit 1
fi

# --- (2/6) Build userland (incl. lex_selftest) -----------------------
echo "[selfhost_lex] (2/6) Build userland"
bash scripts/build_user.sh >/dev/null
if [ ! -f "$SELFTEST_ELF" ]; then
    echo "[selfhost_lex] FAIL: $SELFTEST_ELF not built"
    exit 1
fi
echo "[selfhost_lex] OK: lex_selftest.elf built"

# --- (3/6) Build modules ---------------------------------------------
echo "[selfhost_lex] (3/6) Build kernel modules"
bash scripts/build_modules.sh >/dev/null

# --- (4/6) Embed hamsh as /init + rebuild kernel --------------------
echo "[selfhost_lex] (4/6) Embed hamsh as /init + rebuild kernel"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# --- (5/6) Boot QEMU, run /bin/lex_selftest via hamsh ---------------
echo "[selfhost_lex] (5/6) Boot QEMU + run /bin/lex_selftest via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
(
    sleep 6
    printf '/bin/lex_selftest\n'
    sleep 10
    printf 'exit\n'
    sleep 2
) | timeout 55s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
qemu_rc=$?
set -e

# --- (6/6) Assert sentinels -----------------------------------------
echo "[selfhost_lex] (6/6) Assert sentinels"
echo "[selfhost_lex] --- captured output (selftest lines) ---"
grep -E '\[lex_selftest\]' "$LOG" || true
echo "[selfhost_lex] --- end ---"

fail=0

if grep -F -q "[lex_selftest] start" "$LOG"; then
    echo "[selfhost_lex] OK: selftest ran"
else
    echo "[selfhost_lex] MISS: start sentinel absent"
    fail=1
fi

if grep -F -q "[lex_selftest] FAIL" "$LOG"; then
    echo "[selfhost_lex] MISS: per-assertion FAIL line(s) present:"
    grep -F "[lex_selftest] FAIL" "$LOG" | head -5 | sed 's/^/  /'
    fail=1
else
    echo "[selfhost_lex] OK: no FAIL assertions"
fi

if grep -F -q "[lex_selftest] PASS" "$LOG"; then
    echo "[selfhost_lex] OK: PASS sentinel present"
else
    echo "[selfhost_lex] MISS: PASS sentinel absent"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[selfhost_lex] DIAG: kernel CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -3 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[selfhost_lex] FAIL (qemu rc=${qemu_rc})"
    echo "[selfhost_lex] --- full log (last 100 lines) ---"
    tail -n 100 "$LOG"
    exit 1
fi

echo "[selfhost_lex] PASS — Adder-in-Adder lexer tokenized Adder source on device"
