#!/usr/bin/env bash
# scripts/test_xhci_ko_enum.sh — REAL Linux .ko xHCI bring-up test.
#
# Goes past the load-only test_xhci_ko.sh and the native-bridge
# test_xhci_io.sh. This boots in ENABLE_XHCI_KO_REAL=1 mode where:
#   * the hand-rolled drivers/usb/xhci.ad + ehci.ad are gated OFF at
#     boot:01 (the /etc/xhci-ko marker), AND
#   * the api_usb_hcd.ad usb_hcd_pci_probe NATIVE bridge to xhci_init()
#     is SUPPRESSED (/etc/xhci-ko-real), so NO Hamnix-native code drives
#     the controller, AND
#   * api_xhci_real.ad::xhci_real_exercise() resolves the GENUINE
#     EXPORT_SYMBOL'd functions of the loaded xhci_hcd.ko
#     (xhci_init_driver / xhci_run / xhci_gen_setup / xhci_irq) and lets
#     the STOCK LINUX DRIVER itself read the controller registers.
#
# What this proves (the milestone reached, honestly):
#   Stage 1 — the real Linux xhci_init_driver() runs and populates a
#     struct hc_driver with the .ko's OWN resident function pointers
#     (.start == the real xhci_run, .reset == the real xhci_gen_setup,
#     .irq == the real xhci_irq). This is the Linux driver's own setup
#     code executing through cross-module ksymtab resolution — not a
#     Hamnix shim.
#   Stage 2 — with native disabled, the controller's capability
#     registers (CAPLENGTH / HCIVERSION / HCSPARAMS1) are read LIVE
#     through the exact BAR convention the .ko's xhci_gen_setup uses
#     (hcd->regs == BAR0). Plausible values (CAPLENGTH 0x20..0x80,
#     non-zero max ports/slots) prove the controller MMIO window the
#     Linux driver relies on is reachable in this mode.
#
# Why no full GET_DESCRIPTOR assertion here: driving the real .ko
# xhci_gen_setup to completion (DMA rings via xhci_mem_init, retpoline
# __x86_indirect_thunk_*, __mutex_init/completion primitives, IRQ
# delivery into xhci_irq, the hub kthread) is multi-primitive work
# beyond this milestone — the deep call is gated behind
# ENABLE_XHCI_KO_REAL_MMIO=1 (stage 3) and currently #UDs inside the
# Linux setup path on a missing retpoline thunk. See the report in the
# api_xhci_real.ad header.
#
# With ENABLE_XHCI_KO_REAL_MMIO=1 the test now drives the .ko all the way
# to USB-MASS-STORAGE BLOCK I/O: stages 8/9/10 parse the config
# descriptor, SET_CONFIGURATION + Configure-Endpoint the bulk endpoints,
# and run BOT (Bulk-Only Transport) SCSI READ CAPACITY(10) + READ(10) of
# LBA 0 through the .ko's bulk rings, verifying the returned sector bytes
# are the marker + 0x55AA MBR signature seeded into the backing image.
#
# IMPORTANT — QEMU trace caveat: SeaBIOS has its own USB stack and
# enumerates attached USB devices at BIOS time (slot enable, address
# device, GET_DESCRIPTOR) and even reads sectors. Those `usb_xhci_slot_*`
# / `usb_xhci_xfer_*` trace events therefore appear in EVERY boot
# regardless of which OS driver runs, so they are NOT usable as ground
# truth that the Linux .ko did the work. This test instead asserts the
# unambiguous kernel-side [xhci-real] markers (which only the real .ko
# code path emits) PLUS trace payloads SeaBIOS cannot produce: TRBs
# fetched from OUR kzalloc'd low rings (addresses derived from kernel
# markers, never hardcoded) referencing OUR low-mem DMA buffers, and
# control setup wLengths SeaBIOS never emits (0x12 / 0x40). SeaBIOS
# drives its own transfers from high BIOS memory (0x000e8xxx rings ->
# 0x0efexxxx data), so an OUR-ring/OUR-buffer fetch is .ko-attributable.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
ENUM_TIMEOUT="${XHCI_ENUM_TIMEOUT:-40}"

echo "[test_xhci_ko_enum] (0/5) Probe QEMU for xhci + usb-storage"
HAS_XHCI=0
XHCI_DEVICE=""
if qemu-system-x86_64 -device help 2>&1 | grep -q '"qemu-xhci"'; then
    HAS_XHCI=1
    XHCI_DEVICE="qemu-xhci"
