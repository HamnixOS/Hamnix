#!/usr/bin/env bash
# scripts/test_u31_signal.sh — U31 signal-delivery regression.
#
# Boots Hamnix and execs /bin/u_musl_signal, a musl-built static-PIE
# binary that installs a SIGUSR1 handler via signal(), self-kills via
# kill(getpid(), SIGUSR1), and prints a PASS marker iff the handler
# ran. PASS criterion: "U31: signal delivered" on serial.
#
# REQUIRES: musl-gcc on the host (apt-get install -y musl-tools).
# If tests/u-binary/u_musl_signal isn't staged, the script SKIPs.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_musl_signal
if [ ! -f "$UBIN" ]; then
    echo "[test_u31_signal] SKIP: $UBIN not staged"
    echo "    REQUIRES musl-gcc on host."
    echo "    apt-get install -y musl-tools  # (needs sudo)"
    echo "    then: make -C tests/u-binary/src/musl_signal install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u31_signal] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u31_signal] (2/4) Swap /init = $HAMSH_ELF + embed u_musl_signal"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u31_signal] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u31_signal] (4/4) Boot QEMU + run /bin/u_musl_signal via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_musl_signal\n'
    sleep 4
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

echo "[test_u31_signal] --- captured output ---"
cat "$LOG"
echo "[test_u31_signal] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u31_signal] OK: $label  ('$needle')"
    else
        echo "[test_u31_signal] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "pre-kill reached"     "U31: pre-kill"
check_marker "handler delivered"    "U31: signal delivered"

if grep -F -q "U31: signal NOT delivered" "$LOG"; then
    echo "[test_u31_signal] DIAG: handler did not fire (Part C regression)"
fi
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u31_signal] DIAG: unknown syscall(s)"
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u31_signal] DIAG: CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u31_signal] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u31_signal] PASS — signal() / kill() / handler dispatch works"
