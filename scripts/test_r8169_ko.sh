#!/usr/bin/env bash
# scripts/test_r8169_ko.sh — regression guard for the r8169.ko load path
# through the L-series loader. Realtek consumer GbE (RTL8168/8169/8125
# family). The QEMU `-device rtl8139` PCI ID (0x10ec:0x8139) is in
# r8169's id_table for backward compat — the same .ko binary that drives
# modern Gigabit Realtek chips also matches QEMU's emulated 8139.
#
# Strategy: boot hamsh as /init under QEMU with `-device rtl8139`,
# drive `insmod /lib/modules/r8169.ko` from the shell, snapshot the
# printk ring via `dmesg`, and assert the loader ran cleanly.
#
# V0 assertions:
#   1. `kmod_linux: name=r8169` — .ko bytes located + ET_REL parser started.
#   2. `kmod_linux: relocations applied=N skipped=0` for THAT module.
#   3. `kmod_linux: init returned 0` for THAT module.
#   4. `__pci_register_driver` walked the bus with a non-NULL probe
#      pointer (driver wired its struct correctly).
#   5. No TRAP / BUG / PANIC.
#
# Probe-match against rtl8139 is informational: in some boots the
# bus-walk's PCI ID list misses 0x10ec:0x8139 (the QEMU stub's class
# code differs slightly from real Gigabit silicon). The match-or-not is
# noted but not gating — the strict criterion is "loads cleanly".

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

KO_PATH="$PROJ_ROOT/kernel-modules/r8169/r8169.ko"
KO_SIZE=$(stat -c%s "$KO_PATH" 2>/dev/null || echo 0)
if [ "$KO_SIZE" -lt 100000 ]; then
    echo "[test_r8169_ko] FAIL: r8169.ko missing or too small (${KO_SIZE} bytes)"
    exit 1
fi
echo "[test_r8169_ko] OK: r8169.ko present (${KO_SIZE} bytes)"

UND_SYMS=$(nm -u "$KO_PATH" 2>/dev/null | awk '{print $2}' | sort -u)
MISSING=""
for sym in $UND_SYMS; do
    if ! grep -rq "_add_export(\"${sym}\"" linux_abi/ 2>/dev/null; then
        MISSING+=" $sym"
    fi
done
TOTAL_UND=$(echo "$UND_SYMS" | wc -w)
TOTAL_MISSING=$(echo "$MISSING" | wc -w)
echo "[test_r8169_ko] UND total=$TOTAL_UND missing=$TOTAL_MISSING"
if [ -n "$MISSING" ]; then
    for s in $MISSING; do echo "  - $s"; done
fi

echo "[test_r8169_ko] (1/3) Build userland + modules + initramfs (hamsh as /init)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
ENABLE_R8169_KO=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_r8169_ko] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s "$ELF" ]; then
    echo "[test_r8169_ko] FAIL: kernel ELF missing"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
    exit 1
fi
echo "[test_r8169_ko] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"