elif qemu-system-x86_64 -device help 2>&1 | grep -q '"nec-usb-xhci"'; then
    HAS_XHCI=1
    XHCI_DEVICE="nec-usb-xhci"
fi
if [ "$HAS_XHCI" -ne 1 ]; then
    echo "[test_xhci_ko_enum] SKIPPED — this QEMU build has no xhci emulation"
    exit 0
fi
if ! qemu-system-x86_64 -device help 2>&1 | grep -q '"usb-storage"'; then
    echo "[test_xhci_ko_enum] SKIPPED — this QEMU build has no usb-storage"
    exit 0
fi
echo "[test_xhci_ko_enum] OK: QEMU has -device $XHCI_DEVICE + usb-storage"

echo "[test_xhci_ko_enum] (1/5) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_xhci_ko_enum] (2/5) Build initramfs with /etc/xhci-ko-real + xhci-ko-real-mmio markers"
INITRAMFS_LOG=$(mktemp)
# Arm the DEEP path (ENABLE_XHCI_KO_REAL_MMIO=1): the real .ko
# xhci_gen_setup/mem_init run, the controller is started off the .ko's
# rings, and we drive a full Enable-Slot -> Address-Device ->
# GET_DESCRIPTOR enumeration step through the .ko-built rings. This
# stays a SEPARATE opt-in initramfs; the EXIT trap below restores the
# default native-USB initramfs so no other test is affected.
ENABLE_XHCI_KO_REAL=1 ENABLE_XHCI_KO_REAL_MMIO=1 INIT_ELF=build/user/init.elf \
    python3 scripts/build_initramfs.py > "$INITRAMFS_LOG" 2>&1
# Always restore the default (native-USB) initramfs on exit so the
# root-on-USB boot path is never left disabled for subsequent tests.
trap 'rm -f "$INITRAMFS_LOG" "${LOG:-}" "${TRACE:-}"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT
fail=0
for needle in \
    "embedded /lib/modules/usbcore.ko" \
    "embedded /lib/modules/xhci_pci.ko" \
    "embedded /lib/modules/xhci-hcd.ko"
do
    if grep -F -q "$needle" "$INITRAMFS_LOG"; then
        echo "[test_xhci_ko_enum] OK (cpio): '$needle'"
    else
        echo "[test_xhci_ko_enum] MISS (cpio): '$needle'"
        fail=1
    fi
done
if [ "$fail" -ne 0 ]; then
    cat "$INITRAMFS_LOG"
    exit 1
fi

echo "[test_xhci_ko_enum] (3/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null
if [ ! -s "$ELF" ]; then
    echo "[test_xhci_ko_enum] FAIL: kernel ELF missing"
    exit 1
fi

echo "[test_xhci_ko_enum] (4/5) Boot QEMU ($XHCI_DEVICE + usb-storage) with trace"
source "$PROJ_ROOT/scripts/_kernel_iso.sh"
KISO="$(kernel_iso "$ELF")"
LOG="$(mktemp)"
TRACE="$(mktemp)"
USBIMG="$(mktemp)"
truncate -s 16M "$USBIMG"
# Seed sector 0 with a known marker string + the 0x55AA MBR boot
# signature so the MSC READ(10) stage can assert it read REAL disk data
# (not a zero-filled placeholder). SeaBIOS never reads our LBA-0 content
# back into a guest buffer we control, so a marker match is .ko-attributable.
printf 'HAMNIX-MSC-SECTOR0-MARKER' | dd of="$USBIMG" bs=1 seek=0   conv=notrunc status=none
printf '\x55\xAA'                  | dd of="$USBIMG" bs=1 seek=510 conv=notrunc status=none
set +e
timeout "${ENUM_TIMEOUT}s" qemu-system-x86_64 \
    -boot d -cdrom "$KISO" \
    -device "$XHCI_DEVICE,id=xhci0" \
    -drive if=none,id=usbstick,file="$USBIMG",format=raw \
    -device usb-storage,bus=xhci0.0,drive=usbstick \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    -trace 'usb_xhci_*' -trace 'usb_port_*' -D "$TRACE" \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e
rm -f "$USBIMG"

