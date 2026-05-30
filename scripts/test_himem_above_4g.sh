#!/usr/bin/env bash
# scripts/test_himem_above_4g.sh — proves the kernel can use physical RAM
# ABOVE 4 GiB.
#
# Background: the boot stub (arch/x86/boot/header.S) used to identity-map
# only the first 4 GiB (pdpt_low filled with 4× 1 GiB pages, high dword of
# each PDPT entry hardcoded to 0). On a machine with > 4 GiB the largest
# free e820 region lives ABOVE the 4 GiB hole; the moment the kernel
# touched a frame up there it #PF'd / triple-faulted. header.S now fills
# ALL 512 pdpt_low entries (512× 1 GiB = low 512 GiB) with a proper
# 64-bit phys base split across the entry's low/high dwords.
#
# This test boots build/hamnix.img under OVMF (UEFI) with -m 8G so the
# firmware reports a real above-4-GiB region that is ALSO the LARGEST
# free region (at -m 6G the below-4-GiB chunk is still the largest, so
# memblock would pick it and the bug would hide). At 8G the ~4 GiB
# above-the-hole region wins, so memblock's bump base — and thus every
# early allocation: per-task PML4 clones, user stacks, ELF images —
# lands ABOVE 4 GiB. That is the exact real-hardware failure mode (a
# per-task PML4 + user stack at phys 0x101421000 got truncated to
# 0x01421000 by the old 4-GiB-only identity map and the box triple-
# faulted on the iretq into /init).
#
# Two independent proofs are gated:
#   1. SYNTHETIC: the kernel [himem] self-test (arch/x86/mm/init.ad:
#      _himem_selftest) grabs the top page of the memblock region,
#      asserts its phys is >= 4 GiB, writes+reads a sentinel through its
#      identity-mapped virtual address, and prints `[himem] PASS phys=`.
#   2. END-TO-END: the system must reach the interactive shell. With
#      memblock rooted above 4 GiB, getting to the shell exercises real
#      per-task PML4 + user-stack allocations out of high RAM — the
#      thing that actually broke on the NUC / Asus.
#
# PASS/FAIL is decided by the `[himem_above_4g] PASS` / `... FAIL` line
# this script echoes, gated on log markers — NOT on the qemu exit code
# (a -no-reboot kernel that we kill, or a benign rc=124 timeout, is fine).
#
# SKIPS CLEANLY (exit 0) when /dev/kvm or OVMF firmware is unavailable.
#
# Env overrides:
#   HAMNIX_IMG         image path                (default: build/hamnix.img)
#   OVMF_FD            OVMF firmware path        (default: auto-resolved)
#   HIMEM_RAM          guest RAM size            (default: 8G)
#   HIMEM_BOOT_WAIT    seconds to wait for the   (default: 120)
#                      shell-ready marker
#   HAMNIX_SKIP_BUILD  1 = reuse existing image  (default: rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_IMG="${HAMNIX_IMG:-build/hamnix.img}"
HIMEM_RAM="${HIMEM_RAM:-8G}"
HIMEM_BOOT_WAIT="${HIMEM_BOOT_WAIT:-120}"
KERNEL_BANNER="Hamnix kernel booting"
HIMEM_PASS_MARKER="[himem] PASS"
HIMEM_FAIL_MARKER="[himem] FAIL"
# rc.boot's final line before the interactive REPL — same marker the
# normal UEFI boot test gates on. Reaching it under high RAM proves the
# real failure mode (per-task PML4 + user stack above 4 GiB) is fixed.
PROMPT_MARKER="handing off to interactive shell"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[himem_above_4g] SKIP: /dev/kvm absent (KVM required; boot too slow without it)" >&2
    exit 0
fi

# OVMF resolution: prefer the Debian-style single-file /usr/share/ovmf/
# OVMF.fd; fall back to the split /usr/share/OVMF/OVMF_CODE*.fd packaging.
OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    if [ -f /usr/share/ovmf/OVMF.fd ]; then
        OVMF_FD=/usr/share/ovmf/OVMF.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[himem_above_4g] SKIP: OVMF firmware not found (tried /usr/share/ovmf/OVMF.fd and /usr/share/OVMF/OVMF_CODE*.fd; apt install ovmf)" >&2
    exit 0
fi

# --- build the image --------------------------------------------------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[himem_above_4g] building disk image via build_img.sh"
    rm -f "$HAMNIX_IMG"
    bash "$PROJ_ROOT/scripts/build_img.sh"
fi
if [ ! -f "$HAMNIX_IMG" ]; then
    echo "[himem_above_4g] FAIL: $HAMNIX_IMG missing after build_img.sh." >&2
    exit 1
fi

