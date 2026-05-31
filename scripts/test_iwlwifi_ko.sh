#!/usr/bin/env bash
# scripts/test_iwlwifi_ko.sh — regression guard for the iwlwifi.ko
# load path through the L-series loader.
#
# iwlwifi.ko is Intel's wireless PCI driver — it depends on cfg80211
# (declared in modinfo) and uses a handful of mac80211 ieee80211_*
# helpers (resolved via the mac80211 shim batch). The test boots QEMU
# with both ENABLE_FRAMEWORK_MODULES=1 (pre-loads cfg80211 + mac80211)
# and ENABLE_IWLWIFI_KO=1 (triggers init/main.ad's boot:35.W load of
# iwlwifi.ko from /lib/modules/iwlwifi.ko). The 18-entry api_iwlwifi.ad
# shim batch closes the remaining UND gap.
#
# V0 assertions:
#   1. /lib/modules/iwlwifi.ko is in the cpio archive.
#   2. cfg80211.ko and mac80211.ko load first (prerequisite).
#   3. "[iwlwifi.ko] kmod_linux_load OK" appears in dmesg.
#   4. No `kmod_linux: relocations applied=X skipped=N>0` line.
#   5. No "unresolved external symbol", "TRAP:", "BUG:", or
#      "init returned -N" line.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${IWLWIFI_BOOT_TIMEOUT:-30}"

echo "[test_iwlwifi_ko] (1/4) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
INITRAMFS_LOG=$(mktemp)
ENABLE_FRAMEWORK_MODULES=1 ENABLE_IWLWIFI_KO=1 python3 scripts/build_initramfs.py \
    > "$INITRAMFS_LOG" 2>&1
trap 'rm -f "$INITRAMFS_LOG" "${LOG:-/dev/null}"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_iwlwifi_ko] (2/4) Verify initramfs contents"
fail=0
for needle in \
    "embedded /lib/modules/cfg80211.ko" \
    "embedded /lib/modules/mac80211.ko" \
    "embedded /lib/modules/iwlwifi.ko"
do
    if grep -F -q "$needle" "$INITRAMFS_LOG"; then
        echo "[test_iwlwifi_ko] OK (cpio): '$needle'"
    else
        echo "[test_iwlwifi_ko] MISS (cpio): '$needle'"
        fail=1
    fi
done
if [ "$fail" -ne 0 ]; then
    echo "[test_iwlwifi_ko] --- build_initramfs.py stdout ---"
    cat "$INITRAMFS_LOG"
    exit 1
fi

# Tier-1: .ko file presence
KO_PATH="$PROJ_ROOT/kernel-modules/iwlwifi/iwlwifi.ko"
KO_SIZE=$(stat -c%s "$KO_PATH" 2>/dev/null || echo 0)
if [ "$KO_SIZE" -gt 100000 ]; then
    echo "[test_iwlwifi_ko] OK: iwlwifi.ko present (${KO_SIZE} bytes)"
else
    echo "[test_iwlwifi_ko] FAIL: iwlwifi.ko missing or too small (${KO_SIZE} bytes)"
    exit 1
fi

echo "[test_iwlwifi_ko] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ -f "$ELF" ] && [ -s "$ELF" ]; then
    echo "[test_iwlwifi_ko] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"
else
    echo "[test_iwlwifi_ko] FAIL: kernel ELF missing"
    exit 1
fi

echo "[test_iwlwifi_ko] (4/4) Boot QEMU and watch for iwlwifi.ko load"
LOG=$(mktemp)

set +e
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_iwlwifi_ko] --- captured (boot:35 / cfg80211 / mac80211 / iwlwifi / kmod_linux) ---"
grep -aE '\[boot:35|\[cfg80211\.ko\]|\[mac80211\.ko\]|\[iwlwifi\.ko\]|kmod_linux: vermagic|kmod_linux: relocations|kmod_linux: init_module|kmod_linux: init returned' "$LOG" || true
echo "[test_iwlwifi_ko] --- end ---"