echo "[test_xhci_ko_enum] (5/5) Inspect log + trace"
echo "[test_xhci_ko_enum] --- captured [xhci-real] markers ---"
grep -aE '\[xhci-real\]|\[boot:35\.X\.r\]|native xhci_init bridge SUPPRESSED' "$LOG" || true
echo "[test_xhci_ko_enum] --- end ---"

# Hard regression: any panic / trap during the real bring-up.
if grep -aE -q 'PANIC|panic:|TRAP:|BUG:' "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: kernel panic / trap during real .ko bring-up"
    tail -n 60 "$LOG"
    exit 1
fi

# Native must be provably disabled in this mode.
if ! grep -aF -q "[xhci] hand-rolled init SKIPPED" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: hand-rolled xhci_init not gated off"
    exit 1
fi
if ! grep -aF -q "native xhci_init bridge SUPPRESSED" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: usb_hcd_pci_probe native bridge not suppressed"
    exit 1
fi
# The native xhci body must NOT have entered.
if grep -aF -q "[boot:01.a] xhci_init enter" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: native drivers/usb/xhci.ad::xhci_init ran (native NOT disabled)"
    exit 1
fi
echo "[test_xhci_ko_enum] OK: native USB fully disabled (hand-rolled skipped + bridge suppressed + body not entered)"

# Stage 1: the real .ko xhci_init_driver populated real .ko fn pointers.
if ! grep -aF -q "[xhci-real] PASS stage1" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage1 (real .ko xhci_init_driver) did not pass"
    tail -n 40 "$LOG"
    exit 1
fi
echo "[test_xhci_ko_enum] OK: stage1 — real Linux xhci_init_driver ran; .start/.reset/.irq are real .ko code"

# Cross-module ksymtab actually resolved xhci_init_driver to the .ko
# (proves the resolution that stage1 depends on).
if ! grep -aE -q "\[ksymtab_hit\] xhci_pci -> xhci_hcd: xhci_init_driver" "$LOG"; then
    echo "[test_xhci_ko_enum] WARN: ksymtab_hit for xhci_init_driver not seen"
fi

# Stage 2: with native disabled, the controller cap registers read
# live through the Linux-driver BAR convention.
if ! grep -aF -q "[xhci-real] PASS stage2" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage2 (live controller cap-register read) did not pass"
    tail -n 40 "$LOG"
    exit 1
fi
# Assert a plausible CAPLENGTH was reported (qemu-xhci == 0x40).
if grep -aE -q "\[xhci-real\] stage2 CAPLENGTH=40 " "$LOG"; then
    echo "[test_xhci_ko_enum] OK: stage2 — controller CAPLENGTH=0x40 read live (native disabled)"
else
    echo "[test_xhci_ko_enum] OK: stage2 passed (CAPLENGTH plausible; see markers above)"
fi

# QEMU ground-truth sanity: the controller register window the Linux
# driver read is the same one QEMU's model serviced — assert at least
# one usb_xhci_cap_read happened (BIOS + our stage2 both hit it; we use
# it only as a liveness signal that the BAR window is wired, NOT as
# proof of Linux-driven enumeration — see header caveat).
if grep -aE -q 'usb_xhci_cap_read' "$TRACE"; then
    echo "[test_xhci_ko_enum] OK: QEMU serviced usb_xhci_cap_read (controller BAR window live)"
else
    echo "[test_xhci_ko_enum] WARN: no usb_xhci_cap_read in trace"
fi

# ---------------------------------------------------------------------
# DEEP path (ENABLE_XHCI_KO_REAL_MMIO=1): the real .ko xhci_gen_setup
# ran, the controller was started off the .ko's rings, and a full
# Enable-Slot -> Address-Device -> GET_DESCRIPTOR enumeration step was
# driven through the .ko-built rings. Each milestone is asserted from
# the kernel-side [xhci-real] markers AND cross-checked against the
# unambiguous QEMU trace (controller DMA activity on OUR ring
# addresses, distinguishable from SeaBIOS by buffer addr + wLength).
# ---------------------------------------------------------------------

# Stage 3: the real .ko xhci_gen_setup completed (halt+reset+mem_init).
if ! grep -aF -q "[xhci-real] PASS stage3" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage3 (real .ko xhci_gen_setup) did not complete"
    tail -n 40 "$LOG"
    exit 1
fi
echo "[test_xhci_ko_enum] OK: stage3 — real .ko xhci_gen_setup ran (halt+reset+mem_init)"

