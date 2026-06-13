#!/usr/bin/env bash
# scripts/test_seccomp_bpf.sh -- §6 classic-BPF seccomp filter.
#
# §6 closes the "seccomp-bpf (full classic-BPF program)" gap. The
# kernel-side cBPF interpreter is kernel/seccomp_bpf.ad; the prctl arm
# is linux_abi/u_syscalls.ad PR_SET_SECCOMP_BPF (0x10001); evaluation
# fires at the central Linux-ABI dispatch boundary in
# linux_u_syscall_dispatch via seccomp_check_entry. A SECCOMP_RET_ERRNO
# action is returned to userspace as -errno in %rax (no SIGSYS); other
# actions (KILL/TRAP) raise SIGSYS the same way the bitmap filter does.
#
# Fixture flow (tests/u-binary/src/seccomp_bpf/seccomp_bpf.c):
#   pre-arm write -> prctl(PR_SET_SECCOMP_BPF, &fprog) where fprog is a
#   5-insn cBPF program returning ERRNO|EACCES for SYS_open/SYS_openat
#   and ALLOW for everything else -> allowed write still works ->
#   open("/dev/null", O_RDONLY) returns -EACCES -> _exit(0).
#
# PASS criteria: all of these markers land on serial:
#   - "SECCOMP_BPF: pre-arm write ok"
#   - "SECCOMP_BPF: filter armed"
#   - "SECCOMP_BPF: allowed write after arm"
#   - "SECCOMP_BPF: open denied EACCES"
#   - "seccomp_bpf: PASS"
#
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/seccomp_bpf; only SKIP on a real
# build failure (a genuine missing musl-gcc).
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

UBIN=tests/u-binary/u_seccomp_bpf
ensure_ubin_or_skip test_seccomp_bpf u_seccomp_bpf seccomp_bpf

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_seccomp_bpf] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_seccomp_bpf] (2/4) Swap /init = $HAMSH_ELF + embed u_seccomp_bpf"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_seccomp_bpf] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_seccomp_bpf] (4/4) Boot QEMU + run /bin/u_seccomp_bpf via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 45 \
    -- "u_seccomp_bpf" 8 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_seccomp_bpf] --- captured output ---"
cat "$LOG"
echo "[test_seccomp_bpf] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_seccomp_bpf] OK: $label  ('$needle')"
    else
        echo "[test_seccomp_bpf] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "pre-arm write"        "SECCOMP_BPF: pre-arm write ok"
check_marker "filter armed"         "SECCOMP_BPF: filter armed"
check_marker "allowed after arm"    "SECCOMP_BPF: allowed write after arm"
check_marker "open denied EACCES"   "SECCOMP_BPF: open denied EACCES"
check_marker "fixture PASS"         "seccomp_bpf: PASS"

if grep -a -F -q "seccomp_bpf:" "$LOG"; then
    echo "[test_seccomp_bpf] DIAG: kernel cBPF trace:"
    grep -a -F "seccomp_bpf:" "$LOG" | head -10 || true
fi
if grep -a -F -q "seccomp_bpf: FAIL" "$LOG"; then
    echo "[test_seccomp_bpf] DIAG: fixture self-reported FAIL"
    grep -a -F "seccomp_bpf: FAIL" "$LOG" | head -5 || true
fi
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_seccomp_bpf] DIAG: kernel reported a CPU exception"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_seccomp_bpf] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_seccomp_bpf] PASS -- seccomp cBPF: ALLOW + ERRNO actions e2e"
