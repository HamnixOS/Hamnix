#!/usr/bin/env bash
# scripts/test_drm_ko.sh — regression guard for the drm.ko harvest
# through the L-series loader. drm.ko is Linux's DRM/KMS CORE: the
# graphics framework that every GPU driver (i915/amdgpu/nouveau/...)
# builds on — drm_drv (driver registration), drm_ioctl (the DRM ioctl
# surface), drm_gem (the GEM buffer-object manager), the GEM/PRIME
# dma-buf sharing machinery, dma-fence/dma-resv sync primitives, and
# the atomic mode-setting core. Harvesting it proves Hamnix's module
# loader + linux_abi ABI can absorb the DRM core framework — the LAST
# un-probed subsystem class (after e1000e, libata+scsi, ahci, snd_hda,
# wifi, xhci/ehci).
#
# WHY A KERNEL-SIDE BOOT EXERCISE (not userspace `insmod`):
#   drm.ko's modinfo in this Debian 6.1.0-32 build carries NO
#   `depends:` line — it IS the framework everything else depends on —
#   so a single kmod_linux_load suffices (no ordered dependency chain).
#   Driving insmod over a piped hamsh stdin is timing-fragile (the shell
#   line-editor drops fast-typed lines). Instead the kernel's
#   boot:35.DRM path (init/main.ad, gated on /etc/drm-ko) does the
#   single load. This test plants that marker (ENABLE_DRM_KO=1) and
#   asserts the serial log.
#
# THE HARVEST BAR — "links + init runs", NOT mode-setting:
#   drm.ko's 316 UND symbols resolve entirely against the L1..L68 +
#   api_*.ad surface plus the 101 closers in linux_abi/api_drm.ad (and
#   the autostub generator's __x86_indirect_thunk_rsi). Under QEMU's
#   emulated VGA there is no real GPU, so drm.ko's init_module
#   registers its chrdev/debugfs scaffolding and returns — same shape
#   as snd_hda landing at -ENXIO. The win condition is "relocations
#   skipped=0 + init_module returns".
#
# Assertions:
#   1. `kmod_linux: name=drm`       — harvest target located + parsed.
#   2. Every relocation pass reports `skipped=0` (no UND silently left).
#   3. drm init_module returned (>=1 `init returned` line).
#   4. `[boot:35.DRM] drm.ko harvest OK`.
#   5. No CPU traps / kernel BUGs / panics, no unresolved external
#      symbol, no unknown reloc type.
#
# i915.ko is staged in the initramfs but NOT loaded here: its UND gap
# is large (hundreds of symbols) and out of scope for the drm-core
# coverage probe — see the gap diagnostic below for the live count.
#
# SKIPs cleanly (exit 0) if qemu / grub-mkrescue prerequisites are
# absent so the suite stays green on a tooling-less host.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
INIT_ELF=build/user/init.elf

# --- module presence (hard fail if the .ko file is missing) ---------
DRM_KO="kernel-modules/drm/drm.ko"
sz=$(stat -c%s "$PROJ_ROOT/$DRM_KO" 2>/dev/null || echo 0)
if [ "$sz" -lt 500000 ]; then
    echo "[test_drm_ko] FAIL: $DRM_KO missing or too small (${sz} bytes)"
    exit 1
fi
echo "[test_drm_ko] OK: $DRM_KO present (${sz} bytes)"

# --- gap diagnostic (informational, non-fatal) ----------------------
# drm.ko's UND symbols not covered by a linux_abi shim. A non-empty
# list here means the harvest is genuinely incomplete (the boot
# exercise would then report skipped>0). We expect 0 — api_drm.ad
# closes the 101-symbol gap and gen_autostubs covers the lone thunk.
# Write the exported-symbol set to a file and grep the FILE (not a
# piped `echo "$var" | grep -q`): under `set -o pipefail`, grep -q
# closes the pipe on its first match, killing the upstream echo with
# SIGPIPE (141) and making a SUCCESSFUL match look like a failure.
SHIM_F=$(mktemp)
grep -rhoE '_add_export\("[^"]+"' linux_abi/ \
    | sed -E 's/_add_export\("//; s/"$//' | sort -u > "$SHIM_F"
# Autostub-pattern names the build-time generator covers mechanically.
AUTOSTUB_RE='^(__SC[KT]__|__tracepoint_|__traceiter_|__bpf_trace_|__profile_|__x86_indirect_thunk_|__x86_return_thunk$|__fentry__$)'
UND_SYMS=$(nm -u "$PROJ_ROOT/$DRM_KO" 2>/dev/null | awk '{print $2}' | sort -u)
MISSING=""
for sym in $UND_SYMS; do
    grep -qxF "$sym" "$SHIM_F" && continue
    if [[ "$sym" =~ $AUTOSTUB_RE ]]; then continue; fi
    MISSING+=" $sym"
done
TOTAL_UND=$(echo "$UND_SYMS" | wc -w)
TOTAL_MISSING=$(echo "$MISSING" | wc -w)
echo "[test_drm_ko] drm UND total=$TOTAL_UND uncovered(shim+autostub)=$TOTAL_MISSING"
if [ -n "$MISSING" ]; then
    echo "[test_drm_ko] FAIL: uncovered drm UND symbols (would skip>0 at load):"
    for s in $MISSING; do echo "  - $s"; done
    exit 1
fi