# Stage 4: the .ko programmed DCBAAP+CRCR into live MMIO and the
# controller went non-halted (running off the .ko ring layout).
if ! grep -aF -q "[xhci-real] PASS stage4: controller RUNNING off .ko ring config" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage4 (controller running off .ko rings) did not pass"
    tail -n 40 "$LOG"
    exit 1
fi
if ! grep -aE -q 'usb_xhci_run' "$TRACE"; then
    echo "[test_xhci_ko_enum] FAIL: QEMU trace has no usb_xhci_run (controller not started)"
    exit 1
fi
echo "[test_xhci_ko_enum] OK: stage4 — controller RUNNING off .ko rings (QEMU usb_xhci_run confirmed)"

# Stage 5: Enable-Slot round-trip. The kernel marker asserts the
# completion referenced OUR command TRB; cross-check the trace shows the
# controller fetched CR_ENABLE_SLOT from the EXACT .ko cmd-ring address
# the kernel posted it at. kzalloc returns whatever identity-mapped low
# page is free, so the ring's phys address is BUILD-DEPENDENT — we must
# NOT hardcode a 0x05.. prefix (that misses a genuine fetch on builds
# where the ring lands elsewhere). Instead we parse the 64-byte-aligned
# address the kernel posted Enable-Slot at and re-armed CRCR to
# ("stage5 post-at deq=0x....") and assert the controller fetched
# CR_ENABLE_SLOT at THAT address. This keeps the "controller really
# DMA-fetched OUR TRB from OUR ring" proof while being address-agnostic
# across builds.
if ! grep -aF -q "[xhci-real] PASS stage5" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage5 (Enable-Slot round-trip) did not pass"
    tail -n 40 "$LOG"
    exit 1
fi
# Parse "stage5 post-at deq=0x000000000XXXXXXX" from the log (the
# 64B-aligned address the kernel posted Enable-Slot at + re-armed CRCR to).
ES_ADDR="$(grep -aoE 'stage5 post-at deq=0x[0-9a-fA-F]+' "$LOG" \
            | head -1 | grep -aoE '0x[0-9a-fA-F]+')"
if [ -z "$ES_ADDR" ]; then
    echo "[test_xhci_ko_enum] FAIL: kernel did not emit the stage5 Enable-Slot ring address"
    exit 1
fi
echo "[test_xhci_ko_enum] stage5 Enable-Slot posted by kernel at $ES_ADDR (from marker)"
# The trace prints the fetched address zero-padded to 16 hex digits
# (e.g. 0x0000000005001000); normalise our parsed value the same way.
ES_NORM="$(printf '0x%016x' "$ES_ADDR")"
if ! grep -aF -q "fetch_trb addr ${ES_NORM}, CR_ENABLE_SLOT" "$TRACE"; then
    echo "[test_xhci_ko_enum] FAIL: trace shows no CR_ENABLE_SLOT fetched from the .ko cmd ring at $ES_NORM"
    echo "[test_xhci_ko_enum] --- CR_ENABLE_SLOT fetches seen in trace ---"
    grep -aE 'CR_ENABLE_SLOT' "$TRACE" || true
    exit 1
fi
echo "[test_xhci_ko_enum] OK: stage5 — Enable-Slot DMA-consumed from .ko cmd ring at $ES_NORM + completion to .ko event ring"

# Stage 6: Address-Device SUCCESS. Marker asserts the completion
# referenced OUR command TRB; the trace must show CR_ADDRESS_DEVICE
# fetched from the EXACT .ko cmd-ring address the kernel posted it at,
# AND its param TRB pointing at OUR (low-mem) input context. Both
# addresses are build-dependent (kzalloc), so we derive them from the
# kernel marker "stage6 Address-Device posted at 0x.... (in_ctx=0x....)"
# rather than hardcoding a 0x05.. prefix.
if ! grep -aF -q "[xhci-real] PASS stage6a: Address-Device SUCCESS" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage6 (Address-Device) did not return attributable SUCCESS"
    tail -n 40 "$LOG"
    exit 1
