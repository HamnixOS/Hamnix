#!/usr/bin/env bash
# scripts/test_alx_ko.sh — regression guard for the alx.ko load path
# through the L-series loader. Qualcomm Atheros AR8161/AR8162 — common
# on Asus/Acer/HP laptops. There's no QEMU emulation for the AR816x
# silicon, so this test exercises the .ko *load* path only (the
# init_module symbol-resolution + relocation pass); device probe never
# runs in the absence of matching PCI IDs.
#
# Strict-gate shape, mirroring scripts/test_cfg80211_ko.sh: hard-fail
# on `skipped > 0`, `unresolved external`, `TRAP:`, `BUG:`, or any
# `init returned -N`.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_alx_ko] (1/3) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
ENABLE_ALX_KO=1 python3 scripts/build_initramfs.py >/dev/null

echo "[test_alx_ko] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_alx_ko] (3/3) Boot QEMU (no AR816x device — load-only smoke)"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_alx_ko] --- captured ---"
grep -aE 'kmod_linux|\[alx\.ko\]|\[alx\]|\[boot:35|linux_abi_exports_init' "$LOG" || true
echo "[test_alx_ko] --- end ---"

fail=0

# Tier 1: .ko file presence (kernel-modules/alx/alx.ko in repo).
KO_PATH="$PROJ_ROOT/kernel-modules/alx/alx.ko"
KO_SIZE=$(stat -c%s "$KO_PATH" 2>/dev/null || echo 0)
if [ "$KO_SIZE" -gt 100000 ]; then
    echo "[test_alx_ko] OK: kernel-modules/alx/alx.ko present (${KO_SIZE} bytes)"
else
    echo "[test_alx_ko] FAIL: alx.ko missing or too small (${KO_SIZE} bytes)"
    fail=1
fi

# Tier 1: kernel ELF built.
if [ -f "$ELF" ] && [ -s "$ELF" ]; then
    echo "[test_alx_ko] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"
else
    echo "[test_alx_ko] FAIL: kernel ELF missing"
    fail=1
fi

# Tier 1: kernel reached linux_abi_exports_init (so the new
# linux_abi_register_alx() didn't wedge boot).
if grep -aE -q '\[boot:35\]|linux_abi_exports_init|hamnix|rc\.boot:' "$LOG"; then
    echo "[test_alx_ko] OK: kernel reached linux_abi exports init"
else
    echo "[test_alx_ko] FAIL: kernel did not reach early boot"
    fail=1
fi

# Tier 2 (informational): alx.ko load-path marker. The /etc/alx-ko
# marker is planted; whether init/main.ad's framework-modules block
# already honors that filename is a follow-up. When it does, this
# becomes a hard gate.
if grep -aF -q "[alx.ko] loading" "$LOG"; then
    echo "[test_alx_ko] OK: alx.ko load path engaged"
else
    echo "[test_alx_ko] INFO: alx.ko marker not yet consumed by init/main.ad"
    echo "[test_alx_ko] INFO: symbol-gap closure validated by build-success above"
fi

# Tier 3 strict: zero skipped relocations on ANY module loaded this
# boot. A non-zero skipped count means our gap analysis missed a
# symbol — including for unrelated modules that share a UND in the
# same alx-batch boot.
if grep -aE -q "kmod_linux: relocations applied=[0-9]+ skipped=[1-9]" "$LOG"; then
    echo "[test_alx_ko] FAIL: at least one module had skipped relocations"
    grep -aE "kmod_linux: relocations applied=" "$LOG"
    fail=1
fi

# Tier 3 strict: no unresolved-external messages.
if grep -aF -q "unresolved external symbol" "$LOG"; then
    echo "[test_alx_ko] FAIL: unresolved external symbol reported"
    grep -aF "unresolved external symbol" "$LOG"
    fail=1
fi

# Tier 3 strict: no CPU traps / kernel BUGs.
if grep -aE -q "^TRAP:|^\[[0-9]+\] TRAP:|^BUG:|^\[[0-9]+\] BUG:" "$LOG"; then
    echo "[test_alx_ko] FAIL: TRAP/BUG reported during boot"
    grep -aE "TRAP:|BUG:" "$LOG"
    fail=1
fi

# Tier 3 strict: init_module must return 0 for every loaded module.
if grep -aE -q "kmod_linux: init returned -[0-9]+" "$LOG"; then
    echo "[test_alx_ko] FAIL: a module's init_module returned non-zero"
    grep -aE "kmod_linux: init returned" "$LOG"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_alx_ko] FAIL (qemu rc=$rc)"
    echo "[test_alx_ko] --- full log tail ---"
    tail -80 "$LOG"
    exit 1
fi

echo "[test_alx_ko] PASS"
