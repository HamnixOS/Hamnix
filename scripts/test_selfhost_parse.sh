#!/usr/bin/env bash
# scripts/test_selfhost_parse.sh — self-hosting milestone: Adder parser
# written in Adder, parsing Adder source into an AST, on the device.
#
# Pipeline:
#   1. Bootstrap check: the Python compiler processes the parser
#      (adder/compiler/parser.ad, reached via parse_selftest.ad's import)
#      all the way to assembly — proving the Adder-in-Adder parser is
#      valid Adder and links against the Adder-in-Adder lexer.
#   2. Build userland including the on-device self-test binary
#      (adder/compiler/parse_selftest.ad -> build/user/parse_selftest.elf).
#   3. Boot under QEMU with hamsh as /init, run /bin/parse_selftest, and
#      assert on the PASS sentinel.
#
# PASS criterion:
#   "[parse_selftest] PASS" appears in the serial log.
#
# The PASS line means: the Adder-in-Adder lexer tokenized an embedded
# Adder snippet (two function defs with a while/if/return body), the
# Adder-in-Adder parser built an AST from those tokens, and every
# asserted node-shape check passed — verified on device, in Adder code.
#
# Shape borrowed from scripts/test_selfhost_lex.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
SELFTEST_ELF=build/user/parse_selftest.elf

# --- (1/6) Bootstrap: Python compiler -> ASM from parser.ad ----------
# parser.ad imports the lexer's globals, so a standalone `asm` of
# parser.ad alone can't resolve those names. We compile parse_selftest.ad
# instead (which imports BOTH lexer.ad and parser.ad) with --emit-asm and
# assert the parser's entry symbols are present in the merged assembly.
echo "[selfhost_parse] (1/6) Bootstrap: compile parser.ad to assembly"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    --emit-asm \
    adder/compiler/parse_selftest.ad \
    -o /tmp/parse_selftest_bootstrap.elf >/dev/null
BOOT_S=adder/compiler/parse_selftest.s
if grep -q "^parse_program:" "$BOOT_S" && \
   grep -q "^parser_init:" "$BOOT_S" && \
   grep -q "^parse_statement:" "$BOOT_S"; then
    echo "[selfhost_parse] OK: parser.ad assembles — parse_program + parser_init + parse_statement symbols present"
else
    echo "[selfhost_parse] FAIL: parser.ad assembly missing expected symbols"
    head -20 "$BOOT_S" || true
    rm -f "$BOOT_S"
    exit 1
fi
rm -f "$BOOT_S"

# --- (2/6) Build userland (incl. parse_selftest) ---------------------
echo "[selfhost_parse] (2/6) Build userland"
bash scripts/build_user.sh >/dev/null
if [ ! -f "$SELFTEST_ELF" ]; then
    echo "[selfhost_parse] FAIL: $SELFTEST_ELF not built"
    exit 1
fi
echo "[selfhost_parse] OK: parse_selftest.elf built"

# --- (3/6) Build modules ---------------------------------------------
echo "[selfhost_parse] (3/6) Build kernel modules"
bash scripts/build_modules.sh >/dev/null

# --- (4/6) Embed hamsh as /init + rebuild kernel --------------------
echo "[selfhost_parse] (4/6) Embed hamsh as /init + rebuild kernel"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# --- (5/6) Boot QEMU, run /bin/parse_selftest via hamsh -------------
echo "[selfhost_parse] (5/6) Boot QEMU + run /bin/parse_selftest via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
FIFO=$(mktemp -u)
mkfifo "$FIFO"

# Deterministic input driver. A blind `sleep 6; type` pipe races the
# shell's readline window: on a slow/contended TCG host the boot takes
# longer than the sleep, so the command is typed before hamsh is reading
# and gets swallowed. Instead, watch $LOG and type the command only once
# hamsh signals ready, then type `exit` only once the selftest has
# printed its PASS/FAIL verdict.
(
    exec 3>"$FIFO"          # blocks until qemu opens the FIFO for reading
    for _ in $(seq 1 600); do
        grep -q "shell ready" "$LOG" 2>/dev/null && break
        sleep 0.1
    done
    sleep 1
    printf '/bin/parse_selftest\n' >&3
    for _ in $(seq 1 400); do
        grep -Eq '\[parse_selftest\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
        sleep 0.1
    done
    sleep 1
    printf 'exit\n' >&3
    sleep 1
    exec 3>&-
) &
driver_pid=$!

timeout 90s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    < "$FIFO" \
    > "$LOG" 2>&1
qemu_rc=$?
kill "$driver_pid" 2>/dev/null
wait "$driver_pid" 2>/dev/null || true
rm -f "$FIFO"
set -e

# --- (6/6) Assert sentinels -----------------------------------------
echo "[selfhost_parse] (6/6) Assert sentinels"
echo "[selfhost_parse] --- captured output (selftest lines) ---"
grep -E '\[parse_selftest\]' "$LOG" || true
echo "[selfhost_parse] --- end ---"

fail=0

if grep -F -q "[parse_selftest] start" "$LOG"; then
    echo "[selfhost_parse] OK: selftest ran"
else
    echo "[selfhost_parse] MISS: start sentinel absent"
    fail=1
fi

if grep -F -q "[parse_selftest] FAIL" "$LOG"; then
    echo "[selfhost_parse] MISS: per-assertion FAIL line(s) present:"
    grep -F "[parse_selftest] FAIL" "$LOG" | head -5 | sed 's/^/  /'
    fail=1
else
    echo "[selfhost_parse] OK: no FAIL assertions"
fi

if grep -F -q "[parse_selftest] PASS" "$LOG"; then
    echo "[selfhost_parse] OK: PASS sentinel present"
else
    echo "[selfhost_parse] MISS: PASS sentinel absent"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[selfhost_parse] DIAG: kernel CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -3 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[selfhost_parse] FAIL (qemu rc=${qemu_rc})"
    echo "[selfhost_parse] --- full log (last 100 lines) ---"
    tail -n 100 "$LOG"
    exit 1
fi

echo "[selfhost_parse] PASS — Adder-in-Adder parser built an AST from Adder source on device"
