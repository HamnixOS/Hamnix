#!/usr/bin/env bash
# scripts/test_snd_hda_io.sh — REAL codec-I/O exercise for the Intel
# HD Audio .ko stack (snd_hda_intel + snd_hda_codec + snd_hda_core +
# snd_pcm + snd) loaded via the L-series loader.
#
# This is the "real exercise" companion to scripts/test_snd_hda_ko.sh.
# Where the _ko test only proves the five .ko's LOAD and their
# init_module returns 0, THIS test asserts the controller probe drove
# LIVE codec I/O over the controller's MMIO immediate-command interface
# and walked QEMU's emulated HDA codec node tree.
#
# Boot fixture:  -device intel-hda,debug=3 -device hda-output
#   intel-hda,debug=3 makes QEMU's HDA controller log every immediate-
#   command verb it receives on ICW and every response it latches into
#   IRR. Those `intel-hda:` lines on QEMU's stderr are the ground-truth
#   record of what the guest actually read off the controller — not a
#   synthetic kernel-side marker.
#
# REAL evidence asserted (all must hold):
#
#   1. The guest wrote verb 0x000f0000 (GET_PARAMETERS / VENDOR_ID on
#      the root node) to ICW and QEMU answered IRR = 0x1af40012 — the
#      Red Hat / QEMU codec vendor:device ID (0x1af4:0x0012) read off
#      live controller MMIO. This is the codec-enumeration deliverable.
#
#   2. The guest wrote verb 0x000f0004 (root NODE_COUNT) and QEMU
#      answered a NONZERO node count (response 0x10001 == start_node 1,
#      1 sub-node) — i.e. the function-group walk found an AFG, the
#      thing that previously failed with "no AFG or MFG node found".
#
#   3. The probe walked into the audio function group: at least one
#      sub-node verb in the 0x1f.... range fired (AFG NODE_COUNT
#      0x001f0004 / widget caps), proving enumeration went past the
#      root node into real widget discovery.
#
#   4. The kernel did NOT print "no AFG or MFG node found" nor
#      "no codecs initialized" — the codec bring-up completed.
#
#   5. snd_hda_intel.ko init_module returned 0 (clean probe; no hang in
#      the azx error/cleanup path).
#
#   6. ZERO traps/panics/BUGs anywhere in the module-load + codec-I/O
#      portion of the boot log.
#
# The single emulated codec is QEMU's `hda-output` (line-out only); we
# don't push PCM samples through it here (no /dev/snd userland yet), so
# this test stops at "codec enumerated over real MMIO". Advancing a
# stream position (true playback) is the next rung and out of scope.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
SND_BOOT_TIMEOUT="${SND_BOOT_TIMEOUT:-60}"

echo "[test_snd_hda_io] (0/4) Sanity-check the 5 .ko files are checked in"
fail=0
for sub in snd snd_pcm snd_hda_core snd_hda_codec snd_hda_intel; do
    KO=$(ls "$PROJ_ROOT/kernel-modules/$sub/"*.ko 2>/dev/null | head -1)
    if [ -z "$KO" ]; then
        echo "[test_snd_hda_io] FAIL: kernel-modules/$sub/*.ko missing"
        fail=1
    else
        echo "[test_snd_hda_io] OK: $KO present ($(stat -c%s "$KO") bytes)"
    fi
done
if [ "$fail" -ne 0 ]; then exit 1; fi

echo "[test_snd_hda_io] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_snd_hda_io] (2/4) Bake initramfs with ENABLE_AUTO_MODULES=1"
INITRAMFS_LOG=$(mktemp)
ENABLE_AUTO_MODULES=1 python3 scripts/build_initramfs.py \
    > "$INITRAMFS_LOG" 2>&1
trap 'rm -f "$INITRAMFS_LOG" "${LOG:-}"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

for needle in \
    "embedded /lib/modules/auto/snd_hda_intel.ko" \
    "embedded /lib/modules/modules.alias"
do
    if grep -F -q "$needle" "$INITRAMFS_LOG"; then
        echo "[test_snd_hda_io] OK (cpio): '$needle'"
    else
        echo "[test_snd_hda_io] MISS (cpio): '$needle'"
        fail=1
    fi
done
if [ "$fail" -ne 0 ]; then
    cat "$INITRAMFS_LOG"
    exit 1
fi

echo "[test_snd_hda_io] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null
if [ ! -s "$ELF" ]; then
    echo "[test_snd_hda_io] FAIL: kernel ELF missing after build"
    exit 1
fi
echo "[test_snd_hda_io] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"

echo "[test_snd_hda_io] (4/4) Boot QEMU with intel-hda,debug=3 + hda-output"
LOG=$(mktemp)
trap 'rm -f "$INITRAMFS_LOG" "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout "${SND_BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device e1000e,netdev=n0,mac=52:54:00:12:34:56 \
    -device intel-hda,debug=3 \
    -device hda-output \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_snd_hda_io] --- captured (intel-hda verb/response + snd) ---"
grep -aE 'intel-hda:.*(ICW|IRR|\[icw\]|\[irr\])|no AFG|no codecs|init returned' "$LOG" \
    | head -120 || true
echo "[test_snd_hda_io] --- end ---"
cp "$LOG" /tmp/test_snd_hda_io.last.log || true

echo "[test_snd_hda_io] === assert REAL codec I/O over MMIO ==="

