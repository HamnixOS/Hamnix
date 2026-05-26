#!/usr/bin/env bash
# scripts/test_sky2_ko.sh — regression guard for the sky2.ko load path
# through the L-series loader. Marvell Yukon-2 — common on Lenovo
# ThinkPads + some desktops. No QEMU Yukon emulation, so this test
# exercises the .ko *load* path only — init_module symbol-resolution +
# relocation pass plus the __pci_register_driver invocation. Probe never
# runs (no matching ID on the QEMU bus).
#
# Strategy: boot hamsh as /init, drive `insmod /lib/modules/sky2.ko`
# from the shell, snapshot the printk ring via `dmesg`, and assert the
# loader ran cleanly.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

KO_PATH="$PROJ_ROOT/kernel-modules/sky2/sky2.ko"
KO_SIZE=$(stat -c%s "$KO_PATH" 2>/dev/null || echo 0)
if [ "$KO_SIZE" -lt 100000 ]; then
    echo "[test_sky2_ko] FAIL: sky2.ko missing or too small (${KO_SIZE} bytes)"
    exit 1
fi
echo "[test_sky2_ko] OK: sky2.ko present (${KO_SIZE} bytes)"

UND_SYMS=$(nm -u "$KO_PATH" 2>/dev/null | awk '{print $2}' | sort -u)
MISSING=""
for sym in $UND_SYMS; do
    if ! grep -rq "_add_export(\"${sym}\"" linux_abi/ 2>/dev/null; then
        MISSING+=" $sym"
    fi
done
TOTAL_UND=$(echo "$UND_SYMS" | wc -w)
TOTAL_MISSING=$(echo "$MISSING" | wc -w)
echo "[test_sky2_ko] UND total=$TOTAL_UND missing=$TOTAL_MISSING"
if [ -n "$MISSING" ]; then
    for s in $MISSING; do echo "  - $s"; done
fi

echo "[test_sky2_ko] (1/3) Build userland + modules + initramfs (hamsh as /init)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
ENABLE_SKY2_KO=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_sky2_ko] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s "$ELF" ]; then
    echo "[test_sky2_ko] FAIL: kernel ELF missing"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
    exit 1
fi
echo "[test_sky2_ko] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"

echo "[test_sky2_ko] (3/3) Boot QEMU; insmod via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
(
    sleep 3
    printf 'insmod /lib/modules/sky2.ko\n'
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

echo "[test_sky2_ko] --- captured (kmod / sky2 / probe) ---"
grep -aE 'kmod_linux: (name=|relocations applied|init returned|unresolved external|unknown reloc)|\[sky2\.ko\]|\[sky2\]|\[pci_register_driver\]|insmod:' "$LOG" | head -60 || true
echo "[test_sky2_ko] --- end ---"

fail=0

if grep -aE -q "PANIC|panic:|^TRAP:|^\[[0-9]+\] TRAP:|^BUG:|^\[[0-9]+\] BUG:|invalid opcode" "$LOG"; then
    echo "[test_sky2_ko] FAIL: TRAP / BUG / PANIC reported"
    grep -aE "PANIC|panic:|TRAP:|BUG:|invalid opcode" "$LOG"
    fail=1
fi

if grep -aE -q "insmod: init_module failed" "$LOG"; then
    echo "[test_sky2_ko] FAIL: userspace insmod reported init_module failure"
    fail=1
fi

if grep -aE -q "kmod_linux: init returned -[0-9]+" "$LOG"; then
    echo "[test_sky2_ko] FAIL: a module's init_module returned non-zero"
    grep -aE "kmod_linux: init returned" "$LOG"
    fail=1
fi

if grep -aF -q "unresolved external symbol" "$LOG"; then
    echo "[test_sky2_ko] FAIL: unresolved external symbol reported"
    grep -aF "unresolved external symbol" "$LOG"
    fail=1
fi
if grep -aF -q "unknown reloc type" "$LOG"; then
    echo "[test_sky2_ko] FAIL: unknown reloc type reported"
    grep -aF "unknown reloc type" "$LOG"
    fail=1
fi

if ! grep -aE -q "kmod_linux: name=sky2( |\$)" "$LOG"; then
    echo "[test_sky2_ko] FAIL: sky2.ko was not loaded (no 'kmod_linux: name=sky2' marker)"
    fail=1
else
    echo "[test_sky2_ko] OK: kmod_linux: name=sky2"
fi

RELOC_LINE=$(awk '/kmod_linux: name=sky2$|kmod_linux: name=sky2 /,/kmod_linux: init returned/' "$LOG" | grep -aE 'kmod_linux: relocations applied=' | tail -1)
if [ -z "$RELOC_LINE" ]; then
    echo "[test_sky2_ko] FAIL: no relocation summary found between name=sky2 and init returned"
    fail=1
else
    SKIPPED=$(echo "$RELOC_LINE" | grep -oE 'skipped=[0-9]+' | cut -d= -f2)
    APPLIED=$(echo "$RELOC_LINE" | grep -oE 'applied=[0-9]+' | cut -d= -f2)
    if [ "${SKIPPED:-1}" -eq 0 ]; then
        echo "[test_sky2_ko] OK: relocations applied=$APPLIED skipped=0"
    else
        echo "[test_sky2_ko] FAIL: sky2.ko had skipped=${SKIPPED} relocations (applied=${APPLIED})"
        fail=1
    fi
fi

INIT_LINE=$(awk '/kmod_linux: name=sky2$|kmod_linux: name=sky2 /,EOF' "$LOG" | grep -aE 'kmod_linux: init returned' | head -1)
if [ -z "$INIT_LINE" ]; then
    echo "[test_sky2_ko] FAIL: no 'kmod_linux: init returned' marker after name=sky2"
    fail=1
elif echo "$INIT_LINE" | grep -qE 'init returned 0'; then
    echo "[test_sky2_ko] OK: init_module returned 0 ($INIT_LINE)"
else
    echo "[test_sky2_ko] FAIL: init_module non-zero ($INIT_LINE)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_sky2_ko] FAIL (qemu rc=$rc)"
    echo "[test_sky2_ko] --- full log tail ---"
    tail -120 "$LOG"
    exit 1
fi

echo "[test_sky2_ko] PASS (.ko loaded; relocations clean; init_module returned 0)"
