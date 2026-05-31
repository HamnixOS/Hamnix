#!/usr/bin/env bash
# scripts/test_u37_sigaltstack.sh -- U37: sigaltstack(2) round-trip.
#
# Boots Hamnix and runs a musl static-PIE fixture that calls
# sigaltstack(&ss, NULL) then sigaltstack(NULL, &oss). PASS criterion:
# the three fields (ss_sp / ss_size / ss_flags) round-trip identically.
# Closes the only remaining -ENOSYS in U36's busybox sh trace (nr=131).
#
# REQUIRES: musl-gcc on the host. If tests/u-binary/u_musl_sigaltstack
# isn't staged, the script SKIPs.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_musl_sigaltstack
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/musl_sigaltstack; only SKIP on a
# real failure (e.g. a genuine missing musl-gcc).
ensure_ubin_or_skip test_u37_sigaltstack u_musl_sigaltstack musl_sigaltstack

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u37_sigaltstack] (1/4) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u37_sigaltstack] (2/4) Swap /init=hamsh + embed fixture"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u37_sigaltstack] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u37_sigaltstack] (4/4) Boot QEMU + drive sigaltstack fixture"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Prompt-aware drive: wait for hamsh's ready banner before sending input
# (a fixed sleep races boot-time variance -- see _qemu_drive.sh).
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 30 \
    -- "u_musl_sigaltstack" 4 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_u37_sigaltstack] --- captured output ---"
cat "$LOG"
echo "[test_u37_sigaltstack] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_u37_sigaltstack] OK   $label  ('$needle')"
    else
        echo "[test_u37_sigaltstack] MISS $label  ('$needle')"
        fail=1
    fi
}

check_marker "install rc=0"     "U37: install rc=0"
check_marker "query+combined rc=0" "U37: combined rc=0"
check_marker "round-trip PASS"  "U37: PASS"

# Required: no -ENOSYS for the sigaltstack syscall number.
if grep -E -q "unknown syscall nr=131[^0-9]" "$LOG"; then
    echo "[test_u37_sigaltstack] FAIL: still -ENOSYS for nr=131"
    fail=1
else
    echo "[test_u37_sigaltstack] OK   nr=131: no -ENOSYS noise"
fi

if grep -a -F -q "U37: FAIL" "$LOG"; then
    echo "[test_u37_sigaltstack] DIAG: fixture reported FAIL marker"
    fail=1
fi

if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u37_sigaltstack] DIAG: CPU exception observed"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -a -F -q "page fault" "$LOG"; then
    echo "[test_u37_sigaltstack] DIAG: page fault observed"
    grep -a -F "page fault" "$LOG" | head -5 || true
fi
if grep -a -F -q "unknown syscall" "$LOG"; then
    echo "[test_u37_sigaltstack] DIAG: remaining unknown syscall lines"
    grep -a -F "unknown syscall" "$LOG" | sort -u | head -10 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u37_sigaltstack] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u37_sigaltstack] PASS -- sigaltstack(2) round-trip works"
