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

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_musl_sigaltstack
if [ ! -f "$UBIN" ]; then
    echo "[test_u37_sigaltstack] SKIP: $UBIN not staged"
    echo "    REQUIRES musl-gcc on host."
    echo "    apt-get install -y musl-tools  # (needs sudo)"
    echo "    then: make -C tests/u-binary/src/musl_sigaltstack install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
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
(
    sleep 3
    printf 'u_musl_sigaltstack\n'
    sleep 4
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

echo "[test_u37_sigaltstack] --- captured output ---"
cat "$LOG"
echo "[test_u37_sigaltstack] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
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

if grep -F -q "U37: FAIL" "$LOG"; then
    echo "[test_u37_sigaltstack] DIAG: fixture reported FAIL marker"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u37_sigaltstack] DIAG: CPU exception observed"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "page fault" "$LOG"; then
    echo "[test_u37_sigaltstack] DIAG: page fault observed"
    grep -F "page fault" "$LOG" | head -5 || true
fi
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u37_sigaltstack] DIAG: remaining unknown syscall lines"
    grep -F "unknown syscall" "$LOG" | sort -u | head -10 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u37_sigaltstack] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u37_sigaltstack] PASS -- sigaltstack(2) round-trip works"