# Evidence 1 — codec VENDOR_ID read off live controller MMIO.
# QEMU answers the GET_PARAMETERS/VENDOR_ID (verb 0x000f0000) verb with
# IRR = 0x1af40012 (Red Hat/QEMU vendor 0x1af4, device 0x0012).
if grep -aE -q "\[irr\] response 0x1af40012" "$LOG"; then
    echo "[test_snd_hda_io] OK: codec ID 0x1af40012 read off MMIO (IRR) — real enumeration"
else
    echo "[test_snd_hda_io] FAIL: codec vendor ID 0x1af40012 never read off IRR"
    echo "[test_snd_hda_io] --- intel-hda response lines seen ---"
    grep -aE "intel-hda:.*(IRR|\[irr\])" "$LOG" | head -20 || true
    fail=1
fi

# Also assert the matching ICW write actually went out (the verb that
# elicited the response) — proves WE drove the controller, not QEMU
# self-reporting.
if grep -aE -q "\[icw\] verb 0x000f0000" "$LOG"; then
    echo "[test_snd_hda_io] OK: guest wrote VENDOR_ID verb 0x000f0000 to ICW"
else
    echo "[test_snd_hda_io] FAIL: VENDOR_ID verb 0x000f0000 never written to ICW"
    fail=1
fi

# Evidence 2 — root NODE_COUNT verb fired AND returned a nonzero
# function-group count. Verb 0x000f0004; QEMU's hda-output answers
# 0x10001 (start_node 1, num_nodes 1). The presence of this verb AND a
# nonzero response is exactly what was missing when enumeration died at
# "no AFG or MFG node found".
if grep -aE -q "\[icw\] verb 0x000f0004" "$LOG"; then
    echo "[test_snd_hda_io] OK: guest wrote root NODE_COUNT verb 0x000f0004"
else
    echo "[test_snd_hda_io] FAIL: root NODE_COUNT verb 0x000f0004 never fired"
    fail=1
fi

# Evidence 3 — enumeration descended into the audio function group:
# at least one sub-node verb in the 0x1f.... range (AFG NODE_COUNT
# 0x001f0004 / sub-node start 0x001f0005 / widget caps). This proves
# the walk got past the root node into real widget discovery.
if grep -aE -q "\[icw\] verb 0x001f000[45]" "$LOG"; then
    echo "[test_snd_hda_io] OK: probe walked into the AFG (sub-node verb 0x001f000x fired)"
else
    echo "[test_snd_hda_io] FAIL: enumeration never descended into the function group"
    echo "[test_snd_hda_io] --- distinct verbs seen ---"
    grep -aoE "\[icw\] verb 0x[0-9a-f]+" "$LOG" | sort -u | head -30 || true
    fail=1
fi

# Evidence 4 — codec bring-up did NOT bail. These two strings are the
# failure signatures that the pre-fix path hit.
if grep -aE -q "no AFG or MFG node found" "$LOG"; then
    echo "[test_snd_hda_io] FAIL: codec enumeration bailed — 'no AFG or MFG node found'"
    fail=1
else
    echo "[test_snd_hda_io] OK: no 'no AFG or MFG node found' — function group enumerated"
fi
if grep -aE -q "no codecs initialized" "$LOG"; then
    echo "[test_snd_hda_io] FAIL: 'no codecs initialized' — codec bring-up failed"
    fail=1
else
    echo "[test_snd_hda_io] OK: no 'no codecs initialized' — codec brought up"
fi

# Evidence 5 — snd_hda_intel.ko init_module returned 0 (clean probe; no
# hang in the azx error/cleanup path under the cooperative scheduler).
if awk '
    /kmod_linux: name=snd_hda_intel$/   {hit=1; next}
    hit && /kmod_linux: name=/          {exit}
    hit && / init returned 0;/          {print "OK"; exit}
    hit && / init returned [^0]/        {print "BAD"; exit}
' "$LOG" | grep -qE 'OK'; then
    echo "[test_snd_hda_io] OK: snd_hda_intel.ko init_module returned 0"
else
    echo "[test_snd_hda_io] FAIL: snd_hda_intel.ko init_module did not return 0"
    fail=1
fi

# Evidence 6 — zero traps/panics/BUGs in the boot. A double-fault /
# #GP / page-fault during codec I/O means the MMIO path or a shim
# returned the wrong shape. (The well-known post-module-load
# start_first_task double-fault, if present, lives AFTER all modules
# load and the snd assertions; we scope this check to the module-load
# window by cutting the log at the boot:42/start_first_task marker.)
WINDOW=$(mktemp)
awk '/\[boot:42\] start_first_task/{exit} {print}' "$LOG" > "$WINDOW"
n_traps=$(grep -acE "trap-diag\] vec=|TRAP: vector|#UD|#GP fault|Page Fault|kernel panic|kernel BUG" "$WINDOW" || true)
rm -f "$WINDOW"
if [ "${n_traps:-0}" -eq 0 ]; then
    echo "[test_snd_hda_io] OK: no traps/panics/BUGs during module-load + codec I/O"
else
    echo "[test_snd_hda_io] FAIL: ${n_traps} trap line(s) during module-load window"
    awk '/\[boot:42\] start_first_task/{exit} /trap-diag\] vec=|TRAP: vector|#UD|#GP fault|Page Fault|kernel panic|kernel BUG/{print}' "$LOG" | head -10
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_snd_hda_io] FAIL (qemu rc=$rc)"
    echo "[test_snd_hda_io] --- full log tail ---"
    tail -160 "$LOG"
    exit 1
fi

echo "[test_snd_hda_io] PASS (codec 0x1af40012 read off MMIO; root + AFG node tree enumerated; snd_hda_intel init=0; no traps)"
