#!/usr/bin/env bash
# scripts/test_mdreshape.sh — native software-RAID (md) ONLINE RESHAPE / GROW
# self-test (RAID5 capacity expansion).
#
# Boots the kernel once with /etc/mdreshape-test planted
# (ENABLE_MDRESHAPE_TEST=1). init/main.ad at boot:37.mdreshape calls
# md_reshape_selftest() (drivers/block/md.ad), which registers DEDICATED
# in-kernel backing ramdisks ("mdback0".."mdback3") plus the journal ramdisk
# ("mdjrnl0") as the reshape checkpoint device, and PROVES a REAL online
# RAID5 grow:
#
#   * Build a 3-member RAID5 (chunk=4, 512-sector data capacity) and write a
#     KNOWN pattern across EVERY data sector (multiple stripes).
#   * GROW to 4 members (add mdback3) with md_reshape_grow — a real restripe
#     state machine that walks a PERSISTED checkpoint from 0 to the data-chunk
#     count, reading OLD-geometry stripes and rewriting them in the NEW
#     geometry, advancing the checkpoint after each new-stripe.
#   * The usable capacity GROWS from 512 to 768 sectors.
#   * EVERY original sector reads back BYTE-IDENTICAL through the new
#     4-member geometry (data preserved across the restripe).
#   * The newly-gained tail (sectors 512..767) is usable, and the head stays
#     intact after writing the tail.
#   * CRASH-RESTARTABILITY: a partially-run restripe (one new-stripe done,
#     all in-RAM reshape state wiped) RESUMES from the persisted checkpoint
#     (md_reshape_resume) with the data still verifying byte-identical.
#
# The self-test needs NO external disk — it backs everything onto its own
# in-kernel ramdisks, so the boot is fully deterministic.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [mdreshape] PASS
# Fail marker:  [mdreshape] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_mdreshape] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_mdreshape] (2/3) Build kernel with /etc/mdreshape-test marker"
INIT_ELF=build/user/init.elf ENABLE_MDRESHAPE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_mdreshape] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_mdreshape] --- captured (mdreshape lines) ---"
grep -E '\[md(reshape)?\]' "$LOG" || true
echo "[test_mdreshape] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_mdreshape] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[mdreshape] FAIL" "$LOG"; then
    echo "[test_mdreshape] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[mdreshape] self-test reported FAIL" "$LOG"; then
    echo "[test_mdreshape] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_mdreshape] PASS: $label"
    else
        echo "[test_mdreshape] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"                "[mdreshape] self-test start"
check "wrote+verified 3-member image" "[mdreshape] wrote+verified full 512s image (3 members) OK"
check "grow restripe complete"        "[mdreshape] grow 3->4 members restripe complete OK"
check "capacity grew 512->768"        "[mdreshape] capacity grew 512 -> 768 sectors OK"
check "data preserved across reshape" "[md] PASS mdreshape-data-preserved"
check "grown capacity usable"         "[md] PASS mdreshape-grown-capacity-usable"
check "crash sim partial convert"     "[mdreshape] crash sim: 1 new-stripe converted, state wiped OK"
check "crash restartable resume"      "[md] PASS mdreshape-crash-restartable"
check "mdreshape PASS"                "[mdreshape] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_mdreshape] FAIL"
    exit 1
fi

echo "[test_mdreshape] PASS — native software RAID online RESHAPE / GROW: a 3-member RAID5 with a known image across every data sector is grown to 4 members by a REAL crash-restartable restripe (md_reshape_grow) that walks a persisted checkpoint reading OLD-geometry stripes and rewriting them in the NEW geometry; the usable capacity grows 512 -> 768 sectors, EVERY original block reads back byte-identical through the new geometry, the newly-gained tail is usable while the head stays intact, and a partially-run restripe with all in-RAM state wiped RESUMES from the persisted checkpoint (md_reshape_resume) with the data still byte-identical — all verified"
