#!/usr/bin/env bash
# scripts/test_atlantic_ko.sh — regression guard for the atlantic.ko load
# path through the L-series loader. Aquantia/Marvell AQC10x/AQC11x 10G
# NIC — workstation/Asus-laptop common. No QEMU emulation for AQC
# silicon, so this test exercises the .ko *load* path only (the
# init_module symbol-resolution + relocation pass) and the
# __pci_register_driver invocation. Probe never runs because no matching
# PCI ID is on the bus.
#
# Strategy: boot hamsh as /init, drive `insmod /lib/modules/atlantic.ko`
# from the shell, snapshot the printk ring via `dmesg`, and assert the
# loader ran cleanly. Same shape as scripts/test_ahci_ko.sh /
# test_nvme_ko.sh — actually loading the .ko (not just baking it into the
# initramfs and never touching it) is the only meaningful proof the
# shim surface for this NIC is complete.
#
# V0 assertions:
#   1. `kmod_linux: name=atlantic` — the .ko bytes were located in the
#      initramfs and the L-loader started parsing the ET_REL ELF.
#   2. `kmod_linux: relocations applied=N skipped=0` for THAT module —
#      every UND symbol resolved through either the per-.ko ksymtab or
#      linux_abi/exports.ad's shim table.
#   3. `kmod_linux: init returned 0` for THAT module — init_module ran
#      and returned success.
#   4. No `insmod: init_module failed` reported by userspace.
#   5. No CPU traps / kernel BUGs.
#
# Probe assertion is deferred: the QEMU bus has no Aquantia device, so
# the .ko's __pci_register_driver registers the driver in the bus
# walker but no probe() call fires.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

KO_PATH="$PROJ_ROOT/kernel-modules/atlantic/atlantic.ko"
KO_SIZE=$(stat -c%s "$KO_PATH" 2>/dev/null || echo 0)
if [ "$KO_SIZE" -lt 100000 ]; then
    echo "[test_atlantic_ko] FAIL: atlantic.ko missing or too small (${KO_SIZE} bytes)"
    exit 1
fi
echo "[test_atlantic_ko] OK: atlantic.ko present (${KO_SIZE} bytes)"

# Gap diagnostic (informational, non-fatal).
UND_SYMS=$(nm -u "$KO_PATH" 2>/dev/null | awk '{print $2}' | sort -u)
MISSING=""
for sym in $UND_SYMS; do
    if ! grep -rq "_add_export(\"${sym}\"" linux_abi/ 2>/dev/null; then
        MISSING+=" $sym"
    fi
done
TOTAL_UND=$(echo "$UND_SYMS" | wc -w)
TOTAL_MISSING=$(echo "$MISSING" | wc -w)
echo "[test_atlantic_ko] UND total=$TOTAL_UND missing=$TOTAL_MISSING"
if [ -n "$MISSING" ]; then
    for s in $MISSING; do echo "  - $s"; done
fi

echo "[test_atlantic_ko] (1/3) Build userland + modules + initramfs (hamsh as /init)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
ENABLE_ATLANTIC_KO=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_atlantic_ko] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s "$ELF" ]; then
    echo "[test_atlantic_ko] FAIL: kernel ELF missing"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
    exit 1
fi
echo "[test_atlantic_ko] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"

