#!/usr/bin/env bash
# scripts/test_u_iouring.sh -- §5 Layer-2 io_uring userspace regression.
#
# Closes the TODO §5 deferred "io_uring SQ/CQ rings" item from the
# USERSPACE side: boots Hamnix and execs /bin/u_iouring_test, a musl
# static-PIE Linux-ABI binary exercising the io_uring shim
# (linux_abi/u_iouring.ad) through the documented x86_64 syscall
# numbers (425/426/427), proving the SQE -> CQE roundtrip works from
# a real ring-fd / mmap'd ring caller (complementing the in-kernel
# boot self-test scripts/test_iouring.sh already exercises).
#
# Sequence the fixture drives:
#   - io_uring_setup(4, &params) -> ring fd; sq_entries == 4
#   - mmap SQ, CQ, SQE regions through the ring fd
#   - submit 4 NOP SQEs with distinct user_data, io_uring_enter wait=4
#   - drain 4 CQEs, verify res==0 and user_data roundtrip
#   - io_uring_register(REGISTER_FILES, [0,1], 2) -> 0
#
# PASS criterion: every "iouring_test:" marker through "iouring_test: PASS".
#
# REQUIRES: musl-gcc on the host. SKIPs (exit 0) if it can't build.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ensure_ubin_or_skip test_u_iouring u_iouring_test io_uring

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u_iouring] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u_iouring] (2/4) Swap /init = $HAMSH_ELF + embed u_iouring_test"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u_iouring] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u_iouring] (4/4) Boot QEMU + run /bin/u_iouring_test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending input.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "u_iouring_test" 12 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u_iouring] --- captured output ---"
grep -E 'iouring_test:|\[iouring\]|TRAP' "$LOG" || true
echo "[test_u_iouring] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u_iouring] OK   $label  ('$needle')"
    else
        echo "[test_u_iouring] MISS $label  ('$needle')"
        fail=1
    fi
}

check_marker "setup ok"            "iouring_test: setup ok"
check_marker "mmap + offsets ok"   "iouring_test: mmap+offsets ok"
check_marker "4 NOP CQEs ok"       "iouring_test: 4 NOP CQEs user_data ok"
check_marker "register files ok"   "iouring_test: register files ok"
check_marker "overall PASS"        "iouring_test: PASS"

if grep -a -F -q "iouring_test: FAIL" "$LOG"; then
    echo "[test_u_iouring] DIAG: fixture reported a FAIL marker"
    grep -a -F "iouring_test: FAIL" "$LOG" | head -5 || true
    fail=1
fi
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u_iouring] DIAG: CPU exception observed"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u_iouring] FAIL (qemu rc=$rc)"
    echo "[test_u_iouring] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi

echo "[test_u_iouring] PASS -- io_uring setup/enter/register SQE->CQE" \
     "roundtrip works from real userspace via syscalls 425/426/427"
