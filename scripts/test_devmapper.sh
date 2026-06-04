#!/usr/bin/env bash
# scripts/test_devmapper.sh — native device-mapper (dm) self-test.
#
# Boots the kernel once with /etc/devmapper-test planted
# (ENABLE_DEVMAPPER_TEST=1). init/main.ad at boot:37.dm calls
# dm_selftest() (drivers/block/dm.ad), which registers a DEDICATED
# in-kernel backing ramdisk ("dmback0") and PROVES the native
# device-mapper core + linear + crypt targets:
#
#   * LINEAR: a write through the mapped device at virtual LBA 5 lands on
#     the underlying backing sector (under_start 32 + 5 = 37), and reads
#     back through the mapped device unchanged.
#   * CONCATENATION: a two-linear-target mapped device routes virtual
#     span A to backing region @64 and span B to backing region @128, so
#     a write to a sector in each span lands in the correct backing
#     offset (66 and 130 respectively).
#   * CRYPT (dm-crypt / AES-256-XTS, the aes-xts-plain64 default):
#     plaintext written through the crypt device is CIPHERTEXT on the
#     backing store (differs from plaintext), the SAME plaintext at two
#     sectors yields DIFFERENT ciphertext (the sector-keyed plain64
#     tweak), reads round-trip back to the original plaintext, AND the
#     cipher reproduces an independent AES-256-XTS known-answer vector.
#
# The self-test needs NO external disk — it backs everything onto its own
# in-kernel ramdisk, so the boot is fully deterministic.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [device-mapper] PASS
# Fail marker:  [device-mapper] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_devmapper] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_devmapper] (2/3) Build kernel with /etc/devmapper-test marker"
INIT_ELF=build/user/init.elf ENABLE_DEVMAPPER_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_devmapper] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_devmapper] --- captured (device-mapper lines) ---"
grep -E '\[device-mapper\]' "$LOG" || true
echo "[test_devmapper] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_devmapper] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[device-mapper] FAIL" "$LOG"; then
    echo "[test_devmapper] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[device-mapper] self-test reported FAIL" "$LOG"; then
    echo "[test_devmapper] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_devmapper] PASS: $label"
    else
        echo "[test_devmapper] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"            "[device-mapper] self-test start"
check "linear remap"             "[device-mapper] linear: vLBA5 -> backing sector 37 OK"
check "linear readback"          "[device-mapper] linear: readback byte-identical OK"
check "concat span A"            "[device-mapper] concat: span A vLBA2 -> backing 66 OK"
check "concat span B"            "[device-mapper] concat: span B vLBA10 -> backing 130 OK"
check "crypt ciphertext on disk" "[device-mapper] PASS dmcrypt-ciphertext: backing sector 192 is ciphertext OK"
check "crypt tweak sector-keyed" "[device-mapper] PASS dmcrypt-tweak: same plaintext, two sectors -> different ciphertext OK"
check "crypt round-trip sec0"    "[device-mapper] PASS dmcrypt-roundtrip-sec0: sector 0 round-trips to plaintext OK"
check "crypt round-trip sec1"    "[device-mapper] PASS dmcrypt-roundtrip-sec1: sector 1 round-trips to plaintext OK"
check "crypt AES-XTS KAT vector" "[device-mapper] PASS dmcrypt-kat: AES-256-XTS vector matches reference OK"
check "device-mapper PASS"       "[device-mapper] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_devmapper] FAIL"
    exit 1
fi

echo "[test_devmapper] PASS — native device-mapper: linear remap, two-target concatenation, and AES-256-XTS dm-crypt (aes-xts-plain64: sector-keyed tweak, ciphertext-on-disk, plaintext round-trip, known-answer vector) all verified"
