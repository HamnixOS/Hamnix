#!/usr/bin/env bash
# scripts/test_random.sh — cryptographic /dev/random CSPRNG self-test.
#
# Boots the kernel once with /etc/random-test planted
# (ENABLE_RANDOM_TEST=1); init/main.ad at boot:37.rnd calls
# devrandom_selftest() (sys/src/9/port/devrandom.ad), which exercises the
# REAL ChaCha20 (RFC 8439) fast-key-erasure CSPRNG that backs
# /dev/random, /dev/urandom and getrandom(2).
#
# UNFORGEABLE assertions the kernel self-test prints as [random] lines,
# all of which this script requires:
#   * RFC 8439 §2.3.2 ChaCha20 known-answer keystream matches EXACTLY
#     (first 16 bytes 10 f1 e7 e4 d1 3b 59 15 50 0f dd 1f a3 20 71 c4) —
#     this proves the cipher core is correct, not hand-wavy.
#   * the live pool's output is nonconstant (not all-zero / constant)
#   * two successive reads differ (the fast-key-erasure ratchet advances)
#   * two large back-to-back reads differ (no trivially-short period)
#   * the single [random] PASS banner
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [random] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_random] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_random] (2/3) Build kernel with /etc/random-test marker"
INIT_ELF=build/user/init.elf ENABLE_RANDOM_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_random] (3/3) Boot QEMU and run the CSPRNG self-test"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_random] --- random self-test output ---"
grep -a -E "\[random\]" "$LOG" || true
echo "[test_random] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_random] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Any explicit internal failure / mismatch is fatal.
if grep -a -qF "[random] FAIL" "$LOG"; then
    echo "[test_random] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -a -qF "MISMATCH" "$LOG"; then
    echo "[test_random] FAIL: RFC 8439 known-answer mismatch" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -a -qF "$needle" "$LOG"; then
        echo "[test_random] PASS: $label"
    else
        echo "[test_random] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "RFC 8439 §2.3.2 ChaCha20 KAT matches"  "[random] KAT RFC8439-2.3.2 ChaCha20 keystream OK"
check "output is nonconstant"                 "[random] output nonconstant OK"
check "successive reads differ (ratchet)"     "[random] successive reads differ OK"
check "large reads differ (no short period)"  "[random] large reads differ (no short period) OK"
check "reseed mutates pool (post-compromise)" "[random] reseed mutates pool OK"
check "CSPRNG self-test PASS banner"          "[random] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[random] FAIL"
    exit 1
fi

echo "[random] PASS — ChaCha20 (RFC 8439) fast-key-erasure CSPRNG: known-answer cipher core verified, output nonconstant, ratchet advances, no short period, periodic reseed mutates pool"
