#!/usr/bin/env bash
# scripts/test_u21_glibc_idprobe.sh -- U21 milestone: identity / time /
# sysinfo / futex syscall surface.
#
# Boots Hamnix with /bin/u_glibc_idprobe embedded in the initramfs and
# drives hamsh to exec it. The fixture is a static-PIE glibc binary
# that prints three "U21:" marker lines, each one keyed on a specific
# syscall handler added in u_syscalls.ad:
#
#   getuid/getgid/getppid -> "U21: uid=0 gid=0 ppid=1"
#   gettimeofday          -> "U21: time tv_sec=..."
#   sysinfo               -> "U21: uptime=..."
#
# Skip-on-missing: if tests/u-binary/u_glibc_idprobe hasn't been built
# on the host (`make -C tests/u-binary/src/glibc_idprobe install`),
# exit 0 with a notice so CI without libc6-dev still passes.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_glibc_idprobe
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/glibc_idprobe; only SKIP on a real
# failure (e.g. a genuine missing static glibc).
ensure_ubin_or_skip test_u21_glibc_idprobe u_glibc_idprobe glibc_idprobe

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u21_glibc_idprobe] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u21_glibc_idprobe] (2/4) Swap /init = $HAMSH_ELF + embed u_idprobe"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u21_glibc_idprobe] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u21_glibc_idprobe] (4/4) Boot QEMU + run /bin/u_glibc_idprobe via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 30 \
    -- "u_glibc_idprobe" 5 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u21_glibc_idprobe] --- captured output ---"
cat "$LOG"
echo "[test_u21_glibc_idprobe] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u21_glibc_idprobe] OK: $label  ('$needle')"
    else
        echo "[test_u21_glibc_idprobe] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Three required markers, one per syscall family added in U21.
check_marker "getuid/getgid/getppid" "U21: uid=0 gid=0 ppid=1"
check_marker "gettimeofday"          "U21: time tv_sec="
check_marker "sysinfo"               "U21: uptime="

# Diagnostics: surface the next-gap signal for triage.
if grep -a -F -q "unknown syscall" "$LOG"; then
    echo "[test_u21_glibc_idprobe] DIAG: kernel logged 'unknown syscall'"
    grep -a -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u21_glibc_idprobe] DIAG: kernel reported a CPU exception"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -a -F -q "linux_u:" "$LOG"; then
    echo "[test_u21_glibc_idprobe] DIAG: linux_u trace lines"
    grep -a -F "linux_u:" "$LOG" | head -20 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u21_glibc_idprobe] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u21_glibc_idprobe] PASS -- uid/gid/ppid + gettimeofday + sysinfo work"
