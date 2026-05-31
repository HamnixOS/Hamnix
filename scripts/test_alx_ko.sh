#!/usr/bin/env bash
# scripts/test_alx_ko.sh — regression guard for the alx.ko load path
# through the L-series loader. Qualcomm Atheros AR8161/AR8162/AR8171/
# AR8172 (Killer E2200 family) — common on Asus/Acer/HP consumer
# laptops/desktops. There's no QEMU emulation for the AR816x silicon,
# so this test exercises the .ko *load* path only — the init_module
# symbol-resolution + relocation pass plus the __pci_register_driver
# invocation. Probe never runs to completion (no matching Atheros PCI
# id on the QEMU bus); __pci_register_driver walks the bus and finds
# no device, which is the documented success bar for a load-only
# harvest.
#
# WHY A KERNEL-SIDE BOOT EXERCISE (not userspace `insmod` over hamsh):
#   The original harness booted hamsh as /init and piped
#   `insmod /lib/modules/alx.ko` over serial stdin. That is
#   timing-fragile: hamsh's line-editor doesn't start consuming stdin
#   until its readline arms (the `[hamsh:stage-08] ed-readline-first`
#   marker), which lands AFTER the first piped line — so the early
#   insmod line was silently dropped and alx.ko never loaded. The
#   kernel's boot:35.ALX path (init/main.ad, gated on /etc/alx-ko)
#   instead drives a single kmod_linux_load directly, with no stdin
#   race. This mirrors the libata/cfg80211/ahci kernel-autoload tests.
#
# NOTE — alx silent-skip: alx.ko may report `skipped=1` even though
# every UND symbol is covered by the shim table. The skipped count
# comes from the L-loader's silent "symbol defined in a non-SHF_ALLOC
# section" path (linux_abi/loader.ad:_sym_addr), NOT from a missing
# shim. We accept skipped<=1 here and pin the upper bound; if the
# count rises a real symbol gap has opened.
#
# Assertions (the harvest bar — "links + init runs", NOT packet I/O):
#   1. `kmod_linux: name=alx`               — .ko bytes located + parsed.
#   2. relocations skipped<=1               — see silent-skip note above.
#   3. `kmod_linux: init returned 0`        — init_module ran clean.
#   4. `[boot:35.ALX] alx.ko harvest OK`    — load returned a valid slot.
#   5. No unresolved external / unknown reloc.
#   6. No CPU traps / kernel BUGs / panics.
#
# SKIPs cleanly (exit 0) if qemu / grub-mkrescue prerequisites are
# absent so the suite stays green on a tooling-less host.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
INIT_ELF=build/user/init.elf

KO_PATH="$PROJ_ROOT/kernel-modules/alx/alx.ko"
KO_SIZE=$(stat -c%s "$KO_PATH" 2>/dev/null || echo 0)
if [ "$KO_SIZE" -lt 100000 ]; then
    echo "[test_alx_ko] FAIL: alx.ko missing or too small (${KO_SIZE} bytes)"
    exit 1
fi
echo "[test_alx_ko] OK: alx.ko present (${KO_SIZE} bytes)"

# --- gap diagnostic (hard fail if any UND symbol is unshimmed) ------
UND_SYMS=$(nm -u "$KO_PATH" 2>/dev/null | awk '{print $2}' | sort -u)
MISSING=""
for sym in $UND_SYMS; do
    if ! grep -rq "_add_export(\"${sym}\"" linux_abi/ 2>/dev/null; then
        MISSING+=" $sym"
    fi
done
TOTAL_UND=$(echo "$UND_SYMS" | wc -w)
TOTAL_MISSING=$(echo "$MISSING" | wc -w)
echo "[test_alx_ko] UND total=$TOTAL_UND missing=$TOTAL_MISSING"
if [ -n "$MISSING" ]; then
    for s in $MISSING; do echo "  - $s"; done
    echo "[test_alx_ko] FAIL: $TOTAL_MISSING UND symbol(s) unshimmed"
    exit 1
fi

# --- prerequisite gate (clean SKIP) ---------------------------------
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "[test_alx_ko] SKIP: qemu-system-x86_64 not available"
    exit 0
fi
if ! command -v grub-mkrescue >/dev/null 2>&1; then
    echo "[test_alx_ko] SKIP: grub-mkrescue not available (kernel is ELF64; needs the ISO shim)"
    exit 0
fi

echo "[test_alx_ko] (1/3) Build userland + modules + initramfs (alx marker)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
ENABLE_ALX_KO=1 INIT_ELF="$INIT_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_alx_ko] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

if [ ! -s "$ELF" ]; then
    echo "[test_alx_ko] FAIL: kernel ELF missing"
    INIT_ELF="$INIT_ELF" python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
    exit 1
fi
echo "[test_alx_ko] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"

