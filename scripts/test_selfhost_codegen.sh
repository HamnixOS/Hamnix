#!/usr/bin/env bash
# scripts/test_selfhost_codegen.sh — self-hosting milestone: Adder x86_64
# code generator written in Adder, emitting real machine-code bytes for
# Adder source, on the device.
#
# Pipeline:
#   1. Bootstrap check: the Python compiler processes the codegen
#      (adder/compiler/codegen.ad, reached via codegen_selftest.ad's
#      import) all the way to assembly — proving the Adder-in-Adder
#      codegen is valid Adder and links against the Adder-in-Adder lexer
#      and parser.
#   2. Build userland including the on-device self-test binary
#      (adder/compiler/codegen_selftest.ad -> build/user/codegen_selftest.elf).
#   3. Build kernel modules.
#   4. Embed hamsh as /init + rebuild kernel.
#   5. Boot under QEMU with hamsh as /init, run /bin/codegen_selftest, and
#      assert on the PASS sentinel.
#
# PASS criterion:
#   "[codegen_selftest] PASS" appears in the serial log.
#
# The PASS line means: the Adder-in-Adder lexer tokenized an embedded
# Adder snippet (a function returning an arithmetic expression over its
# parameters), the Adder-in-Adder parser built an AST, the Adder-in-Adder
# codegen emitted x86_64 machine-code bytes, every asserted opcode byte
# matched, and a software emulation of the emitted code produced the
# right arithmetic results — verified on device, in Adder code.
#
# Shape borrowed from scripts/test_selfhost_parse.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
SELFTEST_ELF=build/user/codegen_selftest.elf

# --- (1/6) Bootstrap: Python compiler -> ASM from codegen.ad ---------
# codegen.ad imports the lexer's + parser's globals, so a standalone
# `asm` of codegen.ad alone can't resolve those names. We compile
# codegen_selftest.ad instead (which imports lexer.ad, parser.ad AND
# codegen.ad) with --emit-asm and assert the codegen's entry symbols are
# present in the merged assembly.
echo "[selfhost_codegen] (1/6) Bootstrap: compile codegen.ad to assembly"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    --emit-asm \
    adder/compiler/codegen_selftest.ad \
    -o /tmp/codegen_selftest_bootstrap.elf >/dev/null
BOOT_S=adder/compiler/codegen_selftest.s
if grep -q "^gen_function:" "$BOOT_S" && \
   grep -q "^gen_expr:" "$BOOT_S" && \
   grep -q "^gen_program_first_function:" "$BOOT_S" && \
   grep -q "^gen_program_all_functions:" "$BOOT_S" && \
   grep -q "^gen_call:" "$BOOT_S" && \
   grep -q "^gen_if:" "$BOOT_S" && \
   grep -q "^gen_while:" "$BOOT_S"; then
    echo "[selfhost_codegen] OK: codegen.ad assembles — gen_function + gen_expr + gen_program_first_function + gen_program_all_functions + gen_call + gen_if + gen_while symbols present"
else
    echo "[selfhost_codegen] FAIL: codegen.ad assembly missing expected symbols"
    head -20 "$BOOT_S" || true
    rm -f "$BOOT_S"
    exit 1
fi
rm -f "$BOOT_S"

# --- (2/6) Build userland (incl. codegen_selftest) -------------------
echo "[selfhost_codegen] (2/6) Build userland"
bash scripts/build_user.sh >/dev/null
if [ ! -f "$SELFTEST_ELF" ]; then
    echo "[selfhost_codegen] FAIL: $SELFTEST_ELF not built"
    exit 1
fi
echo "[selfhost_codegen] OK: codegen_selftest.elf built"

# --- (3/6) Build modules ---------------------------------------------
echo "[selfhost_codegen] (3/6) Build kernel modules"
bash scripts/build_modules.sh >/dev/null

# --- (4/6) Embed hamsh as /init + rebuild kernel --------------------
echo "[selfhost_codegen] (4/6) Embed hamsh as /init + rebuild kernel"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# --- (5/6) Boot QEMU, run /bin/codegen_selftest via hamsh -----------
echo "[selfhost_codegen] (5/6) Boot QEMU + run /bin/codegen_selftest via hamsh"
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
    printf '/bin/codegen_selftest\n' >&3
    for _ in $(seq 1 400); do
        grep -Eq '\[codegen_selftest\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
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
echo "[selfhost_codegen] (6/6) Assert sentinels"
echo "[selfhost_codegen] --- captured output (selftest lines) ---"
grep -E '\[codegen_selftest\]' "$LOG" || true
echo "[selfhost_codegen] --- end ---"

fail=0

if grep -F -q "[codegen_selftest] start" "$LOG"; then
    echo "[selfhost_codegen] OK: selftest ran"
else
    echo "[selfhost_codegen] MISS: start sentinel absent"
    fail=1
fi

if grep -F -q "[codegen_selftest] FAIL" "$LOG"; then
    echo "[selfhost_codegen] MISS: per-assertion FAIL line(s) present:"
    grep -F "[codegen_selftest] FAIL" "$LOG" | head -5 | sed 's/^/  /'
    fail=1
else
    echo "[selfhost_codegen] OK: no FAIL assertions"
fi

if grep -F -q "[codegen_selftest] PASS" "$LOG"; then
    echo "[selfhost_codegen] OK: PASS sentinel present"
else
    echo "[selfhost_codegen] MISS: PASS sentinel absent"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[selfhost_codegen] DIAG: kernel CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -3 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[selfhost_codegen] FAIL (qemu rc=${qemu_rc})"
    echo "[selfhost_codegen] --- full log (last 100 lines) ---"
    tail -n 100 "$LOG"
    exit 1
fi

echo "[selfhost_codegen] PASS — Adder-in-Adder codegen emitted real x86_64 machine code from Adder source on device"
