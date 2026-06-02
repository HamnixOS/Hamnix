#!/usr/bin/env bash
# scripts/test_tls_rng.sh — TLS handshake-entropy source self-test.
#
# Proves that the native TLS 1.3 stack (drivers/net/tls.ad) now sources
# its handshake randomness — ClientHello random + the X25519 ephemeral
# private scalar — from the REAL kernel CSPRNG (devrandom_read,
# sys/src/9/port/devrandom.ad) rather than the old jiffies-seeded
# xorshift "toy CSPRNG" placeholder. Weak RNG = predictable key material
# = broken TLS, so this is a SECURITY guard.
#
# Boots the kernel once with /etc/tls-rng-test planted
# (ENABLE_TLS_RNG_TEST=1); init/main.ad at boot:37.tlsrng calls
# tls_rng_selftest() (drivers/net/tls.ad), which:
#   * draws 64 bytes from _tls_rng_bytes twice and asserts the two
#     buffers DIFFER (a deterministic / constant source would not),
#   * asserts neither buffer is all-zero (devrandom self-seeds; an
#     unseeded / stubbed path leaves the buffer untouched),
#   * asserts the output is not a single constant byte (spread).
# It prints an EMERG-level [tls-rng] PASS marker on success.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [tls-rng] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_tls_rng] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_tls_rng] (2/3) Build kernel with /etc/tls-rng-test marker"
INIT_ELF=build/user/init.elf ENABLE_TLS_RNG_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_tls_rng] (3/3) Boot QEMU and run the TLS RNG self-test"
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

echo "[test_tls_rng] --- tls-rng self-test output ---"
grep -a -E "\[tls-rng\]" "$LOG" || true
echo "[test_tls_rng] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_tls_rng] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Any explicit internal failure is fatal.
if grep -a -qF "[tls-rng] FAIL" "$LOG"; then
    echo "[test_tls_rng] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

# The PASS banner must be present.
if grep -a -qF "[tls-rng] PASS" "$LOG"; then
    echo "[test_tls_rng] PASS: TLS handshake entropy from kernel CSPRNG (devrandom)"
else
    echo "[test_tls_rng] FAIL: missing '[tls-rng] PASS' banner" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[tls-rng] FAIL"
    exit 1
fi

echo "[tls-rng] PASS — TLS handshake randomness now drawn from the real kernel CSPRNG (devrandom_read), not the jiffies-seeded toy"
