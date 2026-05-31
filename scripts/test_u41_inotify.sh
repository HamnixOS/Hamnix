#!/usr/bin/env bash
# scripts/test_u41_inotify.sh -- #155 inotify fixture.
#
# inotify is the last leg of the eventfd+signalfd+timerfd+inotify trio.
# This fixture drives the full path end-to-end:
#
#   inotify_init1 -> inotify_add_watch("/tmp", CREATE|MODIFY|DELETE) ->
#   create + write + close + unlink /tmp/inofoo -> read() the queued
#   struct inotify_event records.
#
# The filesystem-event notifications are posted by fs/vfs.ad's
# create/unlink/write arms through a function pointer registered by
# linux_abi/u_syscalls.ad (the boundary inversion the CLEARTID wake hook
# uses) into the Layer-2 uino_* pool in linux_abi/u_epoll.ad.
#
# PASS criteria: all three event markers land on serial:
#   - "INOTIFY: IN_CREATE name=inofoo"
#   - "INOTIFY: IN_MODIFY name=inofoo"
#   - "INOTIFY: IN_DELETE name=inofoo"
#   - "inotify_test: PASS"
#
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/inotify_test; only SKIP on a real
# build failure (e.g. a genuine missing musl-gcc).
#
# REQUIRES: musl-gcc on $PATH. Build step:
#     make -C tests/u-binary/src/inotify_test install
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

UBIN=tests/u-binary/u_inotify_test
ensure_ubin_or_skip test_u41_inotify u_inotify_test inotify_test

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u41_inotify] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u41_inotify] (2/4) Swap /init = $HAMSH_ELF + embed u_inotify_test"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u41_inotify] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u41_inotify] (4/4) Boot QEMU + run /bin/u_inotify_test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 45 \
    -- "u_inotify_test" 8 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u41_inotify] --- captured output ---"
cat "$LOG"
echo "[test_u41_inotify] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    # -a: the serial log carries binary bytes; treat it as text.
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u41_inotify] OK: $label  ('$needle')"
    else
        echo "[test_u41_inotify] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "IN_CREATE event" "INOTIFY: IN_CREATE name=inofoo"
check_marker "IN_MODIFY event" "INOTIFY: IN_MODIFY name=inofoo"
check_marker "IN_DELETE event" "INOTIFY: IN_DELETE name=inofoo"
check_marker "fixture PASS"    "inotify_test: PASS"

# Diagnostics: surface the next-gap signal for triage.
if grep -a -F -q "unknown syscall" "$LOG"; then
    echo "[test_u41_inotify] DIAG: kernel logged 'unknown syscall'"
    grep -a -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u41_inotify] DIAG: kernel reported a CPU exception"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -a -F -q "inotify_test: FAIL" "$LOG"; then
    echo "[test_u41_inotify] DIAG: fixture self-reported FAIL"
    grep -a -F "inotify_test: FAIL" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u41_inotify] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u41_inotify] PASS -- inotify create/modify/delete events delivered"
