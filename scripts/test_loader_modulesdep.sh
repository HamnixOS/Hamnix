#!/usr/bin/env bash
# scripts/test_loader_modulesdep.sh — regression guard for the
# in-kernel modules.dep parser (kernel/modules_dep.ad).
#
# The premise: dispatching mac80211.ko first should auto-load
# cfg80211.ko before it (cfg80211 is declared as a dep in
# modules.dep). This test boots WITHOUT ENABLE_FRAMEWORK_MODULES
# (which would pre-load both modules and bypass the dep walker)
# and instead sets ENABLE_MODULESDEP_TEST=1, which makes
# init/main.ad's [boot:35.D] block dispatch mac80211 via
# modules_dep_load_with_deps(). The walker recursively loads
# cfg80211 first, then mac80211.
#
# Assertions:
#   1. /lib/modules/modules.dep is in the cpio (visible in
#      build_initramfs.py stdout).
#   2. The boot:35.D marker fires (modules.dep test block entered).
#   3. cfg80211 gets loaded FIRST (its kmod_linux_load OK appears
#      before mac80211's).
#   4. Both loads succeed (kmod_linux_load OK for cfg80211 and
#      mac80211).
#   5. No skipped relocations (any unresolved external is a hard
#      fail of the shim closure / dep load order).
#   6. No TRAP / BUG / init returned -N.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${MODULESDEP_BOOT_TIMEOUT:-25}"

echo "[test_loader_modulesdep] (1/4) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
INITRAMFS_LOG=$(mktemp)
ENABLE_MODULESDEP_TEST=1 python3 scripts/build_initramfs.py \
    > "$INITRAMFS_LOG" 2>&1
trap 'rm -f "$INITRAMFS_LOG" "${LOG:-/dev/null}"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Step 1: cpio carries the dep table.
echo "[test_loader_modulesdep] (2/4) Verify initramfs contents"
fail=0
for needle in \
    "embedded /lib/modules/modules.dep" \
    "embedded /lib/modules/cfg80211.ko" \
    "embedded /lib/modules/mac80211.ko"
do
    if grep -F -q "$needle" "$INITRAMFS_LOG"; then
        echo "[test_loader_modulesdep] OK (cpio): '$needle'"
    else
        echo "[test_loader_modulesdep] MISS (cpio): '$needle'"
        fail=1
    fi
done
if [ "$fail" -ne 0 ]; then
    echo "[test_loader_modulesdep] --- build_initramfs.py stdout ---"
    cat "$INITRAMFS_LOG"
    exit 1
fi

echo "[test_loader_modulesdep] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ -f "$ELF" ] && [ -s "$ELF" ]; then
    echo "[test_loader_modulesdep] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"
else
    echo "[test_loader_modulesdep] FAIL: kernel ELF missing"
    exit 1
fi

echo "[test_loader_modulesdep] (4/4) Boot QEMU and watch dep-walker"
LOG=$(mktemp)

set +e
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_loader_modulesdep] --- captured (boot:35.D / modules_dep / kmod_linux) ---"
grep -aE '\[boot:35\.D|\[modules_dep|kmod_linux: name=|kmod_linux: relocations|kmod_linux: init returned|TRAP:|BUG:' "$LOG" || true
echo "[test_loader_modulesdep] --- end ---"

# Step 2: modules.dep block engaged.
if grep -aF -q "[boot:35.D] modules.dep test:" "$LOG"; then
    echo "[test_loader_modulesdep] OK: modules.dep test block engaged"
else
    echo "[test_loader_modulesdep] FAIL: [boot:35.D] block did not fire"
    fail=1
fi

# Step 3: cfg80211 loads BEFORE mac80211 (line-number ordering check).
cfg_line=$(grep -aFn "kmod_linux: name=cfg80211" "$LOG" | head -1 | cut -d: -f1 || true)
mac_line=$(grep -aFn "kmod_linux: name=mac80211" "$LOG" | head -1 | cut -d: -f1 || true)

if [ -z "$cfg_line" ]; then
    echo "[test_loader_modulesdep] FAIL: cfg80211 was never loaded (no 'kmod_linux: name=cfg80211')"
    fail=1
fi
if [ -z "$mac_line" ]; then
    echo "[test_loader_modulesdep] FAIL: mac80211 was never loaded (no 'kmod_linux: name=mac80211')"
    fail=1
fi
if [ -n "$cfg_line" ] && [ -n "$mac_line" ]; then
    if [ "$cfg_line" -lt "$mac_line" ]; then
        echo "[test_loader_modulesdep] OK: cfg80211 loaded BEFORE mac80211 (lines $cfg_line < $mac_line)"
    else
        echo "[test_loader_modulesdep] FAIL: cfg80211 (line $cfg_line) NOT before mac80211 (line $mac_line)"
        fail=1
    fi
fi

# Step 4: both successes.
n_ok=$(grep -aFc "kmod_linux: init returned 0;" "$LOG" || true)
if [ "${n_ok:-0}" -ge 2 ]; then
    echo "[test_loader_modulesdep] OK: $n_ok modules' init returned 0"
else
    echo "[test_loader_modulesdep] FAIL: expected >= 2 'init returned 0', got ${n_ok:-0}"
    fail=1
fi

# Step 5: zero skipped relocations across the boot.
if grep -aE -q "kmod_linux: relocations applied=[0-9]+ skipped=[1-9]" "$LOG"; then
    echo "[test_loader_modulesdep] FAIL: at least one module had skipped relocations"
    grep -aE "kmod_linux: relocations applied=" "$LOG"
    fail=1
else
    echo "[test_loader_modulesdep] OK: no skipped relocations"
fi

# Step 6: hard failures.
for bad in "TRAP:" "BUG:" "unresolved external" "init returned -"; do
    if grep -aF -q "$bad" "$LOG"; then
        echo "[test_loader_modulesdep] FAIL: detected '$bad' in log"
        grep -aF "$bad" "$LOG" | head -5
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_loader_modulesdep] FAIL (qemu rc=$rc)"
    echo "[test_loader_modulesdep] --- full log tail ---"
    tail -200 "$LOG"
    exit 1
fi

echo "[test_loader_modulesdep] PASS (mac80211 dispatch auto-loaded cfg80211 first via modules.dep)"