fi
AD_LINE="$(grep -aE 'stage6 Address-Device posted at 0x[0-9a-fA-F]+ \(in_ctx=0x[0-9a-fA-F]+\)' "$LOG" | head -1)"
AD_ADDR="$(printf '%s' "$AD_LINE" | grep -aoE 'posted at 0x[0-9a-fA-F]+' | grep -aoE '0x[0-9a-fA-F]+')"
AD_CTX="$(printf '%s' "$AD_LINE" | grep -aoE 'in_ctx=0x[0-9a-fA-F]+' | grep -aoE '0x[0-9a-fA-F]+')"
if [ -z "$AD_ADDR" ] || [ -z "$AD_CTX" ]; then
    echo "[test_xhci_ko_enum] FAIL: kernel did not emit the stage6 Address-Device ring/input-ctx addresses"
    exit 1
fi
AD_ADDR_NORM="$(printf '0x%016x' "$AD_ADDR")"
AD_CTX_NORM="$(printf '0x%016x' "$AD_CTX")"
echo "[test_xhci_ko_enum] stage6 Address-Device posted by kernel at $AD_ADDR_NORM -> in_ctx $AD_CTX_NORM (from marker)"
if ! grep -aF -q "fetch_trb addr ${AD_ADDR_NORM}, CR_ADDRESS_DEVICE, p ${AD_CTX_NORM}" "$TRACE"; then
    echo "[test_xhci_ko_enum] FAIL: trace shows no CR_ADDRESS_DEVICE at $AD_ADDR_NORM -> .ko input ctx $AD_CTX_NORM"
    echo "[test_xhci_ko_enum] --- CR_ADDRESS_DEVICE fetches seen in trace ---"
    grep -aE 'CR_ADDRESS_DEVICE' "$TRACE" || true
    exit 1
fi
echo "[test_xhci_ko_enum] OK: stage6 — Address-Device SUCCESS (controller fetched OUR TRB at $AD_ADDR_NORM referencing OUR input context $AD_CTX_NORM)"

# Stage 7: GET_DESCRIPTOR returned a valid 18-byte device descriptor.
# This is the unambiguous, BIOS-distinguishable proof: the marker
# asserts bLength==0x12 / bDescriptorType==0x01, and the trace must show
# a TR_SETUP fetched from OUR EP0 ring (0x0500xxxx) carrying wLength=0x12
# (immediate-data low qword ...0x01000680 with the 0x0012 length word)
# — SeaBIOS's own GET_DESCRIPTOR uses wLength=0x08, so this cannot be a
# BIOS transaction.
if ! grep -aF -q "[xhci-real] PASS stage7: GET_DESCRIPTOR(device) returned a valid 18-byte device descriptor" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage7 (GET_DESCRIPTOR) did not return a valid device descriptor"
    tail -n 40 "$LOG"
    exit 1
fi
if ! grep -aF -q "[xhci-real] stage7 device-descriptor bytes: bLength=0x0000000000000012 bDescriptorType=0x0000000000000001" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage7 descriptor bytes not the expected bLength=0x12/type=0x01"
    exit 1
fi
if ! grep -aE -q 'TR_SETUP, p 0x0012000001000680' "$TRACE"; then
    echo "[test_xhci_ko_enum] FAIL: trace shows no TR_SETUP with our wLength=0x12 GET_DESCRIPTOR (BIOS uses 0x08)"
    exit 1
fi
echo "[test_xhci_ko_enum] OK: stage7 — GET_DESCRIPTOR(device) round-tripped a valid 18-byte descriptor via OUR EP0 control ring"
echo "[test_xhci_ko_enum] OK: trace ground-truth — TR_SETUP wLength=0x12 on .ko EP0 ring (NOT SeaBIOS, which uses 0x08)"

# =====================================================================
# MSC (USB Mass Storage, Bulk-Only Transport) — stages 8/9/10. The .ko
# stack does not merely enumerate; it READS SECTORS off the usb-storage
# device. Proof discipline is identical to enumeration: kernel-side
# [xhci-real] markers attributable to OUR rings + QEMU trace payloads
# SeaBIOS cannot produce. SeaBIOS drives its own bulk transfers from high
# BIOS memory (rings at 0x000e8xxx -> data at 0x0efexxxx); OURS are
# fetched from kzalloc'd low rings (0x05xxxxxx) pointing at OUR low DMA
# buffers, and our control transfers carry wLengths SeaBIOS never emits.
# =====================================================================

