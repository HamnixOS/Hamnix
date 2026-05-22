#!/usr/bin/env bash
# scripts/test_u39_python.sh -- U39 milestone: first Python
# interpreter running through the Hamnix U-track Linux ABI.
#
# Boots Hamnix with /bin/u_python embedded in the initramfs and
# drives hamsh to exec it. u_python is a host-built static-PIE
# OSABI=Linux x86_64 ELF -- specifically MicroPython 1.22.0's unix
# port, ~900 KB, exercising the same brk/mmap/futex/clock_gettime
# surface that U18..U27 paved for glibc/musl. See
# tests/u-binary/src/python/HOWTO.md for the "why MicroPython, not
# CPython" rationale.
#
# Why this milestone matters: Hamnix is being scoped as a server
# OS that runs apt-installable Python. This is the proof-of-
# concept that the Linux ABI surface is wide enough to host a
# real interpreter end-to-end. The "real CPython" swap is a
# follow-up that reuses this fixture's contract:
# `u_python -c "print(...)"` prints to stdout.
#
# The single success marker is the literal "hello from hamnix"
# on serial -- that's the line printed by the embedded Python
# expression `print('hello from hamnix')`. It can only appear if:
#
#   1. hamsh tokenised the quoted -c argument correctly (U17 envp
#      / argv plumbing).
#   2. SYS_SPAWN + ELF loader brought up the static-pie binary
#      (U5 + U10 + U14 + U19 paths).
#   3. The interpreter reached its print path through the U4 +
#      U7 write/writev syscalls without an unhandled -ENOSYS
#      hit on the boot path.
#
# Skip-on-missing: if tests/u-binary/u_python hasn't been built
# on the host (`make -C tests/u-binary/src/python install`),
# exit 0 with a notice so CI in environments without git /
# static-pie still passes -- same shape as U22/U24.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_python
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/python; only SKIP on a real failure
# (this MicroPython fixture does a git clone — an offline host will
# fail here, which is the correct, informative skip reason).
ensure_ubin_or_skip test_u39_python u_python python

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u39_python] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u39_python] (2/4) Swap /init = $HAMSH_ELF + embed u_python"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u39_python] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u39_python] (4/4) Boot QEMU + run /bin/u_python via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 5
    # u_python -c "print('hello from hamnix')"
    # hamsh's tokenizer supports double quotes (see user/hamsh.ad:240);
    # we use that to keep the print() expression as a single argv slot.
    #
    # M16.104 dropped the `-X heapsize=64k` workaround. The legacy
    # brk path kmalloc'd one chunk at a time and only succeeded when
    # consecutive chunks happened to land adjacent -- for the default
    # 1 MiB MicroPython GC arena that almost never happened, malloc
    # printed "break adjusted to free malloc space" + aborted inside
    # glibc-malloc's arena bookkeeping (exit 134 = SIGABRT). The new
    # path reserves 4 MiB of CONTIGUOUS physical memory per task via
    # alloc_pages(MAX_ORDER) on the first brk() call and just adjusts
    # a per-task cursor inside it for subsequent calls -- guaranteed
    # virtually contiguous, no kmalloc fragmentation, no abort.
    printf "u_python -c \"print('hello from hamnix')\"\n"
    sleep 30
    printf 'exit\n'
    sleep 1
) | timeout 90s qemu-system-x86_64 \
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

echo "[test_u39_python] --- captured output (tail 80) ---"
tail -80 "$LOG"
echo "[test_u39_python] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u39_python] OK: $label  ('$needle')"
    else
        echo "[test_u39_python] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Primary success criterion: Python's print() reached serial.
check_marker "python print() output"   "hello from hamnix"
# Secondary: the U1 ELF-detect path noticed the OSABI=Linux byte.
check_marker "U1/U2 ELF detect"        "Linux-ABI binary detected"

# Diagnostics: surface the next-gap signal for triage.
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u39_python] DIAG: kernel logged 'unknown syscall'"
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u39_python] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "linux_u:" "$LOG"; then
    echo "[test_u39_python] DIAG: linux_u trace lines (first 20)"
    grep -F "linux_u:" "$LOG" | head -20 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u39_python] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u39_python] PASS -- Python (MicroPython static-pie) runs on Hamnix"
