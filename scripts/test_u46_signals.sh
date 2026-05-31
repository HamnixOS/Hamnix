#!/usr/bin/env bash
# scripts/test_u46_signals.sh -- #148 POSIX signal e2e fixture.
#
# rt_sigaction / rt_sigprocmask / rt_sigreturn are load-bearing
# Linux-ABI features (linux_abi/u_syscalls.ad _u_rt_sigaction /
# _u_rt_sigprocmask / _u_rt_sigreturn, delivered at the syscall-return
# boundary by deliver_signal_to_user in kernel/sched/core.ad) but had no
# automated coverage driven through the prompt-aware qemu_drive harness.
# This fixture drives the full delivery + return path end-to-end:
#
#   sigaction(SIGUSR1, handler) -> raise(SIGUSR1) -> handler runs AND
#   control resumes PAST raise() (proves rt_sigreturn restored the
#   user context) -> sigprocmask block: raise must NOT fire while
#   blocked -> sigprocmask unblock: the pending signal IS delivered.
#
# Uses musl's sigaction/raise wrappers, so the SA_RESTORER trampoline
# that issues SYS_rt_sigreturn is the real Linux ABI one.
#
# PASS criteria: all four markers land on serial:
#   - "SIGRT: handler ran"
#   - "SIGRT: returned past raise"
#   - "SIGRT: blocked held"
#   - "SIGRT: delivered on unblock"
#   - "sig_rt: PASS"
#
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/sig_rt; only SKIP on a real build
# failure (e.g. a genuine missing musl-gcc).
#
# REQUIRES: musl-gcc on $PATH. Build step:
#     make -C tests/u-binary/src/sig_rt install
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

UBIN=tests/u-binary/u_sig_rt
ensure_ubin_or_skip test_u46_signals u_sig_rt sig_rt

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u46_signals] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u46_signals] (2/4) Swap /init = $HAMSH_ELF + embed u_sig_rt"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u46_signals] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u46_signals] (4/4) Boot QEMU + run /bin/u_sig_rt via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 45 \
    -- "u_sig_rt" 8 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u46_signals] --- captured output ---"
cat "$LOG"
echo "[test_u46_signals] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    # -a: the serial log carries binary bytes; treat it as text.
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u46_signals] OK: $label  ('$needle')"
    else
        echo "[test_u46_signals] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "handler ran"          "SIGRT: handler ran"
check_marker "resumed past raise"   "SIGRT: returned past raise"
check_marker "blocked held"         "SIGRT: blocked held"
check_marker "delivered on unblock" "SIGRT: delivered on unblock"
check_marker "fixture PASS"         "sig_rt: PASS"

# Diagnostics: surface the next-gap signal for triage.
if grep -a -F -q "unknown syscall" "$LOG"; then
    echo "[test_u46_signals] DIAG: kernel logged 'unknown syscall'"
    grep -a -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u46_signals] DIAG: kernel reported a CPU exception"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -a -F -q "sig_rt: FAIL" "$LOG"; then
    echo "[test_u46_signals] DIAG: fixture self-reported FAIL"
    grep -a -F "sig_rt: FAIL" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u46_signals] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u46_signals] PASS -- sigaction/raise/sigreturn + sigprocmask work"
