#!/usr/bin/env bash
# scripts/test_u_sigchld.sh — §3 SIGCHLD + child-reaping test.
#
# Boots Hamnix and execs /bin/u_musl_sigchld, a musl static-PIE binary
# modelling the server-daemon child-management pattern:
#
#   - installs a SIGCHLD handler that reaps via waitpid(-1, WNOHANG)
#   - fork()s a child that _exit(7)s; the exit raises SIGCHLD in the
#     parent; the handler reaps it and confirms WIFEXITED/WEXITSTATUS
#   - fork()s a second child that blocks every signal, kill()s it with
#     SIGKILL, and confirms SIGKILL is uncatchable/unblockable and the
#     WIFSIGNALED / WTERMSIG wait-status encoding is correct
#
# PASS criterion: every "SIGCHLD:" marker through "SIGCHLD: PASS".
#
# REQUIRES: musl-gcc on the host. SKIPs (exit 0) if it can't build.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ensure_ubin_or_skip test_u_sigchld u_musl_sigchld musl_sigchld

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u_sigchld] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u_sigchld] (2/4) Swap /init = $HAMSH_ELF + embed u_musl_sigchld"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u_sigchld] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u_sigchld] (4/4) Boot QEMU + run /bin/u_musl_sigchld via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_musl_sigchld\n'
    sleep 6
    printf 'exit\n'
    sleep 1
) | timeout 35s qemu-system-x86_64 \
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

echo "[test_u_sigchld] --- captured output ---"
cat "$LOG"
echo "[test_u_sigchld] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u_sigchld] OK   $label  ('$needle')"
    else
        echo "[test_u_sigchld] MISS $label  ('$needle')"
        fail=1
    fi
}

check_marker "fixture started"     "SIGCHLD: start"
check_marker "handler delivered"   "SIGCHLD: handler ran"
check_marker "WIFEXITED reap"      "SIGCHLD: reaped exit 7"
check_marker "WIFSIGNALED reap"    "SIGCHLD: reaped killed 9"
check_marker "overall PASS"        "SIGCHLD: PASS"

if grep -F -q "SIGCHLD: FAIL" "$LOG"; then
    echo "[test_u_sigchld] DIAG: fixture reported a FAIL marker"
    grep -F "SIGCHLD: FAIL" "$LOG" | head -5 || true
    fail=1
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u_sigchld] DIAG: CPU exception observed"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u_sigchld] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u_sigchld] PASS — SIGCHLD delivery + child reaping work"