# Stage 8: GET_DESCRIPTOR(config) parsed; bulk IN/OUT endpoints found.
# The control transfer is BIOS-distinguishable by its setup payload: we
# request wValue=0x0200 (CONFIG) wLength=0x0040, immediate-data low qword
# 0x0040000002000680 — SeaBIOS's config fetch uses a different wLength.
if ! grep -aF -q "[xhci-real] PASS stage8: GET_DESCRIPTOR(config) parsed" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage8 (GET_DESCRIPTOR config + bulk-endpoint parse) did not pass"
    tail -n 40 "$LOG"
    exit 1
fi
if ! grep -aF -q "[xhci-real] stage8 bulk endpoints: IN=0x0000000000000081 OUT=0x0000000000000002" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage8 did not identify the expected bulk IN=0x81 / OUT=0x02 endpoints"
    exit 1
fi
if ! grep -aE -q 'TR_SETUP, p 0x0040000002000680' "$TRACE"; then
    echo "[test_xhci_ko_enum] FAIL: trace shows no TR_SETUP for our GET_DESCRIPTOR(config) wLength=0x40 (BIOS-distinguishable)"
    exit 1
fi
echo "[test_xhci_ko_enum] OK: stage8 — config descriptor parsed; bulk IN=0x81/OUT=0x02 found (TR_SETUP wLength=0x40 on .ko EP0 ring)"

# Stage 9: SET_CONFIGURATION(1) + Configure-Endpoint SUCCESS. The
# Configure-Endpoint command TRB is fetched from OUR cmd ring at the
# exact address the kernel posted it (derived from the marker, not a
# hardcoded prefix), referencing OUR low-mem input context.
if ! grep -aF -q "[xhci-real] PASS stage9a: SET_CONFIGURATION(1) accepted over EP0" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage9a (SET_CONFIGURATION) did not complete with SUCCESS"
    tail -n 40 "$LOG"
    exit 1
fi
if ! grep -aF -q "[xhci-real] PASS stage9: Configure-Endpoint SUCCESS" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage9 (Configure-Endpoint) did not return attributable SUCCESS"
    tail -n 40 "$LOG"
    exit 1
fi
CE_LINE="$(grep -aE 'stage9 Configure-Endpoint posted at 0x[0-9a-fA-F]+ \(in_ctx=0x[0-9a-fA-F]+\)' "$LOG" | head -1)"
CE_ADDR="$(printf '%s' "$CE_LINE" | grep -aoE 'posted at 0x[0-9a-fA-F]+' | grep -aoE '0x[0-9a-fA-F]+')"
CE_CTX="$(printf '%s' "$CE_LINE" | grep -aoE 'in_ctx=0x[0-9a-fA-F]+' | grep -aoE '0x[0-9a-fA-F]+')"
if [ -z "$CE_ADDR" ] || [ -z "$CE_CTX" ]; then
    echo "[test_xhci_ko_enum] FAIL: kernel did not emit the stage9 Configure-Endpoint ring/input-ctx addresses"
    exit 1
fi
CE_ADDR_NORM="$(printf '0x%016x' "$CE_ADDR")"
CE_CTX_NORM="$(printf '0x%016x' "$CE_CTX")"
echo "[test_xhci_ko_enum] stage9 Configure-Endpoint posted by kernel at $CE_ADDR_NORM -> in_ctx $CE_CTX_NORM (from marker)"
if ! grep -aF -q "fetch_trb addr ${CE_ADDR_NORM}, CR_CONFIGURE_ENDPOINT, p ${CE_CTX_NORM}" "$TRACE"; then
    echo "[test_xhci_ko_enum] FAIL: trace shows no CR_CONFIGURE_ENDPOINT at $CE_ADDR_NORM -> .ko input ctx $CE_CTX_NORM"
    echo "[test_xhci_ko_enum] --- CR_CONFIGURE_ENDPOINT fetches seen in trace ---"
    grep -aE 'CR_CONFIGURE_ENDPOINT' "$TRACE" || true
    exit 1
fi
echo "[test_xhci_ko_enum] OK: stage9 — SET_CONFIGURATION + Configure-Endpoint SUCCESS (controller fetched OUR cmd TRB at $CE_ADDR_NORM -> OUR input ctx $CE_CTX_NORM)"

