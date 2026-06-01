#!/usr/bin/env bash
# scripts/test_hamnix_ac.sh — end-to-end smoke test for scripts/hamnix-ac.
#
# Proves the full host->device->host->device loop:
#
#   1. HOST invokes scripts/hamnix-ac on a small REAL Adder source file
#      (adder/compiler/hamnix_ac_smoke_input.ad). That boots Hamnix under
#      QEMU, the SELF-HOSTED compiler (lexer.ad->parser.ad->codegen.ad->
#      elf_emit.ad) compiles the FILE on-device, and the emitted ELF is
#      hex-dumped over serial and reconstructed on the host.
#
#   2. The reconstructed ELF is staged into the initramfs (auto-staged at
#      /bin/hamnix_ac_smoke), the kernel is rebuilt, and in a SECOND QEMU
#      boot hamsh EXECs it natively at CPL-3.
#
# The smoke input's main() returns sumto(8) + triple(2) == 36 + 6 == 42,
# so the gating assertion is the kernel scheduler reporting the emitted
# task exited with code=42.
#
# PASS means: host invoked hamnix-ac -> on-device self-hosted compiler
# emitted the ELF -> that EXACT ELF executed natively at CPL-3 -> correct
# result (42). NOT an emulator.
#
# Shape borrowed from scripts/test_selfhost_elf.sh PHASE B.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
# The emitted ELF is staged under a SHORT binary name (/bin/hcc). The
# 16550 serial RX FIFO is only 16 bytes with no kernel-side software
# buffer (M16.34), so a command line longer than ~15 chars gets its tail
# dropped before SYS_READ drains it. "/bin/hcc\n" is 9 bytes — safely
# under the FIFO depth — so the exec command lands intact.
SMOKE_INPUT=adder/compiler/hamnix_ac_smoke_input.ad
SMOKE_OUT=build/user/hcc.elf
SMOKE_BIN=/bin/hcc
EXPECT_EXIT=42

# --- (1/3) Compile the input ON-DEVICE via hamnix-ac -----------------
echo "[hamnix_ac] (1/3) Compile $SMOKE_INPUT on-device via hamnix-ac"
rm -f "$SMOKE_OUT"
if ! bash scripts/hamnix-ac "$SMOKE_INPUT" -o "$SMOKE_OUT"; then
    echo "[hamnix_ac] FAIL: hamnix-ac returned nonzero"
    exit 1
fi
if [ ! -s "$SMOKE_OUT" ]; then
    echo "[hamnix_ac] FAIL: $SMOKE_OUT not produced"
    exit 1
fi
NBYTES=$(wc -c < "$SMOKE_OUT")
echo "[hamnix_ac] compiled $SMOKE_INPUT -> $SMOKE_OUT (${NBYTES} bytes)"
echo "[hamnix_ac] reconstructed $(file "$SMOKE_OUT")"

# --- (2/3) Rebuild initramfs (auto-stages /bin/hamnix_ac_smoke) ------
echo "[hamnix_ac] (2/3) Stage emitted ELF + rebuild kernel"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# Restore the default initramfs (and drop the emitted ELF) on exit.
trap 'rm -f "$SMOKE_OUT"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

run_qemu() {
    local log="$1" cmd="$2" donere="$3" cmd2="${4:-}" donere2="${5:-}"
    local fifo
    fifo=$(mktemp -u)
    mkfifo "$fifo"
    (
        exec 3>"$fifo"
        for _ in $(seq 1 600); do
            grep -q "shell ready" "$log" 2>/dev/null && break
            sleep 0.1
        done
        sleep 1
        printf '%s\n' "$cmd" >&3
        for _ in $(seq 1 600); do
            grep -Eq "$donere" "$log" 2>/dev/null && break
            sleep 0.1
        done
        sleep 1
        if [ -n "$cmd2" ]; then
            printf '%s\n' "$cmd2" >&3
            for _ in $(seq 1 600); do
                grep -Eq "$donere2" "$log" 2>/dev/null && break
                sleep 0.1
            done
            sleep 1
        fi
        printf 'exit\n' >&3
        sleep 1
        exec 3>&-
    ) &
    local driver_pid=$!
    timeout 120s qemu-system-x86_64 \
        -kernel "$ELF" \
        -smp 2 \
        -nographic \
        -no-reboot \
        -m 256M \
        -monitor none \
        -serial stdio \
        < "$fifo" \
        > "$log" 2>&1
    local rc=$?
    kill "$driver_pid" 2>/dev/null
    wait "$driver_pid" 2>/dev/null || true
    rm -f "$fifo"
    return $rc
}

# --- (3/3) Boot QEMU, EXEC the emitted ELF natively ------------------
echo "[hamnix_ac] (3/3) Native exec of hamnix-ac-emitted ELF"
LOG=$(mktemp)
set +e
run_qemu "$LOG" \
    "$SMOKE_BIN" \
    "task: pid [0-9]+ exited \(code=${EXPECT_EXIT}\)" \
    "echo hcc exit=\$status" \
    "hcc exit="
qrc=$?
set -e

echo "[hamnix_ac] --- native exec lines ---"
grep -aE 'task: pid [0-9]+ exited|hcc exit=|TRAP: vector' "$LOG" | grep -avE '\[K' | head -10 || true
echo "[hamnix_ac] --- end ---"

fail=0
if grep -aE -q "task: pid [0-9]+ exited \(code=${EXPECT_EXIT}\)" "$LOG"; then
    echo "[hamnix_ac] native exec exit=${EXPECT_EXIT}"
else
    echo "[hamnix_ac] MISS: kernel did not report code=${EXPECT_EXIT} exit"
    grep -aE "task: pid [0-9]+ exited" "$LOG" || true
    fail=1
fi

if grep -aF -q "hcc exit=${EXPECT_EXIT}" "$LOG"; then
    echo "[hamnix_ac] OK: shell \$status echo also confirms exit=${EXPECT_EXIT}"
fi

if grep -aF -q "TRAP: vector" "$LOG"; then
    echo "[hamnix_ac] DIAG: kernel CPU exception during exec"
    grep -aF "TRAP: vector" "$LOG" | head -3 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[hamnix_ac] FAIL (qemu rc=${qrc})"
    tail -n 100 "$LOG"
    rm -f "$LOG"
    exit 1
fi
rm -f "$LOG"

echo "[hamnix_ac] PASS — host hamnix-ac -> on-device self-hosted compile -> native CPL-3 exec -> exit=${EXPECT_EXIT}"
