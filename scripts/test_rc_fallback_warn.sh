#!/usr/bin/env bash
# scripts/test_rc_fallback_warn.sh — guard the silent-cpio-fallback fix.
#
# etc/rc.boot's normal-boot branch falls back to the in-RAM cpio tools
# when `bind '#sysroot' /` fails. That fallback is BENIGN on the
# `-kernel` developer/live path (no rootfs disk was ever attached — the
# cpio IS the intended root) but is a SILENT DISASTER on a real
# INSTALLED system (the operator unknowingly runs throwaway tools and
# every edit "vanishes"). The fix gates a LOUD multi-line warning behind
# the *sysroot device* signal: a real whole-disk block device present
# under /dev/blk means an ext4 root was expected, so a bind failure must
# warn; with NO disk at all the cpio is intended and we stay quiet.
#
# This test proves BOTH directions on the cheap `-kernel` boot path:
#
#   (A) QUIET on the genuine live/dev image — NO disk attached, so the
#       probe finds no /dev/blk/<disk>, `installed` stays 0, and rc.boot
#       prints the quiet "cpio fallback (live/dev image)" line and NOT
#       the loud "ROOT FILESYSTEM FAILED TO MOUNT" banner.
#
#   (B) LOUD on an "installed" system — a blank virtio disk attached as
#       /dev/blk/vda makes the probe succeed (`installed` > 0), but the
#       blank disk carries no `.hamnix-roots` sentinel so `bind
#       '#sysroot' /` still fails — exactly the corrupt/unenumerated
#       installed-root scenario. rc.boot MUST then print the loud banner.
#
# Acceptance markers are emitted EARLY in the boot rc, long before the
# spawn-heavy startup hits the known `-m 256M` COW-OOM (a separate,
# pre-existing bug — see TODO/MEMORY), so we do not require a full boot.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

bash scripts/build_user.sh >/dev/null
python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOUD='ROOT FILESYSTEM FAILED TO MOUNT'
QUIET='cpio fallback (live/dev image)'

run_boot() {
    # $1 = log path; $2.. = extra qemu args (e.g. a -drive)
    local log="$1"; shift
    set +e
    (
        sleep 6
        printf 'exit\n'
        sleep 1
    ) | timeout 20s qemu-system-x86_64 \
        -kernel "$ELF" \
        -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
        "$@" \
        > "$log" 2>&1
    set -e
}

fail=0

# --- (A) no disk -> QUIET ------------------------------------------
LOG_A=$(mktemp)
run_boot "$LOG_A"
if grep -F -q "$QUIET" "$LOG_A"; then
    echo "[test_rc_fallback_warn] OK (A): quiet cpio-fallback line on the no-disk live/dev image"
else
    echo "[test_rc_fallback_warn] MISS (A): quiet fallback line absent on the no-disk image"
    fail=1
fi
if grep -F -q "$LOUD" "$LOG_A"; then
    echo "[test_rc_fallback_warn] MISS (A): LOUD warning cried wolf on the live/dev image (no disk)"
    fail=1
else
    echo "[test_rc_fallback_warn] OK (A): no false-alarm loud warning on the live/dev image"
fi

# --- (B) blank disk attached -> LOUD -------------------------------
# A blank raw disk: /dev/blk/vda registers (probe succeeds -> installed)
# but there is no .hamnix-roots sentinel, so `bind '#sysroot' /` fails.
BLANK=$(mktemp)
# 16 MiB of zeros — enough to register as a disk, no partition table /
# sentinel so #sysroot never gets posted.
dd if=/dev/zero of="$BLANK" bs=1M count=16 status=none
LOG_B=$(mktemp)
run_boot "$LOG_B" -drive file="$BLANK",if=virtio,format=raw
if grep -F -q "$LOUD" "$LOG_B"; then
    echo "[test_rc_fallback_warn] OK (B): LOUD warning fired on the installed system (disk present, sysroot unbindable)"
else
    echo "[test_rc_fallback_warn] MISS (B): LOUD warning did NOT fire with a real disk present"
    fail=1
fi

rm -f "$LOG_A" "$LOG_B" "$BLANK"

if [ "$fail" -ne 0 ]; then
    echo "[test_rc_fallback_warn] FAIL"
    exit 1
fi
echo "[test_rc_fallback_warn] PASS"
