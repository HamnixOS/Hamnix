#!/usr/bin/env bash
# scripts/test_cpuinfo.sh — real /proc/cpuinfo (CPUID identity + SMP
# per-CPU enumeration).
#
# Boots the kernel once with /etc/cpuinfo-test planted
# (ENABLE_CPUINFO_TEST=1); init/main.ad at boot:37.cpi calls
# cpuinfo_selftest() (fs/procfs.ad), which renders /proc/cpuinfo into a
# scratch buffer and asserts:
#   * the real CPUID leaf-0 vendor string is present (NOT the old
#     literal placeholder "Hamnix")
#   * the stanza header "processor\t: 0" appears
#   * the count of "processor\t:" lines equals get_cpus_online()
#     (the live SMP online-CPU counter the AP bring-up bumps)
#
# We boot with -smp 2 so the SMP path actually brings up a second
# logical CPU; the self-test then requires TWO processor stanzas, which
# proves the renderer enumerates per-CPU rather than hardcoding one.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_cpuinfo] PASS
# Fail marker:  [test_cpuinfo] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_cpuinfo] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_cpuinfo] (2/3) Build kernel with /etc/cpuinfo-test marker"
INIT_ELF=build/user/init.elf ENABLE_CPUINFO_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_cpuinfo] (3/3) Boot QEMU (-smp 2) and run the cpuinfo self-test"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_cpuinfo] --- cpuinfo self-test output ---"
grep -E "\[CPUINFO\]" "$LOG" || true
echo "[test_cpuinfo] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_cpuinfo] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[CPUINFO] FAIL" "$LOG"; then
    echo "[test_cpuinfo] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

if grep -qF "[CPUINFO] PASS" "$LOG"; then
    echo "[test_cpuinfo] PASS: kernel self-test reported PASS"
else
    echo "[test_cpuinfo] FAIL: no [CPUINFO] PASS line in serial log" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_cpuinfo] FAIL"
    exit 1
fi

echo "[test_cpuinfo] PASS — /proc/cpuinfo reports the real CPUID vendor and enumerates one stanza per online logical CPU"
