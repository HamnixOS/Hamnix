#!/usr/bin/env bash
# scripts/test_sysinfo.sh — sysinfo(2) live-accounting self-test.
#
# Boots the kernel once with /etc/sysinfo-test planted
# (ENABLE_SYSINFO_TEST=1). init/main.ad at boot:37.sysi calls
# sysinfo_selftest() (linux_abi/u_syscalls.ad), which:
#
#   * drives _u_sysinfo against a 256-byte buffer pre-poisoned with 0xAA
#     (so any field that fails to get written stays unmistakable),
#   * asserts mem_unit == 1,
#   * asserts totalram > 0 AND totalram == page_alloc_total() * 4096
#     (the LIVE page-allocator total, not the old hardcoded constant),
#   * asserts 0 < freeram <= totalram (live free-page count * 4096),
#   * asserts procs >= 1 (live task-slot count).
#
# A PASS proves the Linux `struct sysinfo` is now filled from live kernel
# accounting rather than fake constants. Needs NO block device.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [SYSINFO] PASS
# Fail marker:  [SYSINFO] FAIL / self-test reported FAIL
#
# A QEMU timeout (rc=124) is EXPECTED/normal — the PASS banner is the
# pass condition, not the process exit code.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_sysinfo] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_sysinfo] (2/3) Build kernel with /etc/sysinfo-test marker"
INIT_ELF=build/user/init.elf ENABLE_SYSINFO_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_sysinfo] (3/3) Boot QEMU (no disk needed)"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_sysinfo] --- captured (SYSINFO lines) ---"
grep -E '\[SYSINFO\]|\[boot:37\.sysi\]' "$LOG" || true
echo "[test_sysinfo] --- end ---"

fail=0

# A QEMU timeout (rc=124) is the normal, expected exit — the kernel never
# powers off. Only a genuinely abnormal exit code is a failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_sysinfo] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[SYSINFO] FAIL" "$LOG"; then
    echo "[test_sysinfo] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[SYSINFO] self-test reported FAIL" "$LOG"; then
    echo "[test_sysinfo] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_sysinfo] PASS: $label"
    else
        echo "[test_sysinfo] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "sysinfo self-test PASS" "[SYSINFO] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_sysinfo] FAIL"
    exit 1
fi

echo "[test_sysinfo] PASS — sysinfo(2) reports live totalram/freeram/loads/procs from real kernel accounting"
