#!/usr/bin/env bash
# scripts/test_keymap.sh — task #178, selectable international keyboard
# layouts.
#
# Boots the kernel once with /etc/keymap-test planted
# (ENABLE_KEYMAP_TEST=1); init/main.ad at boot:37.km calls
# keymap_selftest() (drivers/input/atkbd.ad), which drives the
# scancode->char translator directly (NO QEMU key injection) with a
# fixed sequence of Set-1 make-codes under each of the US / DE / FR
# layouts and asserts the produced characters match that layout.
#
# UNFORGEABLE assertions the kernel self-test prints as [keymap] lines,
# all of which this script requires:
#   * physical 'Y' key (Set-1 0x15) -> 'y' (121) under US
#   * the SAME key -> 'z' (122) under DE  (the QWERTZ Y/Z swap)
#   * physical 'Q' key (Set-1 0x10) -> 'q' (113) under US
#   * the SAME key -> 'a' (97) under FR   (the AZERTY A/Q swap)
#   * AltGr+Q under DE -> '@' (64)        (level-3 / AltGr really maps)
#   * AltGr+a-grave under FR -> '@' (64)
#   * Shift+'2' -> '@' (64) under US, '"' (34) under DE (shifted symbol)
#   * switching back to US restores 'y' (no stale-table leak)
#   * the [keymap] PASS banner
#
# Asserting that the SAME make-code yields DIFFERENT characters under
# different layouts proves the runtime layout switch really re-routes
# translation — not a hardcoded single map.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_keymap] PASS
# Fail marker:  [test_keymap] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_keymap] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_keymap] (2/3) Build kernel with /etc/keymap-test marker"
INIT_ELF=build/user/init.elf ENABLE_KEYMAP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_keymap] (3/3) Boot QEMU and run the keymap self-test"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_keymap] --- keymap self-test output ---"
grep -E "\[keymap\]" "$LOG" || true
echo "[test_keymap] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_keymap] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -qF "[keymap] FAIL" "$LOG"; then
    echo "[test_keymap] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_keymap] PASS: $label"
    else
        echo "[test_keymap] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "US 'Y' key gives 'y' (121)"        "[keymap] US 'Y' key -> 121 OK"
check "US 'Q' key gives 'q' (113)"        "[keymap] US 'Q' key -> 113 OK"
check "US Shift+2 gives '@' (64)"         "[keymap] US Shift+2 -> 64 OK"
check "DE 'Y' key gives 'z' (122)"        "[keymap] DE 'Y' key (QWERTZ) -> 122 OK"
check "DE AltGr+Q gives '@' (64)"         "[keymap] DE AltGr+Q -> 64 OK"
check "DE Shift+2 gives '\"' (34)"         "[keymap] DE Shift+2 -> 34 OK"
check "FR 'Q' key gives 'a' (97)"         "[keymap] FR 'Q' key (AZERTY) -> 97 OK"
check "FR AltGr+a-grave gives '@' (64)"   "[keymap] FR AltGr+a-grave -> 64 OK"
check "US restored 'Y' gives 'y' (121)"   "[keymap] US restored 'Y' -> 121 OK"
check "keymap self-test PASS banner"      "[keymap] PASS: layout self-test complete"

if [ "$fail" -ne 0 ]; then
    echo "[test_keymap] FAIL"
    exit 1
fi

echo "[test_keymap] PASS — US/DE/FR layouts each translate the same make-codes to their own characters, AltGr level-3 maps, and the runtime switch round-trips"
