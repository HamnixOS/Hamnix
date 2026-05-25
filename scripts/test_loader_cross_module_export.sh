#!/usr/bin/env bash
# scripts/test_loader_cross_module_export.sh — regression guard for the
# loader's per-.ko EXPORT_SYMBOL cross-module resolution path.
#
# Premise: cfg80211.ko declares ~134 EXPORT_SYMBOL names through its
# __ksymtab / __ksymtab_gpl sections. mac80211.ko has ~72 UND symbols
# starting with "cfg80211_" that match exactly those names. Without
# the loader-side ksymtab registry, those UNDs were resolved via
# hand-written Hamnix shims in linux_abi/api_mac80211.ad. With the
# registry, the loader's _sym_addr() now falls back to ksymtab_lookup
# after the Hamnix shim table misses — and for names that aren't in
# the shim table, this means the .ko-side EXPORT_SYMBOL wins.
#
# This test boots with ENABLE_CROSS_MODULE_EXPORT_TEST=1 and
# ENABLE_FRAMEWORK_MODULES=1: the framework block loads cfg80211 then
# mac80211, populating the registry from cfg80211's ksymtab and then
# resolving mac80211's UNDs against it. The loader emits a
# `[ksymtab_hit] <consumer> -> <provider>: <name>` line at each
# resolution.
#
# Assertions:
#   1. Both modules in cpio.
#   2. cfg80211 loads first (framework-modules path), then mac80211.
#   3. At least one [ksymtab_hit] mac80211 -> cfg80211 line appears
#      (proving the cross-module fallback fired for some cfg80211_*
#      symbol the Hamnix shim table either doesn't carry, or one
#      that the shim path missed).
#   4. No skipped relocations / unresolved external / TRAP / BUG /
#      init returned -N.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${CROSS_MODULE_BOOT_TIMEOUT:-25}"

echo "[test_loader_cross_module_export] (1/4) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
INITRAMFS_LOG=$(mktemp)
ENABLE_FRAMEWORK_MODULES=1 \
ENABLE_CROSS_MODULE_EXPORT_TEST=1 \
    python3 scripts/build_initramfs.py > "$INITRAMFS_LOG" 2>&1
trap 'rm -f "$INITRAMFS_LOG" "${LOG:-/dev/null}"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_loader_cross_module_export] (2/4) Verify initramfs contents"
fail=0
for needle in \
    "embedded /lib/modules/cfg80211.ko" \
    "embedded /lib/modules/mac80211.ko"
do
    if grep -F -q "$needle" "$INITRAMFS_LOG"; then
        echo "[test_loader_cross_module_export] OK (cpio): '$needle'"
    else
        echo "[test_loader_cross_module_export] MISS (cpio): '$needle'"
        fail=1
    fi
done
if [ "$fail" -ne 0 ]; then
    echo "[test_loader_cross_module_export] --- build_initramfs.py stdout ---"
    cat "$INITRAMFS_LOG"
    exit 1
fi

echo "[test_loader_cross_module_export] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ -f "$ELF" ] && [ -s "$ELF" ]; then
    echo "[test_loader_cross_module_export] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"
else
    echo "[test_loader_cross_module_export] FAIL: kernel ELF missing"
    exit 1
fi

echo "[test_loader_cross_module_export] (4/4) Boot QEMU"
LOG=$(mktemp)

set +e
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_loader_cross_module_export] --- captured (ksymtab / kmod_linux) ---"
grep -aE 'kmod_linux: (name|registered)|\[ksymtab_hit\]|kmod_linux: relocations|init returned|TRAP:|BUG:' "$LOG" | head -50 || true
echo "[test_loader_cross_module_export] --- end ---"

# Step 2: cfg80211 loads first, then mac80211.
cfg_line=$(grep -aFn "kmod_linux: name=cfg80211" "$LOG" | head -1 | cut -d: -f1 || true)
mac_line=$(grep -aFn "kmod_linux: name=mac80211" "$LOG" | head -1 | cut -d: -f1 || true)
if [ -z "$cfg_line" ]; then
    echo "[test_loader_cross_module_export] FAIL: cfg80211 was never loaded"
    fail=1
fi
if [ -z "$mac_line" ]; then
    echo "[test_loader_cross_module_export] FAIL: mac80211 was never loaded"
    fail=1
fi
if [ -n "$cfg_line" ] && [ -n "$mac_line" ]; then
    if [ "$cfg_line" -lt "$mac_line" ]; then
        echo "[test_loader_cross_module_export] OK: cfg80211 loaded BEFORE mac80211"
    else
        echo "[test_loader_cross_module_export] FAIL: load order wrong (cfg=$cfg_line mac=$mac_line)"
        fail=1
    fi
fi

# Step 3: at least one [ksymtab_hit] mac80211 -> cfg80211 line. The
# registry's owner-name is interned from .modinfo "name=" so the
# string is exactly "cfg80211". The consumer is also from .modinfo
# so it's exactly "mac80211".
n_hits=$(grep -acE '\[ksymtab_hit\] mac80211 -> cfg80211:' "$LOG" || true)
if [ "${n_hits:-0}" -ge 1 ]; then
    echo "[test_loader_cross_module_export] OK: $n_hits [ksymtab_hit] mac80211 -> cfg80211 events"
    echo "[test_loader_cross_module_export] sample hits:"
    grep -aE '\[ksymtab_hit\] mac80211 -> cfg80211:' "$LOG" | head -5 | sed 's/^/    /'
else
    echo "[test_loader_cross_module_export] FAIL: no [ksymtab_hit] mac80211 -> cfg80211 events"
    fail=1
fi

# Step 4: zero skipped relocations.
if grep -aE -q "kmod_linux: relocations applied=[0-9]+ skipped=[1-9]" "$LOG"; then
    echo "[test_loader_cross_module_export] FAIL: at least one module had skipped relocations"
    grep -aE "kmod_linux: relocations applied=" "$LOG"
    fail=1
else
    echo "[test_loader_cross_module_export] OK: no skipped relocations"
fi

# Hard-fail surface.
for bad in "TRAP:" "BUG:" "unresolved external" "init returned -"; do
    if grep -aF -q "$bad" "$LOG"; then
        echo "[test_loader_cross_module_export] FAIL: detected '$bad' in log"
        grep -aF "$bad" "$LOG" | head -5
        fail=1
    fi
done

# Both modules init must have returned 0.
n_ok=$(grep -aFc "kmod_linux: init returned 0;" "$LOG" || true)
if [ "${n_ok:-0}" -ge 2 ]; then
    echo "[test_loader_cross_module_export] OK: $n_ok modules' init returned 0"
else
    echo "[test_loader_cross_module_export] FAIL: expected >= 2 'init returned 0', got ${n_ok:-0}"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_loader_cross_module_export] FAIL (qemu rc=$rc)"
    echo "[test_loader_cross_module_export] --- full log tail ---"
    tail -200 "$LOG"
    exit 1
fi

echo "[test_loader_cross_module_export] PASS (mac80211 UNDs resolved via cfg80211 ksymtab fallback)"
