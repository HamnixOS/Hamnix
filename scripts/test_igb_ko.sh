#!/usr/bin/env bash
# scripts/test_igb_ko.sh — regression guard for the igb.ko load + probe
# path through the L-series loader. Intel 82575/82576/82580/I210/I211/
# I350 server-class GbE.
#
# Strategy: boot hamsh as /init under QEMU with `-device igb` attached,
# drive `insmod /lib/modules/igb.ko` from the shell, snapshot the printk
# ring via `dmesg`, and assert:
#
#   1. `kmod_linux: name=igb` — .ko bytes located + ET_REL parser started.
#   2. `kmod_linux: relocations applied=N skipped=0` for THAT module.
#   3. `kmod_linux: init returned 0` for THAT module.
#   4. `[pci_register_driver] MATCH 8086:....` — the driver's id_table
#      matched the QEMU igb device.
#   5. `[pci_register_driver] probe returned rc=0` — the driver's probe
#      function ran to completion against the L-shim'd PCI device.
#   6. No TRAP / BUG / PANIC / invalid opcode.
#
# QEMU SUPPORT: -device igb was added in QEMU 8.2. When the host QEMU
# doesn't ship it, skip cleanly so older CI hosts don't false-fail.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

KO_PATH="$PROJ_ROOT/kernel-modules/igb/igb.ko"
KO_SIZE=$(stat -c%s "$KO_PATH" 2>/dev/null || echo 0)
if [ "$KO_SIZE" -lt 100000 ]; then
    echo "[test_igb_ko] FAIL: igb.ko missing or too small (${KO_SIZE} bytes)"
    exit 1
fi
echo "[test_igb_ko] OK: igb.ko present (${KO_SIZE} bytes)"

# QEMU device-availability probe.
echo "[test_igb_ko] (0/3) Probe QEMU for -device igb"
HAS_IGB=0
if qemu-system-x86_64 -device help 2>&1 | grep -q '"igb"'; then
    HAS_IGB=1
elif qemu-system-x86_64 -device help 2>&1 | grep -qE '\bigb\b'; then
    HAS_IGB=1
fi
if [ "$HAS_IGB" -ne 1 ]; then
    echo "[test_igb_ko] SKIPPED — this QEMU build has no -device igb"
    echo "[test_igb_ko] (igb.ko load-only smoke still validated by the per-NIC tests above —"
    echo "[test_igb_ko]  this test specifically gates on the probe path which requires the"
    echo "[test_igb_ko]  matching emulated silicon)"
    exit 0
fi

UND_SYMS=$(nm -u "$KO_PATH" 2>/dev/null | awk '{print $2}' | sort -u)
MISSING=""
for sym in $UND_SYMS; do
    if ! grep -rq "_add_export(\"${sym}\"" linux_abi/ 2>/dev/null; then
        MISSING+=" $sym"
    fi
done
TOTAL_UND=$(echo "$UND_SYMS" | wc -w)
TOTAL_MISSING=$(echo "$MISSING" | wc -w)
echo "[test_igb_ko] UND total=$TOTAL_UND missing=$TOTAL_MISSING"
if [ -n "$MISSING" ]; then
    for s in $MISSING; do echo "  - $s"; done
fi

echo "[test_igb_ko] (1/3) Build userland + modules + initramfs (hamsh as /init)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
ENABLE_IGB_KO=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_igb_ko] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s "$ELF" ]; then
    echo "[test_igb_ko] FAIL: kernel ELF missing"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
    exit 1
fi
echo "[test_igb_ko] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"