# Boot sanity: kernel reached linux_abi_exports_init
if grep -aE -q '\[boot:35\]|linux_abi_exports_init|hamnix' "$LOG"; then
    echo "[test_iwlwifi_ko] OK: kernel reached linux_abi_exports_init"
else
    echo "[test_iwlwifi_ko] FAIL: kernel did not reach linux_abi_exports_init"
    fail=1
fi

# Tier-2: framework-modules marker engaged
if grep -aF -q "[boot:35.F] framework modules" "$LOG"; then
    echo "[test_iwlwifi_ko] OK: framework-modules marker honored"
else
    echo "[test_iwlwifi_ko] MISS: framework-modules block did not engage"
    fail=1
fi

# cfg80211.ko must load first (iwlwifi depends on it)
if grep -aF -q "[cfg80211.ko] kmod_linux_load OK" "$LOG"; then
    echo "[test_iwlwifi_ko] OK: cfg80211.ko loaded (prerequisite)"
else
    echo "[test_iwlwifi_ko] FAIL: cfg80211.ko did not load"
    fail=1
fi

# mac80211.ko must load second
if grep -aF -q "[mac80211.ko] kmod_linux_load OK" "$LOG"; then
    echo "[test_iwlwifi_ko] OK: mac80211.ko loaded (prerequisite)"
else
    echo "[test_iwlwifi_ko] FAIL: mac80211.ko did not load"
    fail=1
fi

# iwlwifi.ko harvest target
if grep -aF -q "[iwlwifi.ko] loading" "$LOG"; then
    echo "[test_iwlwifi_ko] OK: iwlwifi.ko found in cpio + loading"
else
    echo "[test_iwlwifi_ko] FAIL: iwlwifi.ko not loaded"
    fail=1
fi

if grep -aF -q "[iwlwifi.ko] kmod_linux_load OK" "$LOG"; then
    echo "[test_iwlwifi_ko] OK: kmod_linux_load returned success"
else
    echo "[test_iwlwifi_ko] FAIL: kmod_linux_load did not return OK"
    fail=1
fi

# Tier-3 strict: zero skipped relocations across all modules
if grep -aE -q "kmod_linux: relocations applied=[0-9]+ skipped=[1-9]" "$LOG"; then
    echo "[test_iwlwifi_ko] FAIL: at least one module had skipped relocations"
    grep -aE "kmod_linux: relocations applied=" "$LOG"
    fail=1
fi

# Tier-3 strict: any "unresolved external symbol" line is a hard fail.
if grep -aF -q "unresolved external symbol" "$LOG"; then
    echo "[test_iwlwifi_ko] FAIL: unresolved external symbol reported"
    grep -aF "unresolved external symbol" "$LOG"
    fail=1
fi

# Tier-3 strict: CPU traps / kernel BUGs during boot are a hard fail.
if grep -aE -q "^TRAP:|^\[[0-9]+\] TRAP:|^BUG:|^\[[0-9]+\] BUG:" "$LOG"; then
    echo "[test_iwlwifi_ko] FAIL: TRAP/BUG reported during boot"
    grep -aE "TRAP:|BUG:" "$LOG"
    fail=1
fi

# Tier-3 strict: init_module must return 0 for every loaded module.
if grep -aE -q "kmod_linux: init returned -[0-9]+" "$LOG"; then
    echo "[test_iwlwifi_ko] FAIL: a module's init_module returned non-zero"
    grep -aE "kmod_linux: init returned" "$LOG"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_iwlwifi_ko] FAIL (qemu rc=$rc)"
    echo "[test_iwlwifi_ko] --- full log tail ---"
    tail -150 "$LOG"
    exit 1
fi

echo "[test_iwlwifi_ko] PASS (cfg80211.ko + mac80211.ko + iwlwifi.ko load via framework-modules + harvest path)"