echo "[test_atlantic_ko] (3/3) Boot QEMU; insmod via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
(
    sleep 3
    printf 'insmod /lib/modules/atlantic.ko\n'
    sleep 8
    printf 'dmesg\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_atlantic_ko] --- captured (kmod / atlantic / probe) ---"
grep -aE 'kmod_linux: (name=|vermagic=|relocations applied|init returned|unresolved external|unknown reloc)|\[atlantic\.ko\]|\[atlantic\]|\[pci_register_driver\]|insmod:' "$LOG" | head -60 || true
echo "[test_atlantic_ko] --- end ---"

fail=0

# Hard fail on panic / trap / BUG.
if grep -aE -q "PANIC|panic:|^TRAP:|^\[[0-9]+\] TRAP:|^BUG:|^\[[0-9]+\] BUG:|invalid opcode" "$LOG"; then
    echo "[test_atlantic_ko] FAIL: TRAP / BUG / PANIC reported"
    grep -aE "PANIC|panic:|TRAP:|BUG:|invalid opcode" "$LOG"
    fail=1
fi

# Hard fail on userspace insmod failure.
if grep -aE -q "insmod: init_module failed" "$LOG"; then
    echo "[test_atlantic_ko] FAIL: userspace insmod reported init_module failure"
    fail=1
fi

# Hard fail on any module's init returning non-zero.
if grep -aE -q "kmod_linux: init returned -[0-9]+" "$LOG"; then
    echo "[test_atlantic_ko] FAIL: a module's init_module returned non-zero"
    grep -aE "kmod_linux: init returned" "$LOG"
    fail=1
fi

# Hard fail on unresolved external symbol diagnostics.
if grep -aF -q "unresolved external symbol" "$LOG"; then
    echo "[test_atlantic_ko] FAIL: unresolved external symbol reported"
    grep -aF "unresolved external symbol" "$LOG"
    fail=1
fi
if grep -aF -q "unknown reloc type" "$LOG"; then
    echo "[test_atlantic_ko] FAIL: unknown reloc type reported"
    grep -aF "unknown reloc type" "$LOG"
    fail=1
fi

# Strong: the target .ko was actually loaded by the L-loader.
if ! grep -aE -q "kmod_linux: name=atlantic( |\$)" "$LOG"; then
    echo "[test_atlantic_ko] FAIL: atlantic.ko was not loaded (no 'kmod_linux: name=atlantic' marker)"
    fail=1
else
    echo "[test_atlantic_ko] OK: kmod_linux: name=atlantic"
fi

# Strong: relocations applied with skipped=0 for the target .ko. We
# extract the relocation summary line that follows 'name=atlantic'.
RELOC_LINE=$(awk '/kmod_linux: name=atlantic$|kmod_linux: name=atlantic /,/kmod_linux: init returned/' "$LOG" | grep -aE 'kmod_linux: relocations applied=' | tail -1)
if [ -z "$RELOC_LINE" ]; then
    echo "[test_atlantic_ko] FAIL: no relocation summary found between name=atlantic and init returned"
    fail=1
else
    SKIPPED=$(echo "$RELOC_LINE" | grep -oE 'skipped=[0-9]+' | cut -d= -f2)
    APPLIED=$(echo "$RELOC_LINE" | grep -oE 'applied=[0-9]+' | cut -d= -f2)
    if [ "${SKIPPED:-1}" -eq 0 ]; then
        echo "[test_atlantic_ko] OK: relocations applied=$APPLIED skipped=0"
    else
        echo "[test_atlantic_ko] FAIL: atlantic.ko had skipped=${SKIPPED} relocations (applied=${APPLIED})"
        fail=1
    fi
fi

# Strong: init_module returned 0 for the target .ko.
INIT_LINE=$(awk '/kmod_linux: name=atlantic$|kmod_linux: name=atlantic /,EOF' "$LOG" | grep -aE 'kmod_linux: init returned' | head -1)
if [ -z "$INIT_LINE" ]; then
    echo "[test_atlantic_ko] FAIL: no 'kmod_linux: init returned' marker after name=atlantic"
    fail=1
elif echo "$INIT_LINE" | grep -qE 'init returned 0'; then
    echo "[test_atlantic_ko] OK: init_module returned 0 ($INIT_LINE)"
else
    echo "[test_atlantic_ko] FAIL: init_module non-zero ($INIT_LINE)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_atlantic_ko] FAIL (qemu rc=$rc)"
    echo "[test_atlantic_ko] --- full log tail ---"
    tail -120 "$LOG"
    exit 1
fi

echo "[test_atlantic_ko] PASS (.ko loaded; relocations clean; init_module returned 0)"
