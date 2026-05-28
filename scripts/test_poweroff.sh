#!/usr/bin/env bash
# scripts/test_poweroff.sh — real shutdown / reboot regression.
#
# Verifies that the power binaries actually power the (virtual) machine
# down instead of being print-only stubs. Two legs:
#
#   POWEROFF leg:
#     boot -> hamsh prompt -> run `poweroff` -> the kernel power routine
#     (arch/x86/kernel/power.ad) flushes filesystems and issues the QEMU
#     ACPI-S5 debug port (0x604 <- 0x2000), which makes QEMU EXIT ON ITS
#     OWN. The test passes when QEMU exits well before the timeout (rc
#     != 124) rather than hanging until `timeout` kills it. We also
#     assert the kernel's flush + poweroff banner lines appear.
#
#   REBOOT leg:
#     boot -> hamsh prompt -> run `reboot` -> the kernel resets via the
#     i8042 0xFE pulse. Run with -no-reboot so the reset makes QEMU EXIT
#     (instead of looping the firmware). Same "exits on its own" assert.
#
# The poweroff path drives both the native /dev/reboot cdev (the user
# binary opens /dev/reboot and writes "poweroff") AND, transitively, the
# shared power_action() core that the Linux reboot(2)=169 syscall also
# funnels through.
#
# Fixed-sleep timing follows the established safe margin (8s boot, then
# a few seconds per command) — hamsh must reach its readline stage
# before piped keystrokes land, or they get dropped.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_poweroff] (1/4) Build userland (hamsh + coreutils + halt/reboot/poweroff)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_poweroff] (2/4) Plant /init = hamsh in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_poweroff] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# Restore the canonical /init on the way out so we don't leave the cpio
# pointing at hamsh.
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

run_leg() {
    # $1 = leg name, $2 = command to type at the hamsh prompt,
    # $3 = log file. Boots QEMU with -no-reboot so BOTH a poweroff
    # (0x604) and a reboot (i8042 reset) cause QEMU to exit. Returns
    # the QEMU/timeout rc via the global LEG_RC.
    local leg="$1" cmd="$2" log="$3"
    set +e
    (
        sleep 8
        printf '%s\n' "$cmd"
        # Generous tail: if the power action works, QEMU exits during
        # this window long before the 30s timeout fires.
        sleep 10
    ) | timeout 30s qemu-system-x86_64 \
        -kernel "$ELF" \
        -smp 2 \
        -nographic \
        -no-reboot \
        -m 256M \
        -monitor none \
        -serial stdio \
        > "$log" 2>&1
    LEG_RC=$?
    set -e
}

fail=0

echo "[test_poweroff] (4/4a) POWEROFF leg: boot + run 'poweroff'"
LOG_PO=$(mktemp)
run_leg poweroff "poweroff" "$LOG_PO"
PO_RC=$LEG_RC
echo "[test_poweroff] --- poweroff leg output ---"
cat "$LOG_PO"
echo "[test_poweroff] --- end output (qemu rc=$PO_RC) ---"

# rc 124 == `timeout` had to kill QEMU == the VM hung == poweroff did
# NOT take. Any other rc means QEMU exited on its own (the success
# condition for the 0x604 ACPI shutdown path).
if [ "$PO_RC" -eq 124 ]; then
    echo "[test_poweroff] FAIL: QEMU hung (timeout) — poweroff did not power the VM off"
    fail=1
else
    echo "[test_poweroff] OK: QEMU exited on its own (rc=$PO_RC) — ACPI 0x604 shutdown took"
fi

po_markers=(
    "poweroff: requested power off"
    "Hamnix power: flushing filesystems"
    "Hamnix: powering off"
)
for m in "${po_markers[@]}"; do
    if grep -F -q "$m" "$LOG_PO"; then
        echo "[test_poweroff] OK: marker '$m'"
    else
        echo "[test_poweroff] MISS: marker '$m'"
        fail=1
    fi
done
rm -f "$LOG_PO"

echo "[test_poweroff] (4/4b) REBOOT leg: boot + run 'reboot' (-no-reboot => QEMU exits)"
LOG_RB=$(mktemp)
run_leg reboot "reboot" "$LOG_RB"
RB_RC=$LEG_RC
echo "[test_poweroff] --- reboot leg output ---"
cat "$LOG_RB"
echo "[test_poweroff] --- end output (qemu rc=$RB_RC) ---"

if [ "$RB_RC" -eq 124 ]; then
    echo "[test_poweroff] FAIL: QEMU hung (timeout) — reboot did not reset the VM"
    fail=1
else
    echo "[test_poweroff] OK: QEMU exited on its own (rc=$RB_RC) — i8042 reset took"
fi

rb_markers=(
    "reboot: requested reboot"
    "Hamnix power: flushing filesystems"
    "Hamnix: rebooting"
)
for m in "${rb_markers[@]}"; do
    if grep -F -q "$m" "$LOG_RB"; then
        echo "[test_poweroff] OK: marker '$m'"
    else
        echo "[test_poweroff] MISS: marker '$m'"
        fail=1
    fi
done
rm -f "$LOG_RB"

if [ "$fail" -ne 0 ]; then
    echo "[test_poweroff] FAIL"
    exit 1
fi

echo "[test_poweroff] PASS"