# --- i915 follow-up diagnostic (informational only) -----------------
I915_KO="kernel-modules/i915/i915.ko"
if [ -f "$PROJ_ROOT/$I915_KO" ]; then
    I915_UND=$(nm -u "$PROJ_ROOT/$I915_KO" 2>/dev/null | awk '{print $2}' | sort -u)
    I915_MISS=0
    for sym in $I915_UND; do
        grep -qxF "$sym" "$SHIM_F" && continue
        if [[ "$sym" =~ $AUTOSTUB_RE ]]; then continue; fi
        I915_MISS=$((I915_MISS + 1))
    done
    echo "[test_drm_ko] (info) i915.ko uncovered UND=$I915_MISS — deferred follow-up, not loaded by this probe"
fi
rm -f "$SHIM_F"

# --- prerequisite gate (clean SKIP) ---------------------------------
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "[test_drm_ko] SKIP: qemu-system-x86_64 not available"
    exit 0
fi
if ! command -v grub-mkrescue >/dev/null 2>&1; then
    echo "[test_drm_ko] SKIP: grub-mkrescue not available (kernel is ELF64; needs the ISO shim)"
    exit 0
fi

echo "[test_drm_ko] (1/3) Build userland + modules + initramfs (drm marker)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
ENABLE_DRM_KO=1 INIT_ELF="$INIT_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_drm_ko] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s "$ELF" ]; then
    echo "[test_drm_ko] FAIL: kernel ELF missing"
    INIT_ELF="$INIT_ELF" python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
    exit 1
fi
echo "[test_drm_ko] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"

echo "[test_drm_ko] (3/3) Boot QEMU; kernel-side boot:35.DRM drives the load"
LOG=$(mktemp)
# Restore the default initramfs on exit so a later test isn't surprised
# by the drm marker leaking into its image.
trap 'rm -f "$LOG"; INIT_ELF="'"$INIT_ELF"'" python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
timeout 90s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 512M \
    -monitor none -serial stdio \
    < /dev/null > "$LOG" 2>&1
rc=$?
set -e
# rc=124 (timeout) is EXPECTED — init.elf is a long-running PID 1.
echo "[test_drm_ko] qemu exited rc=$rc (124=timeout, expected for long-running init)"
cp "$LOG" /tmp/test_drm_ko.last.log 2>/dev/null || true

echo "[test_drm_ko] --- captured (boot:35.DRM / kmod) ---"
grep -aE 'boot:35.DRM|kmod_linux: (name=drm|relocations applied|init returned|no init|unresolved external|unknown reloc)' "$LOG" | head -40 || true
echo "[test_drm_ko] --- end ---"

fail=0

# 1. No traps / panics anywhere in the boot.
if grep -aE -q "PANIC|panic:|TRAP: vector|^TRAP:|#GP fault|#UD|Page Fault|invalid opcode|^BUG:" "$LOG"; then
    echo "[test_drm_ko] FAIL: TRAP / BUG / PANIC reported"
    grep -aE "PANIC|panic:|TRAP|#GP fault|#UD|Page Fault|invalid opcode|BUG:" "$LOG" | head -10
    fail=1
else
    echo "[test_drm_ko] OK: no traps/panics in boot log"
fi

# 2. No unresolved external symbol / unknown reloc anywhere.
if grep -aF -q "unresolved external symbol" "$LOG"; then
    echo "[test_drm_ko] FAIL: unresolved external symbol reported"
    grep -aF "unresolved external symbol" "$LOG" | head -20
    fail=1
else
    echo "[test_drm_ko] OK: no unresolved external symbols"
fi
if grep -aF -q "unknown reloc type" "$LOG"; then
    echo "[test_drm_ko] FAIL: unknown reloc type reported"
    grep -aF "unknown reloc type" "$LOG" | head
    fail=1
fi

# 3. drm.ko was located + parsed.
if grep -aE -q "kmod_linux: name=drm( |\$)" "$LOG"; then
    echo "[test_drm_ko] OK: kmod_linux: name=drm"
else
    echo "[test_drm_ko] FAIL: drm.ko not loaded (no name=drm marker)"
    fail=1
fi

# 4. Every relocation pass that fired resolved fully (skipped=0).
n_bad_skipped=$( { grep -aE "kmod_linux: relocations applied=" "$LOG" || true; } \
                | { grep -vE 'skipped=0' || true; } | wc -l)
if [ "$n_bad_skipped" -ne 0 ]; then
    echo "[test_drm_ko] FAIL: $n_bad_skipped relocation pass(es) had skipped>0"
    grep -aE "kmod_linux: relocations applied=" "$LOG" | grep -vE 'skipped=0' | head
    fail=1
else
    echo "[test_drm_ko] OK: every relocation pass resolved (skipped=0)"
fi

# 5. The harvest-OK marker fired (drm.ko load returned a valid slot).
if grep -aF -q "[boot:35.DRM] drm.ko harvest OK" "$LOG"; then
    echo "[test_drm_ko] OK: boot:35.DRM drm.ko harvest OK"
else
    echo "[test_drm_ko] FAIL: no '[boot:35.DRM] drm.ko harvest OK' marker"
    fail=1
fi

# 6. drm init_module returned (>=1 'init returned' line between the
#    name=drm marker and the harvest-OK marker).
INIT_OK=$(awk '/kmod_linux: name=drm/,/drm\.ko harvest OK/' "$LOG" \
          | grep -acE "kmod_linux: init returned" || true)
INIT_OK=${INIT_OK:-0}
if [ "$INIT_OK" -ge 1 ]; then
    echo "[test_drm_ko] OK: drm init_module returned (count=$INIT_OK)"
else
    echo "[test_drm_ko] FAIL: no 'init returned' between name=drm and harvest OK (got $INIT_OK)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_drm_ko] FAIL"
    echo "[test_drm_ko] --- full log tail ---"
    tail -120 "$LOG"
    exit 1
fi

echo "[test_drm_ko] PASS (drm.ko loaded; relocations clean skipped=0; init_module returned)"
