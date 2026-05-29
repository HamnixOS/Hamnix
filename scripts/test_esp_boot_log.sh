#!/usr/bin/env bash
# scripts/test_esp_boot_log.sh — ACCEPTANCE GATE for ESP boot-log
# persistence (kernel/printk/esp_log.ad + the \LOG.TXT preallocation in
# scripts/build_img.sh).
#
# Proves the kernel actually FLUSHES its printk ring to the FAT ESP, so
# that on a real-hardware boot (Intel NUC, no serial port) the user can
# re-plug the boot USB stick into any PC, mount the ESP, and read
# \LOG.TXT to see why the box died.
#
# Flow:
#   1. build build/hamnix.img via build_img.sh (preallocates \LOG.TXT)
#   2. boot it under OVMF off a virtio disk (same path as
#      test_img_uefi_boot.sh) far enough to log boot markers, then power
#      it down.
#   3. pull \LOG.TXT back OFF partition 1 (the FAT ESP) of the RESULTING
#      disk image with `mcopy -i` at the ESP's byte offset.
#   4. assert the recovered file contains real boot markers — proving
#      the log was written to disk, not merely held in RAM.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm or OVMF firmware is unavailable.
#
# Env overrides:
#   HAMNIX_IMG         image path                (default: build/hamnix.img)
#   OVMF_FD            OVMF firmware path        (default: auto-resolved)
#   BOOT_WAIT          seconds to wait for the   (default: 90)
#                      shell-ready marker
#   HAMNIX_SKIP_BUILD  1 = reuse existing image  (default: rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_IMG="${HAMNIX_IMG:-build/hamnix.img}"
BOOT_WAIT="${BOOT_WAIT:-90}"
# Markers the kernel logs during boot. The early one proves we captured
# the start of boot; the late one proves a later boot PHASE made it to
# disk too (the whole point — not just the last few lines).
EARLY_MARKER="Hamnix kernel booting"
LATE_MARKER="start_first_task"
# A line the persistence module itself emits once it arms — confirms the
# kernel found LOG.TXT's extent on the ESP at all.
ARM_MARKER="esp_log: armed on"
PROMPT_MARKER="handing off to interactive shell"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_esp_log] SKIP: /dev/kvm absent (KVM required; boot too slow without it)" >&2
    exit 0
fi

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
    echo "[test_esp_log] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi
if ! command -v mcopy >/dev/null 2>&1; then
    echo "[test_esp_log] SKIP: mtools (mcopy) not found (apt install mtools)" >&2
    exit 0
fi

# --- build the image --------------------------------------------------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_esp_log] building disk image via build_img.sh"
    rm -f "$HAMNIX_IMG"
    bash "$PROJ_ROOT/scripts/build_img.sh"
fi
if [ ! -f "$HAMNIX_IMG" ]; then
    echo "[test_esp_log] FAIL: $HAMNIX_IMG missing after build_img.sh." >&2
    exit 1
fi

# --- locate the ESP (partition 1) byte offset within the image --------
# build_img.sh aligns the ESP at 1 MiB. Read it back from the GPT so
# this test stays correct if the layout math changes.
PARTED="/sbin/parted"
[ -x "$PARTED" ] || PARTED="$(command -v parted || true)"
ESP_START_SECTOR=""
if [ -n "$PARTED" ]; then
    # `unit s print` lists each partition's start sector; partition 1 is
    # the ESP. Grab the first data row's start (strip the trailing 's').
    ESP_START_SECTOR=$("$PARTED" -s "$HAMNIX_IMG" unit s print 2>/dev/null \
        | awk '/^ *1 /{gsub(/s/,"",$2); print $2; exit}')
fi
# Fall back to the documented 1 MiB alignment if parted is unavailable
# or its output didn't parse.
if ! [[ "$ESP_START_SECTOR" =~ ^[0-9]+$ ]]; then
    ESP_START_SECTOR=$(( 1 * 1024 * 1024 / 512 ))   # 1 MiB / 512
fi
ESP_OFFSET_BYTES=$(( ESP_START_SECTOR * 512 ))
echo "[test_esp_log] ESP starts at sector ${ESP_START_SECTOR} (byte ${ESP_OFFSET_BYTES})."

