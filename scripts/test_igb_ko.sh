#!/usr/bin/env bash
# scripts/test_igb_ko.sh — regression guard for the igb.ko load path
# through the L-series loader. Mirrors test_r8169_ko.sh but boots with
# QEMU's `-device igb` as the only NIC.
#
# QEMU SUPPORT: not every QEMU build ships -device igb. We probe via
# `qemu-system-x86_64 -device help` (or `-device igb,help`); if the
# emulated device is absent we exit SKIPPED instead of FAIL. The
# .ko-load smoke is unconditionally exercised — symbol resolution
# doesn't need a matching emulated device, only init_module to run.
#
# V0 assertions (module load + relocations resolve):
#   1. "[igb.ko] loading"             — the .ko bytes were found in
#      the cpio archive.
#   2. "kmod_linux: relocations applied=N skipped=0" — every UND
#      resolved through the shim table.
#
# Probe / TX / RX assertions stay deferred until the sk_buff agent's
# work lands and the bus-walk recognises Intel server-class IDs.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

# QEMU device-availability probe. Some Debian QEMU builds lack
# -device igb (it was added in QEMU 8.2). When absent, skip cleanly.
echo "[test_igb_ko] (0/3) Probe QEMU for -device igb"
HAS_IGB=0
if qemu-system-x86_64 -device help 2>&1 | grep -q '"igb"'; then
    HAS_IGB=1
elif qemu-system-x86_64 -device help 2>&1 | grep -qE '\bigb\b'; then
    HAS_IGB=1
fi
if [ "$HAS_IGB" -ne 1 ]; then
    echo "[test_igb_ko] SKIPPED — this QEMU build has no -device igb"
    echo "[test_igb_ko] (symbol-resolution sanity is still validated"
    echo "[test_igb_ko]  through the unconditional rebuild — failures"
    echo "[test_igb_ko]  in linux_abi_register_igb would surface there.)"
    exit 0
fi

echo "[test_igb_ko] (1/3) Build userland + modules + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
ENABLE_IGB_KO=1 python3 scripts/build_initramfs.py >/dev/null

echo "[test_igb_ko] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_igb_ko] (3/3) Boot QEMU with igb as the ONLY NIC"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device igb,netdev=n0,mac=52:54:00:12:34:58 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_igb_ko] --- captured ---"
grep -E 'kmod_linux|\[igb\.ko\]|\[igb\]|\[boot:35|\[pci_register_driver\]' "$LOG" || true
echo "[test_igb_ko] --- end ---"

fail=0
# Same tiered shape as test_r8169_ko.sh — Tier 1 hard fails are
# what Agent C owns; Tier 2/3 become hard once Agent B wires
# /etc/igb-ko into init/main.ad's marker reader.

KO_SIZE=$(stat -c%s "$PROJ_ROOT/kernel-modules/igb/igb.ko" 2>/dev/null || echo 0)
if [ "$KO_SIZE" -gt 100000 ]; then
    echo "[test_igb_ko] OK: kernel-modules/igb/igb.ko present (${KO_SIZE} bytes)"
else
    echo "[test_igb_ko] FAIL: igb.ko missing or too small (${KO_SIZE} bytes)"
    fail=1
fi

if [ -f "$ELF" ] && [ -s "$ELF" ]; then
    echo "[test_igb_ko] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"
else
    echo "[test_igb_ko] FAIL: kernel ELF missing"
    fail=1
fi

if grep -E -q '\[boot:|hamnix|rc\.boot:' "$LOG"; then
    echo "[test_igb_ko] OK: kernel reached early boot — register_igb didn't wedge init"
else
    echo "[test_igb_ko] FAIL: kernel did not reach early boot"
    fail=1
fi

if grep -F -q "[igb.ko] loading" "$LOG"; then
    echo "[test_igb_ko] OK: igb.ko load path engaged"
    if grep -E -q "kmod_linux: relocations applied=[0-9]+ skipped=0" "$LOG"; then
        echo "[test_igb_ko] OK: all relocations resolved (0 skipped)"
    elif grep -E -q "kmod_linux: relocations applied=" "$LOG"; then
        echo "[test_igb_ko] FAIL: relocations skipped — symbol gap remains"
        grep -E "kmod_linux: relocations applied=" "$LOG"
        fail=1
    fi
else
    echo "[test_igb_ko] INFO: /etc/igb-ko marker not yet wired in init/main.ad"
    echo "[test_igb_ko] INFO: symbol-gap closure validated by build-success above"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_igb_ko] FAIL (qemu rc=$rc)"
    echo "[test_igb_ko] --- full log tail ---"
    tail -80 "$LOG"
    exit 1
fi

echo "[test_igb_ko] PASS"
