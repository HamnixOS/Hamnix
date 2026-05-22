#!/usr/bin/env bash
# scripts/test_u_sigfull.sh — §3 full Linux-ABI signal-delivery test.
#
# Boots Hamnix and execs /bin/u_musl_sigfull, a musl static-PIE binary
# that exercises the signal surface beyond U31's signal()+kill():
#
#   - sigaction(SA_SIGINFO): a 3-arg handler that reads the kernel-
#     built rt_sigframe's siginfo_t.
#   - sigprocmask masking: blocks SIGUSR1, raises it (must NOT fire
#     while blocked), unblocks it (the pending signal must fire then).
#   - rt_sigreturn resume: main() keeps running after the handler.
#
# PASS criterion: every "SIGFULL:" marker through "SIGFULL: PASS".
#
# REQUIRES: musl-gcc on the host. If the fixture can't be built the
# script SKIPs (exit 0) with the real build error.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ensure_ubin_or_skip test_u_sigfull u_musl_sigfull musl_sigfull

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u_sigfull] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u_sigfull] (2/4) Swap /init = $HAMSH_ELF + embed u_musl_sigfull"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u_sigfull] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u_sigfull] (4/4) Boot QEMU + run /bin/u_musl_sigfull via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_musl_sigfull\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
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

echo "[test_u_sigfull] --- captured output ---"
cat "$LOG"
echo "[test_u_sigfull] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u_sigfull] OK   $label  ('$needle')"
    else
        echo "[test_u_sigfull] MISS $label  ('$needle')"
        fail=1
    fi
}

check_marker "fixture started"      "SIGFULL: start"
check_marker "masked signal held"   "SIGFULL: blocked ok"
check_marker "delivered on unblock" "SIGFULL: unblock delivered"
check_marker "siginfo fidelity"     "SIGFULL: siginfo ok"
check_marker "main resumed"         "SIGFULL: resumed ok"
check_marker "overall PASS"         "SIGFULL: PASS"

if grep -F -q "SIGFULL: FAIL" "$LOG"; then
    echo "[test_u_sigfull] DIAG: fixture reported a FAIL marker"
    grep -F "SIGFULL: FAIL" "$LOG" | head -5 || true
    fail=1
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u_sigfull] DIAG: CPU exception observed"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u_sigfull] DIAG: unknown syscall(s)"
    grep -F "unknown syscall" "$LOG" | sort -u | head -10 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u_sigfull] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u_sigfull] PASS — sigaction/sigprocmask/rt_sigreturn work"