# --- boot under OVMF (writable disk copy so the flush sticks) ---------
OVMF_RW=$(mktemp --tmpdir hamnix-esplog.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-esplog.disk.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-esplog.XXXXXX.log)
RECOVERED=$(mktemp --tmpdir hamnix-esplog.recovered.XXXXXX.txt)
cp "$OVMF_FD" "$OVMF_RW"
cp "$HAMNIX_IMG" "$IMG_RW"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$RECOVERED"
}
trap cleanup EXIT

# No interactive input needed — we only need the kernel to boot far
# enough to flush. Drive stdin from /dev/null.
qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m 512M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    < /dev/null > "$LOG" 2>&1 &
QEMU_PID=$!

echo "[test_esp_log] waiting up to ${BOOT_WAIT}s for boot to reach the shell..."
booted=0
for _ in $(seq 1 "$BOOT_WAIT"); do
    if grep -a -q "$PROMPT_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        # qemu exited; the kernel may still have flushed before dying.
        break
    fi
    sleep 1
done

# Give the final flush a beat, then shut the VM down cleanly so the
# host's view of the disk image is settled before we read it back.
sleep 2
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null

if [ "$booted" -ne 1 ]; then
    echo "[test_esp_log] WARN: shell-ready marker not seen; checking what reached the ESP anyway." >&2
fi

# --- recover \LOG.TXT off the ESP of the BOOTED image -----------------
# mcopy reads a FAT volume at a byte offset inside a larger image via
# the `name@@offset` (mtools "offset") suffix. This opens partition 1
# in place — no loop mount, no root.
echo "[test_esp_log] pulling \\LOG.TXT off the ESP (partition 1) of the booted image."
if ! mcopy -n -o -i "${IMG_RW}@@${ESP_OFFSET_BYTES}" "::/LOG.TXT" "$RECOVERED" 2>/dev/null; then
    echo "[test_esp_log] FAIL: could not mcopy \\LOG.TXT off the ESP." >&2
    echo "----- serial log tail -----" >&2
    tail -60 "$LOG" >&2
    exit 1
fi

REC_BYTES=$(stat -c%s "$RECOVERED" 2>/dev/null || echo 0)
echo "[test_esp_log] recovered \\LOG.TXT: ${REC_BYTES} bytes."

# --- assertions on the RECOVERED (on-disk) log ------------------------
fail=0

# The persistence module must have armed (found LOG.TXT's extent). This
# check runs against the on-disk file: the arm line is itself logged
# AFTER esp_log_init, so a later flush captures it.
if grep -a -q "$ARM_MARKER" "$RECOVERED"; then
    echo "[test_esp_log] PASS: esp_log armed (LOG.TXT extent located on a block device)."
else
    echo "[test_esp_log] FAIL: '$ARM_MARKER' NOT in the on-disk log — the kernel never found LOG.TXT's extent." >&2
    fail=1
fi

# THE KEYSTONE: an EARLY boot marker is on disk. If only RAM held the
# log this file would still be the build-time zero fill.
if grep -a -q "$EARLY_MARKER" "$RECOVERED"; then
    echo "[test_esp_log] PASS (KEYSTONE): early boot marker ('$EARLY_MARKER') persisted to the ESP."
else
    echo "[test_esp_log] FAIL: early boot marker ('$EARLY_MARKER') NOT on the ESP — flush did not reach disk." >&2
    fail=1
fi

# A LATE boot-phase marker is on disk too — proves we capture more than
# the last few lines, which is the entire reason this feature exists.
if grep -a -q "$LATE_MARKER" "$RECOVERED"; then
    echo "[test_esp_log] PASS: late boot-phase marker ('$LATE_MARKER') persisted to the ESP."
else
    echo "[test_esp_log] FAIL: late boot-phase marker ('$LATE_MARKER') NOT on the ESP." >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_esp_log] PASS"
    rm -f "$LOG"
    exit 0
else
    echo "[test_esp_log] FAIL (serial log: $LOG ; recovered copy kept at: $RECOVERED)" >&2
    trap - EXIT
    rm -f "$OVMF_RW" "$IMG_RW"
    exit 1
fi