echo "[test_alx_ko] (3/3) Boot QEMU; kernel-side boot:35.ALX drives the load"
LOG=$(mktemp)
# Restore the default initramfs on exit so a later test isn't surprised
# by the alx marker leaking into its image.
trap 'rm -f "$LOG"; INIT_ELF="'"$INIT_ELF"'" python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# init.elf never exits, so qemu runs until the timeout. The boot:35.ALX
# exercise fires at ~boot:35 (well before the timeout). No stdin needed
# — the load is kernel-driven.
set +e
timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    < /dev/null > "$LOG" 2>&1
rc=$?
set -e
# rc=124 (timeout) is EXPECTED — init.elf is a long-running PID 1.
echo "[test_alx_ko] qemu exited rc=$rc (124=timeout, expected for long-running init)"
cp "$LOG" /tmp/test_alx_ko.last.log 2>/dev/null || true

echo "[test_alx_ko] --- captured (boot:35.ALX / kmod / alx) ---"
grep -aE 'boot:35.ALX|\[alx\.ko\]|kmod_linux: (name=alx|relocations applied|init returned|unresolved external|unknown reloc)|\[pci_register_driver\]' "$LOG" | head -40 || true
echo "[test_alx_ko] --- end ---"

fail=0

if grep -aE -q "PANIC|panic:|TRAP: vector|^TRAP:|#GP fault|#UD|Page Fault|invalid opcode|^BUG:" "$LOG"; then
    echo "[test_alx_ko] FAIL: TRAP / BUG / PANIC reported"
    grep -aE "PANIC|panic:|TRAP|#GP fault|#UD|Page Fault|invalid opcode|BUG:" "$LOG" | head -10
    fail=1
else
    echo "[test_alx_ko] OK: no traps/panics in boot log"
fi

if grep -aF -q "unresolved external symbol" "$LOG"; then
    echo "[test_alx_ko] FAIL: unresolved external symbol reported"
    grep -aF "unresolved external symbol" "$LOG" | head -20
    fail=1
else
    echo "[test_alx_ko] OK: no unresolved external symbols"
fi
if grep -aF -q "unknown reloc type" "$LOG"; then
    echo "[test_alx_ko] FAIL: unknown reloc type reported"
    grep -aF "unknown reloc type" "$LOG" | head
    fail=1
fi

if grep -aE -q "kmod_linux: name=alx( |\$)" "$LOG"; then
    echo "[test_alx_ko] OK: kmod_linux: name=alx"
else
    echo "[test_alx_ko] FAIL: alx.ko was not loaded (no 'kmod_linux: name=alx' marker)"
    fail=1
fi

# alx is the documented silent-skip outlier: skipped<=1 is acceptable
# (a defined symbol references a non-SHF_ALLOC section — see loader.ad
# header note); skipped>=2 means a real new gap.
RELOC_LINE=$(awk '/kmod_linux: name=alx$|kmod_linux: name=alx /,/kmod_linux: init returned/' "$LOG" | grep -aE 'kmod_linux: relocations applied=' | tail -1)
if [ -z "$RELOC_LINE" ]; then
    echo "[test_alx_ko] FAIL: no relocation summary found between name=alx and init returned"
    fail=1
else
    SKIPPED=$(echo "$RELOC_LINE" | grep -oE 'skipped=[0-9]+' | cut -d= -f2)
    APPLIED=$(echo "$RELOC_LINE" | grep -oE 'applied=[0-9]+' | cut -d= -f2)
    if [ "${SKIPPED:-99}" -le 1 ]; then
        echo "[test_alx_ko] OK: relocations applied=$APPLIED skipped=$SKIPPED (alx silent-skip tolerance: skipped<=1)"
    else
        echo "[test_alx_ko] FAIL: alx.ko had skipped=${SKIPPED} relocations (applied=${APPLIED}); tolerance is <=1"
        fail=1
    fi
fi

INIT_LINE=$(awk '/kmod_linux: name=alx$|kmod_linux: name=alx /,EOF' "$LOG" | grep -aE 'kmod_linux: init returned' | head -1)
if [ -z "$INIT_LINE" ]; then
    echo "[test_alx_ko] FAIL: no 'kmod_linux: init returned' marker after name=alx"
    fail=1
elif echo "$INIT_LINE" | grep -qE 'init returned 0'; then
    echo "[test_alx_ko] OK: init_module returned 0 ($INIT_LINE)"
else
    echo "[test_alx_ko] FAIL: init_module non-zero ($INIT_LINE)"
    fail=1
fi

if grep -aF -q "[boot:35.ALX] alx.ko harvest OK" "$LOG"; then
    echo "[test_alx_ko] OK: boot:35.ALX alx.ko harvest OK"
else
    echo "[test_alx_ko] FAIL: no '[boot:35.ALX] alx.ko harvest OK' marker"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_alx_ko] FAIL (qemu rc=$rc)"
    echo "[test_alx_ko] --- full log tail ---"
    tail -120 "$LOG"
    exit 1
fi

echo "[test_alx_ko] PASS (.ko loaded; relocations clean; init_module returned 0)"
