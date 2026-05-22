#!/usr/bin/env bash
# scripts/test_u22_glibc_demo.sh -- U22 milestone: stress the U-track
# ABI with a wider glibc workload in a single binary.
#
# Boots Hamnix with /bin/u_glibc_demo embedded in the initramfs and
# drives hamsh to exec it. u_glibc_demo is a host-built static-PIE
# OSABI=Linux x86_64 ELF that exercises four glibc subsystems in one
# process:
#
#   1. malloc/free via strdup       -> SYS_brk (and possibly mmap)
#   2. FILE* I/O via fopen/fread    -> openat + fstat + read + close
#   3. printf format variety        -> writev to stdout (in-process)
#   4. time(NULL)                   -> clock_gettime(CLOCK_REALTIME)
#
# Skip-on-missing: if tests/u-binary/u_glibc_demo hasn't been built
# on the host (`make -C tests/u-binary/src/glibc_demo install`),
# exit 0 with a notice so CI in environments without libc6-dev still
# passes.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_glibc_demo
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/glibc_demo; only SKIP on a real
# failure (e.g. a genuine missing static glibc).
ensure_ubin_or_skip test_u22_glibc_demo u_glibc_demo glibc_demo

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u22_glibc_demo] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u22_glibc_demo] (2/4) Swap /init = $HAMSH_ELF + embed u_glibc_demo"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u22_glibc_demo] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u22_glibc_demo] (4/4) Boot QEMU + run /bin/u_glibc_demo via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_glibc_demo\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
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

echo "[test_u22_glibc_demo] --- captured output ---"
cat "$LOG"
echo "[test_u22_glibc_demo] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u22_glibc_demo] OK: $label  ('$needle')"
    else
        echo "[test_u22_glibc_demo] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Primary success criteria: each of the four glibc subsystems
# produced its marker line on serial.
check_marker "strdup/free heap path"   "U22: heap ok"
# fread's byte count varies with whichever /etc/motd ships; just
# assert the marker prefix appeared and N is at least one digit.
if grep -E -q 'U22: motd read [0-9]+ bytes' "$LOG"; then
    motd_bytes=$(grep -E -o 'U22: motd read [0-9]+ bytes' "$LOG" \
        | head -1 | awk '{print $4}')
    if [ "${motd_bytes:-0}" -gt 0 ]; then
        echo "[test_u22_glibc_demo] OK: fopen/fread/fclose path " \
             "(${motd_bytes} bytes read)"
    else
        echo "[test_u22_glibc_demo] MISS: fread returned 0 bytes"
        fail=1
    fi
else
    echo "[test_u22_glibc_demo] MISS: fopen/fread/fclose path " \
         "('U22: motd read N bytes')"
    fail=1
fi
check_marker "printf format variety"   "U22: ints="
check_marker "time(NULL) path"         "U22: time_t="
# Secondary: the U1 ELF-detect path noticed the OSABI=Linux byte.
check_marker "U1/U2 ELF detect"        "Linux-ABI binary detected"

# Diagnostics: surface the next-gap signal for triage.
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u22_glibc_demo] DIAG: kernel logged 'unknown syscall'"
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u22_glibc_demo] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "linux_u:" "$LOG"; then
    echo "[test_u22_glibc_demo] DIAG: linux_u trace lines"
    grep -F "linux_u:" "$LOG" | head -20 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u22_glibc_demo] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u22_glibc_demo] PASS -- heap + FILE* I/O + printf variety + time() all live"