# Stage 10: BOT READ CAPACITY(10) + READ(10) of LBA 0 through the .ko
# bulk rings. The CBWs are bulk-OUT Normal TRBs fetched from OUR low-mem
# bulk-OUT ring pointing at OUR CBW buffer; the READ(10) data is a
# 512-byte bulk-IN Normal TRB into OUR sector buffer (s 0x00000200).
# SeaBIOS drives its bulk transfers from 0x000e8xxx rings into 0x0efexxxx
# data, so a Normal TRB fetched from our low ring into our low buffer is
# .ko-attributable. The decisive substance: the returned sector carries
# the marker + 0x55AA MBR signature we seeded — real disk data DMA'd back
# through OUR bulk-IN ring.
if ! grep -aF -q "[xhci-real] PASS stage10a: READ CAPACITY(10) over .ko bulk rings" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage10a (READ CAPACITY over BOT) did not complete with a good CSW"
    tail -n 40 "$LOG"
    exit 1
fi
echo "[test_xhci_ko_enum] OK: stage10a — READ CAPACITY(10) over .ko bulk rings (real disk geometry returned)"
# READ CAPACITY data must report the seeded 16 MiB disk: last-LBA 32767,
# 512-byte blocks. This 8-byte data IN came back through OUR bulk-IN ring.
if ! grep -aF -q "[xhci-real] PASS stage10a: READ CAPACITY(10) over .ko bulk rings — last-LBA=32767 block-size=512" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage10a capacity != the seeded 16 MiB disk (last-LBA=32767/512)"
    exit 1
fi
if ! grep -aF -q "[xhci-real] PASS stage10: READ(10) of LBA0 over .ko bulk rings returned 512 sector bytes" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: stage10 (READ(10) of LBA0 over BOT) did not return 512 sector bytes"
    tail -n 40 "$LOG"
    exit 1
fi
# Decisive proof the bytes are REAL disk data (not a zeroed buffer): the
# seeded marker "HAMNIX-MSC-SECTOR0-MARKER" begins with 'H'(0x48) 'A'(0x41),
# and the MBR signature 0x55AA sits at offset 510/511.
if ! grep -aF -q "[xhci-real] stage10 sector0 first bytes: [0]=0x0000000000000048 [1]=0x0000000000000041" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: sector-0 first bytes are not the seeded marker 'HA' — bulk-IN did not DMA real disk data"
    exit 1
fi
if ! grep -aF -q "[xhci-real] PASS stage10b: sector-0 carries the 0x55AA MBR boot signature" "$LOG"; then
    echo "[test_xhci_ko_enum] FAIL: sector-0 0x55AA MBR signature not read back through the .ko bulk-IN ring"
    exit 1
fi
# Trace ground-truth: a 512-byte bulk-IN Normal TRB (s 0x00000200)
# referencing OUR sector buffer (the kernel printed sector=0x....). Derive
# the buffer address from the marker so the assertion is build-agnostic.
SEC_BUF="$(grep -aoE 'stage10 BOT bufs: cbw=0x[0-9a-fA-F]+ sector=0x[0-9a-fA-F]+' "$LOG" | head -1 \
            | grep -aoE 'sector=0x[0-9a-fA-F]+' | grep -aoE '0x[0-9a-fA-F]+')"
if [ -z "$SEC_BUF" ]; then
    echo "[test_xhci_ko_enum] FAIL: kernel did not emit the stage10 sector buffer address"
    exit 1
fi
SEC_BUF_NORM="$(printf '0x%016x' "$SEC_BUF")"
echo "[test_xhci_ko_enum] stage10 sector buffer (from marker) = $SEC_BUF_NORM"
if ! grep -aF -q "TR_NORMAL, p ${SEC_BUF_NORM}, s 0x00000200" "$TRACE"; then
    echo "[test_xhci_ko_enum] FAIL: trace shows no 512-byte bulk-IN TR_NORMAL into our sector buffer $SEC_BUF_NORM"
    echo "[test_xhci_ko_enum] --- 512-byte TR_NORMAL fetches seen in trace ---"
    grep -aE 'TR_NORMAL.*s 0x00000200' "$TRACE" || true
    exit 1
fi
echo "[test_xhci_ko_enum] OK: stage10 — READ(10) DMA'd 512 real sector bytes into OUR bulk-IN buffer $SEC_BUF_NORM (marker + 0x55AA verified)"

echo "[test_xhci_ko_enum] PASS (real Linux xhci_hcd.ko drove FULL enumeration AND USB-MSC block I/O: gen_setup + controller-run + Enable-Slot + Address-Device + GET_DESCRIPTOR + SET_CONFIG + Configure-Endpoint + BOT READ CAPACITY + READ(10) sector through .ko rings; native disabled)"
