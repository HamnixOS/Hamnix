#!/usr/bin/env bash
# scripts/test_acpi_poweroff.sh — task #168: REAL ACPI S5 poweroff.
#
# Proves Hamnix powers off via the firmware's OWN ACPI FADT + DSDT — the
# portable mechanism that works on real hardware (the NUC) — instead of
# the QEMU/VirtualBox emulator debug ports (0x604/0xB004/0x4004).
#
# drivers/acpi/acpi.ad now parses the FADT (signature "FACP") for the
# PM1a_CNT_BLK / PM1b_CNT_BLK I/O ports and the firmware RESET_REG, and
# scans the DSDT body for the \_S5 NameOp/Package to decode SLP_TYPa /
# SLP_TYPb (the well-known minimal-ACPI poweroff technique — NO full AML
# interpreter). arch/x86/kernel/power.ad's _do_poweroff() then commits a
# real S5 by writing (SLP_TYPa << 10) | SLP_EN(bit13) to PM1a_CNT.
#
# QEMU exposes a real FADT + DSDT with a \_S5 object, so this is
# VM-provable. The self-test (init/main.ad boot:37.acpi, gated on
# /etc/acpi-test which build_initramfs.py plants under ENABLE_ACPI_TEST=1):
#   1. LOGS the concrete parsed values:
#        [acpi] FADT PM1a_CNT_BLK=0x604 SLP_TYPa=0
#      We assert that marker appears AND the values are plausible:
#      a non-zero PM1a port and SLP_TYPa in 0..7.
#   2. Triggers the poweroff in REAL-ONLY mode via power_set_real_only(1):
#      _do_poweroff() issues ONLY the parsed PM1a_CNT S5 write and SKIPS
#      the 0x604/0xB004/0x4004 emulator-port fallback entirely (it logs
#      "[acpi] real-only mode: skipping emulator-port fallback"). So a
#      clean QEMU exit can ONLY have come from the FADT/PM1a write — this
#      is how we ISOLATE and prove the real path, not the shortcut.
#
# A clean QEMU exit (rc != 124) is the success condition; rc 124 means
# `timeout` had to kill a hung VM == the real S5 write did NOT power off.
#
# Modelled on scripts/test_vk_software_raster.sh (build -> boot -> grep
# markers). Prints a single [acpi] PASS line; exits non-zero on failure.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_acpi] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_acpi] (2/3) Build kernel with /etc/acpi-test marker"
INIT_ELF=build/user/init.elf ENABLE_ACPI_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_acpi] (3/3) Boot QEMU and run the real ACPI S5 self-test"
set +e
timeout 120s qemu-system-x86_64 \
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

echo "[test_acpi] --- acpi self-test output ---"
grep -E "\[acpi\]|\\\\_S5|FADT|DSDT" "$LOG" || true
echo "[test_acpi] --- end (qemu rc=$rc) ---"

fail=0

# Explicit internal failure is fatal.
if grep -qF "[acpi] FAIL" "$LOG"; then
    echo "[test_acpi] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

# 1) The parsed-value marker line must appear.
MARKER_LINE="$(grep -E '\[acpi\] FADT PM1a_CNT_BLK=0x[0-9A-Fa-f]+ SLP_TYPa=[0-9]+' "$LOG" | head -1 || true)"
if [ -z "$MARKER_LINE" ]; then
    echo "[test_acpi] FAIL: parsed-value marker '[acpi] FADT PM1a_CNT_BLK=... SLP_TYPa=...' not found" >&2
    fail=1
else
    echo "[test_acpi] OK: parsed-value marker: $MARKER_LINE"
    # Extract and sanity-check the concrete values.
    PORT_HEX="$(echo "$MARKER_LINE" | sed -E 's/.*PM1a_CNT_BLK=0x([0-9A-Fa-f]+).*/\1/')"
    SLP_TYPA="$(echo "$MARKER_LINE" | sed -E 's/.*SLP_TYPa=([0-9]+).*/\1/')"
    PORT_DEC=$((16#$PORT_HEX))
    if [ "$PORT_DEC" -eq 0 ]; then
        echo "[test_acpi] FAIL: PM1a_CNT_BLK port is zero (FADT parse produced no usable port)" >&2
        fail=1
    else
        echo "[test_acpi] OK: PM1a_CNT_BLK=0x$PORT_HEX is non-zero"
    fi
    if [ "$SLP_TYPA" -ge 0 ] && [ "$SLP_TYPA" -le 7 ]; then
        echo "[test_acpi] OK: SLP_TYPa=$SLP_TYPA in plausible range 0..7"
    else
        echo "[test_acpi] FAIL: SLP_TYPa=$SLP_TYPA out of plausible range 0..7" >&2
        fail=1
    fi
fi

# 2) Prove we took the ISOLATED real path (emulator-port fallback skipped).
if grep -qF "[acpi] real-only mode: skipping emulator-port fallback" "$LOG"; then
    echo "[test_acpi] OK: real-only mode active — emulator-port fallback was skipped"
else
    echo "[test_acpi] FAIL: real-only isolation marker missing (cannot prove the real path)" >&2
    fail=1
fi

# 3) Assert the S5 PM1a write actually issued.
if grep -qE '\[acpi\] S5 write PM1a_CNT=0x[0-9A-Fa-f]+' "$LOG"; then
    echo "[test_acpi] OK: real PM1a_CNT S5 write issued"
else
    echo "[test_acpi] FAIL: PM1a_CNT S5 write marker missing" >&2
    fail=1
fi

# 4) The VM must power off on its own (clean exit, not a timeout kill).
#    With the emulator ports skipped, this can ONLY be the FADT/PM1a write.
if [ "$rc" -eq 124 ]; then
    echo "[test_acpi] FAIL: QEMU hung (timeout) — the real PM1a S5 write did not power off" >&2
    fail=1
else
    echo "[test_acpi] OK: QEMU exited on its own (rc=$rc) — the real FADT/PM1a S5 write powered off"
fi

# Belt-and-suspenders: the post-poweroff failure line must NOT appear
# (power_action returns only if every power leg failed to take).
if grep -qF "[acpi] FAIL: poweroff returned" "$LOG"; then
    echo "[test_acpi] FAIL: poweroff returned without powering off" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_acpi] FAIL"
    exit 1
fi

echo "[acpi] PASS"
exit 0
