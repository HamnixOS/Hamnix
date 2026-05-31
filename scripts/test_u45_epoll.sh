#!/usr/bin/env bash
# scripts/test_u45_epoll.sh -- #145 epoll readiness fixture.
#
# epoll (epoll_create1 / epoll_ctl / epoll_wait) is a load-bearing
# Linux-ABI feature implemented in linux_abi/u_epoll.ad (the uepoll_*
# interest-list) and dispatched in linux_abi/u_syscalls.ad, but had no
# automated coverage driven through the prompt-aware qemu_drive harness.
# This fixture drives a real readiness path end-to-end:
#
#   eventfd2(0) -> epoll_create1(0) -> epoll_ctl(ADD, eventfd, EPOLLIN)
#   -> epoll_wait(timeout=0) reports NOTHING ready (eventfd empty)
#   -> write(eventfd, 1) -> epoll_wait reports it ready with our cookie
#   -> epoll_ctl(DEL) -> epoll_wait reports nothing again.
#
# PASS criteria: all four readiness markers land on serial:
#   - "EPOLL: empty not-ready ok"
#   - "EPOLL: ready after write ok"
#   - "EPOLL: data cookie ok"
#   - "EPOLL: del then empty ok"
#   - "epoll_rdy: PASS"
#
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/epoll_rdy; only SKIP on a real build
# failure (e.g. a genuine missing musl-gcc).
#
# REQUIRES: musl-gcc on $PATH. Build step:
#     make -C tests/u-binary/src/epoll_rdy install
#
# NOTE: a trailing QEMU rc=124 AFTER the markers have printed is benign
# (the kernel halts without powering off qemu, so the watchdog reaps it);
# the grep marker checks below are authoritative.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_epoll_rdy
ensure_ubin_or_skip test_u45_epoll u_epoll_rdy epoll_rdy

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u45_epoll] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u45_epoll] (2/4) Swap /init = $HAMSH_ELF + embed u_epoll_rdy"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u45_epoll] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u45_epoll] (4/4) Boot QEMU + run /bin/u_epoll_rdy via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 45 \
    -- "u_epoll_rdy" 8 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u45_epoll] --- captured output ---"
cat "$LOG"
echo "[test_u45_epoll] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    # -a: the serial log carries binary bytes; treat it as text.
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u45_epoll] OK: $label  ('$needle')"
    else
        echo "[test_u45_epoll] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "empty not-ready"      "EPOLL: empty not-ready ok"
check_marker "ready after write"    "EPOLL: ready after write ok"
check_marker "data cookie echoed"   "EPOLL: data cookie ok"
check_marker "del then empty"       "EPOLL: del then empty ok"
check_marker "fixture PASS"         "epoll_rdy: PASS"

# Diagnostics: surface the next-gap signal for triage.
if grep -a -F -q "unknown syscall" "$LOG"; then
    echo "[test_u45_epoll] DIAG: kernel logged 'unknown syscall'"
    grep -a -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u45_epoll] DIAG: kernel reported a CPU exception"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -a -F -q "epoll_rdy: FAIL" "$LOG"; then
    echo "[test_u45_epoll] DIAG: fixture self-reported FAIL"
    grep -a -F "epoll_rdy: FAIL" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u45_epoll] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u45_epoll] PASS -- epoll readiness (eventfd ADD/wait/DEL) works"
