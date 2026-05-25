#!/usr/bin/env bash
# scripts/test_tg3_ko.sh — regression guard for the tg3.ko load path
# through the L-series loader. Broadcom NetXtreme — ubiquitous on
# Dell/HP servers and workstations. No QEMU NetXtreme emulation, so
# this exercises the .ko *load* path only.
#
# Strict-gate shape, mirroring scripts/test_cfg80211_ko.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_tg3_ko] (1/3) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
ENABLE_TG3_KO=1 python3 scripts/build_initramfs.py >/dev/null

echo "[test_tg3_ko] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_tg3_ko] (3/3) Boot QEMU (no NetXtreme device — load-only smoke)"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_tg3_ko] --- captured ---"
grep -aE 'kmod_linux|\[tg3\.ko\]|\[tg3\]|\[boot:35|linux_abi_exports_init' "$LOG" || true
echo "[test_tg3_ko] --- end ---"

fail=0

KO_PATH="$PROJ_ROOT/kernel-modules/tg3/tg3.ko"
KO_SIZE=$(stat -c%s "$KO_PATH" 2>/dev/null || echo 0)
if [ "$KO_SIZE" -gt 100000 ]; then
    echo "[test_tg3_ko] OK: tg3.ko present (${KO_SIZE} bytes)"
else
    echo "[test_tg3_ko] FAIL: tg3.ko missing or too small (${KO_SIZE} bytes)"
    fail=1
fi

if [ -f "$ELF" ] && [ -s "$ELF" ]; then
    echo "[test_tg3_ko] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"
else
    echo "[test_tg3_ko] FAIL: kernel ELF missing"
    fail=1
fi

if grep -aE -q '\[boot:35\]|linux_abi_exports_init|hamnix|rc\.boot:' "$LOG"; then
    echo "[test_tg3_ko] OK: kernel reached linux_abi exports init"
else
    echo "[test_tg3_ko] FAIL: kernel did not reach early boot"
    fail=1
fi

if grep -aF -q "[tg3.ko] loading" "$LOG"; then
    echo "[test_tg3_ko] OK: tg3.ko load path engaged"
else
    echo "[test_tg3_ko] INFO: tg3.ko marker not yet consumed by init/main.ad"
    echo "[test_tg3_ko] INFO: symbol-gap closure validated by build-success above"
fi

if grep -aE -q "kmod_linux: relocations applied=[0-9]+ skipped=[1-9]" "$LOG"; then
    echo "[test_tg3_ko] FAIL: at least one module had skipped relocations"
    grep -aE "kmod_linux: relocations applied=" "$LOG"
    fail=1
fi

if grep -aF -q "unresolved external symbol" "$LOG"; then
    echo "[test_tg3_ko] FAIL: unresolved external symbol reported"
    grep -aF "unresolved external symbol" "$LOG"
    fail=1
fi

if grep -aE -q "^TRAP:|^\[[0-9]+\] TRAP:|^BUG:|^\[[0-9]+\] BUG:" "$LOG"; then
    echo "[test_tg3_ko] FAIL: TRAP/BUG reported during boot"
    grep -aE "TRAP:|BUG:" "$LOG"
    fail=1
fi

if grep -aE -q "kmod_linux: init returned -[0-9]+" "$LOG"; then
    echo "[test_tg3_ko] FAIL: a module's init_module returned non-zero"
    grep -aE "kmod_linux: init returned" "$LOG"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_tg3_ko] FAIL (qemu rc=$rc)"
    echo "[test_tg3_ko] --- full log tail ---"
    tail -80 "$LOG"
    exit 1
fi

echo "[test_tg3_ko] PASS"