echo "[test_igb_ko] (3/3) Boot QEMU with -device igb; insmod via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
(
    sleep 3
    printf 'insmod /lib/modules/igb.ko\n'
    sleep 8
    printf 'dmesg\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device igb,netdev=n0,mac=52:54:00:12:34:58 \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_igb_ko] --- captured (kmod / igb / probe) ---"
grep -aE 'kmod_linux: (name=|relocations applied|init returned|unresolved external|unknown reloc)|\[igb\.ko\]|\[igb\]|\[pci_register_driver\]|\[dev_open\]|insmod:' "$LOG" | head -60 || true
echo "[test_igb_ko] --- end ---"

fail=0

if grep -aE -q "PANIC|panic:|^TRAP:|^\[[0-9]+\] TRAP:|^BUG:|^\[[0-9]+\] BUG:|invalid opcode" "$LOG"; then
    echo "[test_igb_ko] FAIL: TRAP / BUG / PANIC reported"
    grep -aE "PANIC|panic:|TRAP:|BUG:|invalid opcode" "$LOG"
    fail=1
fi

if grep -aE -q "insmod: init_module failed" "$LOG"; then
    echo "[test_igb_ko] FAIL: userspace insmod reported init_module failure"
    fail=1
fi

if grep -aE -q "kmod_linux: init returned -[0-9]+" "$LOG"; then
    echo "[test_igb_ko] FAIL: a module's init_module returned non-zero"
    grep -aE "kmod_linux: init returned" "$LOG"
    fail=1
fi

if grep -aF -q "unresolved external symbol" "$LOG"; then
    echo "[test_igb_ko] FAIL: unresolved external symbol reported"
    grep -aF "unresolved external symbol" "$LOG"
    fail=1
fi
if grep -aF -q "unknown reloc type" "$LOG"; then
    echo "[test_igb_ko] FAIL: unknown reloc type reported"
    grep -aF "unknown reloc type" "$LOG"
    fail=1
fi

if ! grep -aE -q "kmod_linux: name=igb( |\$)" "$LOG"; then
    echo "[test_igb_ko] FAIL: igb.ko was not loaded (no 'kmod_linux: name=igb' marker)"
    fail=1
else
    echo "[test_igb_ko] OK: kmod_linux: name=igb"
fi

RELOC_LINE=$(awk '/kmod_linux: name=igb$|kmod_linux: name=igb /,/kmod_linux: init returned/' "$LOG" | grep -aE 'kmod_linux: relocations applied=' | tail -1)
if [ -z "$RELOC_LINE" ]; then
    echo "[test_igb_ko] FAIL: no relocation summary found between name=igb and init returned"
    fail=1
else
    SKIPPED=$(echo "$RELOC_LINE" | grep -oE 'skipped=[0-9]+' | cut -d= -f2)
    APPLIED=$(echo "$RELOC_LINE" | grep -oE 'applied=[0-9]+' | cut -d= -f2)
    if [ "${SKIPPED:-1}" -eq 0 ]; then
        echo "[test_igb_ko] OK: relocations applied=$APPLIED skipped=0"
    else
        echo "[test_igb_ko] FAIL: igb.ko had skipped=${SKIPPED} relocations (applied=${APPLIED})"
        fail=1
    fi
fi

INIT_LINE=$(awk '/kmod_linux: name=igb$|kmod_linux: name=igb /,EOF' "$LOG" | grep -aE 'kmod_linux: init returned' | head -1)
if [ -z "$INIT_LINE" ]; then
    echo "[test_igb_ko] FAIL: no 'kmod_linux: init returned' marker after name=igb"
    fail=1
elif echo "$INIT_LINE" | grep -qE 'init returned 0'; then
    echo "[test_igb_ko] OK: init_module returned 0 ($INIT_LINE)"
else
    echo "[test_igb_ko] FAIL: init_module non-zero ($INIT_LINE)"
    fail=1
fi

# Probe assertions (igb-specific — the QEMU device's PCI ID is matched).
IGB_SECTION=$(awk '/kmod_linux: name=igb$|kmod_linux: name=igb /,EOF' "$LOG")
if echo "$IGB_SECTION" | grep -aE -q "\[pci_register_driver\] MATCH 8086:"; then
    MATCH_LINE=$(echo "$IGB_SECTION" | grep -aE "\[pci_register_driver\] MATCH 8086:" | head -1)
    echo "[test_igb_ko] OK: PCI id matched ($MATCH_LINE)"
else
    echo "[test_igb_ko] FAIL: igb.ko didn't match the QEMU -device igb PCI id"
    fail=1
fi

if echo "$IGB_SECTION" | grep -aE -q "\[pci_register_driver\] probe returned rc=0"; then
    echo "[test_igb_ko] OK: probe returned rc=0"
else
    echo "[test_igb_ko] FAIL: probe didn't return rc=0"
    echo "$IGB_SECTION" | grep -aE "\[pci_register_driver\]" | head -5
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_igb_ko] FAIL (qemu rc=$rc)"
    echo "[test_igb_ko] --- full log tail ---"
    tail -120 "$LOG"
    exit 1
fi

echo "[test_igb_ko] PASS (.ko loaded; PCI match; probe rc=0)"
