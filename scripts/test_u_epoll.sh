#!/usr/bin/env bash
# scripts/test_u_epoll.sh — §5 Layer-2 async-I/O regression.
#
# Boots Hamnix and execs /bin/u_epolltest, a musl static-PIE Linux-ABI
# binary exercising the epoll / eventfd / timerfd / poll / O_NONBLOCK
# surface real Linux event-driven daemons depend on, bridged to the
# Layer-2 shim (linux_abi/u_epoll.ad + u_syscalls.ad + fs/vfs.ad):
#
#   - pipe2(O_NONBLOCK): an empty non-blocking pipe read returns -EAGAIN
#   - eventfd2: write a value, epoll_wait reports it, read drains it
#   - timerfd_create + timerfd_settime: epoll_wait blocks on a one-shot
#     timer, then read returns the expiration count
#   - epoll_create1 + epoll_ctl(ADD) + epoll_wait over pipe + eventfd +
#     timerfd fds
#   - poll(2) over an eventfd as the simpler fallback path
#
# PASS criterion: every "epolltest:" marker through "epolltest: PASS".
#
# REQUIRES: musl-gcc on the host. SKIPs (exit 0) if it can't build.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ensure_ubin_or_skip test_u_epoll u_epolltest epolltest

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u_epoll] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u_epoll] (2/4) Swap /init = $HAMSH_ELF + embed u_epolltest"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u_epoll] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u_epoll] (4/4) Boot QEMU + run /bin/u_epolltest via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "u_epolltest" 12 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u_epoll] --- captured output ---"
grep -E 'epolltest:|\[u_epoll\]|TRAP' "$LOG" || true
echo "[test_u_epoll] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u_epoll] OK   $label  ('$needle')"
    else
        echo "[test_u_epoll] MISS $label  ('$needle')"
        fail=1
    fi
}

check_marker "non-blocking pipe EAGAIN" "epolltest: nonblock-pipe EAGAIN ok"
check_marker "eventfd ready + drain"    "epolltest: eventfd ready+drain ok"
check_marker "timerfd fired"            "epolltest: timerfd fired ok"
check_marker "pipe epoll readiness"     "epolltest: pipe epoll ready ok"
check_marker "poll(2) fallback"         "epolltest: poll eventfd ok"
check_marker "overall PASS"             "epolltest: PASS"

if grep -a -F -q "epolltest: FAIL" "$LOG"; then
    echo "[test_u_epoll] DIAG: fixture reported a FAIL marker"
    grep -a -F "epolltest: FAIL" "$LOG" | head -5 || true
    fail=1
fi
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u_epoll] DIAG: CPU exception observed"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u_epoll] FAIL (qemu rc=$rc)"
    echo "[test_u_epoll] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi

echo "[test_u_epoll] PASS — epoll / eventfd / timerfd / poll /" \
     "O_NONBLOCK all work via the Layer-2 shim"
