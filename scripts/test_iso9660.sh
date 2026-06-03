#!/usr/bin/env bash
# scripts/test_iso9660.sh — read-only ISO9660 (Rock Ridge) self-test.
#
# Boots the kernel once with /etc/iso9660-test planted
# (ENABLE_ISO9660_TEST=1). build_initramfs.py builds a REAL Rock Ridge
# .iso (scripts/build_iso_fixture.py, via genisoimage/xorriso) and bakes
# it into the cpio at /tests/iso9660/test.iso. init/main.ad at
# boot:37.iso calls iso9660_e2e_selftest() (fs/iso9660.ad), which:
#
#   * loop-attaches the baked .iso as /dev/blk/loop1,
#   * parses the Primary Volume Descriptor at logical sector 16 and
#     records the root directory extent,
#   * lists the root directory and confirms the Rock Ridge long name
#     "a_long_rock_ridge_name.txt" is enumerated (NM SUSP entry),
#   * reads /HELLO.TXT and asserts its bytes are exactly "ISO9660_MARKER",
#   * resolves + reads the Rock Ridge long-name file,
#   * reads /BIG.DAT (4096 bytes = two 2048-byte logical sectors) and
#     asserts the deterministic byte pattern is exact across the sector
#     boundary,
#   * resolves a nested file /sub/NESTED.TXT.
#
# The .iso is built at build time and kept OUT of git.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO.
#
# Pass marker:  [iso9660] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_iso9660] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_iso9660] (2/3) Build kernel with /etc/iso9660-test marker + Rock Ridge ISO fixture"
INIT_ELF=build/user/init.elf ENABLE_ISO9660_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_iso9660] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_iso9660] --- captured (iso9660 lines) ---"
grep -E '\[iso9660\]' "$LOG" || true
echo "[test_iso9660] --- end ---"

fail=0

# rc 124 = timeout, 143 = SIGTERM under host load — treat as flake, not
# a logic failure, IF the PASS marker is absent (handled by check below).
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 143 ]; then
    echo "[test_iso9660] WARN: qemu exited rc=$rc" >&2
fi

if grep -qF "[iso9660] FAIL" "$LOG"; then
    echo "[test_iso9660] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[iso9660] self-test reported FAIL" "$LOG"; then
    echo "[test_iso9660] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_iso9660] PASS: $label"
    else
        echo "[test_iso9660] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"        "[iso9660] self-test start"
check "loop attached"        "[iso9660] loop device attached for .iso"
check "PVD mounted"          "[iso9660] mounted"
check "HELLO.TXT byte-exact" "[iso9660] /HELLO.TXT content verified"
check "Rock Ridge long name" "[iso9660] Rock Ridge long name resolved + read"
check "BIG.DAT 2-sector"     "[iso9660] /BIG.DAT (2 logical sectors) verified byte-exact"
check "nested file"          "[iso9660] /sub/NESTED.TXT resolved + read"
check "iso9660 PASS"         "[iso9660] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_iso9660] FAIL"
    exit 1
fi

echo "[test_iso9660] PASS — read-only ISO9660 + Rock Ridge: PVD parse, directory walk, byte-exact file read, Rock Ridge long name (NM), multi-sector extent, and nested lookup all verified"
