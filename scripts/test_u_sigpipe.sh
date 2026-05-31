#!/usr/bin/env bash
# scripts/test_u_sigpipe.sh — §3 SIGPIPE-on-broken-pipe test.
#
# Boots Hamnix and execs /bin/u_musl_sigpipe, a musl static-PIE binary
# modelling the daemon "client hung up mid-response" path:
#
#   - installs a SIGPIPE handler, creates a pipe, closes the read end,
#     write()s to the write end — the kernel must raise SIGPIPE in the
#     writer AND have write(2) return -1/EPIPE
#   - repeats with SIG_IGN for SIGPIPE and confirms the broken write
#     still returns EPIPE without terminating the process
#
# PASS criterion: every "SIGPIPE:" marker through "SIGPIPE: PASS".
#
# REQUIRES: musl-gcc on the host. SKIPs (exit 0) if it can't build.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ensure_ubin_or_skip test_u_sigpipe u_musl_sigpipe musl_sigpipe

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u_sigpipe] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u_sigpipe] (2/4) Swap /init = $HAMSH_ELF + embed u_musl_sigpipe"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u_sigpipe] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u_sigpipe] (4/4) Boot QEMU + run /bin/u_musl_sigpipe via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 30 \
    -- "u_musl_sigpipe" 5 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u_sigpipe] --- captured output ---"
cat "$LOG"
echo "[test_u_sigpipe] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u_sigpipe] OK   $label  ('$needle')"
    else
        echo "[test_u_sigpipe] MISS $label  ('$needle')"
        fail=1
    fi
}

check_marker "fixture started"    "SIGPIPE: start"
check_marker "handler delivered"  "SIGPIPE: handler ran"
check_marker "write got EPIPE"    "SIGPIPE: write got EPIPE"
check_marker "SIG_IGN path"       "SIGPIPE: ignored ok"
check_marker "overall PASS"       "SIGPIPE: PASS"

if grep -a -F -q "SIGPIPE: FAIL" "$LOG"; then
    echo "[test_u_sigpipe] DIAG: fixture reported a FAIL marker"
    grep -a -F "SIGPIPE: FAIL" "$LOG" | head -5 || true
    fail=1
fi
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u_sigpipe] DIAG: CPU exception observed"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u_sigpipe] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u_sigpipe] PASS — SIGPIPE on broken pipe works"