# OVMF persists UEFI variables back into the firmware file, so it needs a
# writable copy. The disk is also opened r/w — copy it so a re-run starts
# from a pristine image.
OVMF_RW=$(mktemp --tmpdir hamnix-himem.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-himem.disk.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-himem.XXXXXX.log)
cp "$OVMF_FD" "$OVMF_RW"
cp "$HAMNIX_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW"
}
trap cleanup EXIT

echo "[himem_above_4g] booting build/hamnix.img under UEFI with -m ${HIMEM_RAM}"

# Boot the image as a DISK via virtio-blk with > 4 GiB of RAM so the
# firmware reports an above-4-GiB region for the kernel to exercise.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m "$HIMEM_RAM" \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    < /dev/null > "$LOG" 2>&1 &
QEMU_PID=$!

# --- wait for the shell-ready marker ----------------------------------
# We wait for the END-TO-END marker (the interactive prompt), not just
# the synthetic [himem] marker: reaching the shell is what exercises the
# real above-4-GiB per-task PML4 + user-stack allocations. The [himem]
# self-test fires much earlier, so by the time the prompt appears it is
# already in the log.
echo "[himem_above_4g] waiting up to ${HIMEM_BOOT_WAIT}s for the shell-ready marker..."
for _ in $(seq 1 "$HIMEM_BOOT_WAIT"); do
    if grep -a -q -F "$PROMPT_MARKER" "$LOG"; then
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        # qemu exited (triple-fault reboot suppressed by -no-reboot, or a
        # clean halt). The marker checks below are authoritative.
        break
    fi
    sleep 1
done

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

# --- assertions (marker-gated, NOT exit-code-gated) -------------------
fail=0

# 1. Kernel banner (proves the EFI stub loaded + jumped into the kernel).
if grep -a -q -F "$KERNEL_BANNER" "$LOG"; then
    echo "[himem_above_4g] PASS: kernel banner ('$KERNEL_BANNER') present."
else
    echo "[himem_above_4g] FAIL: kernel banner ('$KERNEL_BANNER') NOT present — boot did not reach the kernel." >&2
    fail=1
fi

# 2. The keystone: the himem self-test must report PASS and must NOT
#    report FAIL.
if grep -a -q -F "$HIMEM_FAIL_MARKER" "$LOG"; then
    echo "[himem_above_4g] FAIL: '[himem] FAIL' present — high-RAM sentinel mismatch:" >&2
    grep -a -F "$HIMEM_FAIL_MARKER" "$LOG" >&2
    fail=1
elif grep -a -q -F "$HIMEM_PASS_MARKER" "$LOG"; then
    echo "[himem_above_4g] PASS (KEYSTONE): high-RAM self-test passed:"
    grep -a -F "$HIMEM_PASS_MARKER" "$LOG"
else
    echo "[himem_above_4g] FAIL: no '[himem] PASS' marker — self-test never ran (region top <= 4 GiB?) or boot stalled." >&2
    echo "----- serial log tail -----" >&2
    tail -80 "$LOG" >&2
    fail=1
fi

# 3. END-TO-END: the system reached the interactive shell. Under -m 8G
#    memblock is rooted above 4 GiB, so reaching the prompt means the
#    per-task PML4 clone + user stack + ELF image for /init all came out
#    of high RAM and were correctly mapped — the real-hardware failure
#    mode (truncated 0x101421000 -> 0x01421000 triple-fault) is gone.
if grep -a -q -F "$PROMPT_MARKER" "$LOG"; then
    echo "[himem_above_4g] PASS (KEYSTONE): reached interactive shell with memblock above 4 GiB."
else
    echo "[himem_above_4g] FAIL: shell-ready marker ('$PROMPT_MARKER') NOT present — boot did not complete under high RAM." >&2
    echo "----- serial log tail -----" >&2
    tail -80 "$LOG" >&2
    fail=1
fi

# 4. No hard-fault markers anywhere in the boot.
if grep -a -q -E 'PANIC|panic:|TRAP:|BUG:|FAIL' "$LOG"; then
    # Exclude our own "[himem_above_4g] FAIL" / "[himem] FAIL" echoes
    # (those are handled above); only flag kernel-side hard faults.
    if grep -a -E 'PANIC|panic:|TRAP:|BUG:' "$LOG" | grep -a -q -v 'himem'; then
        echo "[himem_above_4g] FAIL: hard-fault marker (PANIC/TRAP/BUG) in the boot log:" >&2
        grep -a -E 'PANIC|panic:|TRAP:|BUG:' "$LOG" | grep -a -v 'himem' >&2
        fail=1
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "[himem_above_4g] PASS"
    rm -f "$LOG"
    exit 0
else
    echo "[himem_above_4g] FAIL (serial log: $LOG)" >&2
    exit 1
fi