echo "[test_r8169_ko] (3/3) Boot QEMU with -device rtl8139; insmod via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
(
    sleep 3
    printf 'insmod /lib/modules/r8169.ko\n'
    sleep 8
    printf 'dmesg\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device rtl8139,netdev=n0,mac=52:54:00:12:34:57 \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_r8169_ko] --- captured (kmod / r8169 / probe) ---"
grep -aE 'kmod_linux: (name=|relocations applied|init returned|unresolved external|unknown reloc)|\[r8169\.ko\]|\[r8169\]|\[pci_register_driver\]|insmod:' "$LOG" | head -60 || true
echo "[test_r8169_ko] --- end ---"

fail=0

if grep -aE -q "PANIC|panic:|^TRAP:|^\[[0-9]+\] TRAP:|^BUG:|^\[[0-9]+\] BUG:|invalid opcode" "$LOG"; then
    echo "[test_r8169_ko] FAIL: TRAP / BUG / PANIC reported"
    grep -aE "PANIC|panic:|TRAP:|BUG:|invalid opcode" "$LOG"
    fail=1
fi

if grep -aE -q "insmod: init_module failed" "$LOG"; then
    echo "[test_r8169_ko] FAIL: userspace insmod reported init_module failure"
    fail=1
fi

if grep -aE -q "kmod_linux: init returned -[0-9]+" "$LOG"; then
    echo "[test_r8169_ko] FAIL: a module's init_module returned non-zero"
    grep -aE "kmod_linux: init returned" "$LOG"
    fail=1
fi

if grep -aF -q "unresolved external symbol" "$LOG"; then
    echo "[test_r8169_ko] FAIL: unresolved external symbol reported"
    grep -aF "unresolved external symbol" "$LOG"
    fail=1
fi
if grep -aF -q "unknown reloc type" "$LOG"; then
    echo "[test_r8169_ko] FAIL: unknown reloc type reported"
    grep -aF "unknown reloc type" "$LOG"
    fail=1
fi

if ! grep -aE -q "kmod_linux: name=r8169( |\$)" "$LOG"; then
    echo "[test_r8169_ko] FAIL: r8169.ko was not loaded (no 'kmod_linux: name=r8169' marker)"
    fail=1
else
    echo "[test_r8169_ko] OK: kmod_linux: name=r8169"
fi

RELOC_LINE=$(awk '/kmod_linux: name=r8169$|kmod_linux: name=r8169 /,/kmod_linux: init returned/' "$LOG" | grep -aE 'kmod_linux: relocations applied=' | tail -1)
if [ -z "$RELOC_LINE" ]; then
    echo "[test_r8169_ko] FAIL: no relocation summary found between name=r8169 and init returned"
    fail=1
else
    SKIPPED=$(echo "$RELOC_LINE" | grep -oE 'skipped=[0-9]+' | cut -d= -f2)
    APPLIED=$(echo "$RELOC_LINE" | grep -oE 'applied=[0-9]+' | cut -d= -f2)
    if [ "${SKIPPED:-1}" -eq 0 ]; then
        echo "[test_r8169_ko] OK: relocations applied=$APPLIED skipped=0"
    else
        echo "[test_r8169_ko] FAIL: r8169.ko had skipped=${SKIPPED} relocations (applied=${APPLIED})"
        fail=1
    fi
fi

INIT_LINE=$(awk '/kmod_linux: name=r8169$|kmod_linux: name=r8169 /,EOF' "$LOG" | grep -aE 'kmod_linux: init returned' | head -1)
if [ -z "$INIT_LINE" ]; then
    echo "[test_r8169_ko] FAIL: no 'kmod_linux: init returned' marker after name=r8169"
    fail=1
elif echo "$INIT_LINE" | grep -qE 'init returned 0'; then
    echo "[test_r8169_ko] OK: init_module returned 0 ($INIT_LINE)"
else
    echo "[test_r8169_ko] FAIL: init_module non-zero ($INIT_LINE)"
    fail=1
fi

# pci_register_driver should have walked the bus with a real probe ptr.
R8169_SECTION=$(awk '/kmod_linux: name=r8169$|kmod_linux: name=r8169 /,EOF' "$LOG")
REG_LINE=$(echo "$R8169_SECTION" | grep -aE "\[pci_register_driver\] walking bus" | head -1)
if [ -n "$REG_LINE" ]; then
    if echo "$REG_LINE" | grep -qE 'probe=0x0000000000000000'; then
        echo "[test_r8169_ko] FAIL: pci_register_driver received probe=NULL (driver struct decode bug)"
        echo "  $REG_LINE"
        fail=1
    else
        echo "[test_r8169_ko] OK: pci_register_driver invoked with non-NULL probe ($REG_LINE)"
    fi
else
    echo "[test_r8169_ko] FAIL: pci_register_driver was never invoked"
    fail=1
fi

# Match-against-rtl8139 is informational only; r8169's id_table covers
# the 8139 ID for backward compat but the bus-walk doesn't always match
# (the QEMU rtl8139 stub's class-code differs from a real GbE Realtek).
if echo "$R8169_SECTION" | grep -aE -q "\[pci_register_driver\] MATCH 10ec:"; then
    MATCH_LINE=$(echo "$R8169_SECTION" | grep -aE "\[pci_register_driver\] MATCH 10ec:" | head -1)
    echo "[test_r8169_ko] BONUS: PCI id matched ($MATCH_LINE)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_r8169_ko] FAIL (qemu rc=$rc)"
    echo "[test_r8169_ko] --- full log tail ---"
    tail -120 "$LOG"
    exit 1
fi

echo "[test_r8169_ko] PASS (.ko loaded; relocations clean; init_module returned 0; driver registered)"
