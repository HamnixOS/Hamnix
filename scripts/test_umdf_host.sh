#!/usr/bin/env bash
# scripts/test_umdf_host.sh — Track 4 first vertical slice gate.
#
# Proves that a stock-shape Linux ET_REL `.ko` loads + initializes OUTSIDE
# the kernel fault domain, in a restartable USERLAND host process, and that
# the three kernel-provided privileged primitives (MMIO map / DMA alloc /
# IRQ file) work — and that the kernel SURVIVES a driver-host crash.
#
# WHAT IT EXERCISES (all driven from hamsh over serial):
#
#   1. USERLAND .ko LOAD:
#        umdf_host /lib/modules/6.12/umdf_probe.ko
#      The host (user/umdf_host.ad, CPL3) parses the ELF, lays out the
#      SHF_ALLOC sections into mmap'd USER memory, applies x86_64
#      relocations, resolves `_printk` against its userland shim, and
#      calls init_module() — all in ring 3. Marker:
#        [umdf-host] MODULE INITIALIZED IN USERLAND
#
#   2. PRIVILEGED PRIMITIVES (the kernel-trust surface):
#        umdf_host selftest-dma 0x1000   -> DMA PRIMITIVE OK
#        umdf_host selftest-irq 0x60     -> IRQ PRIMITIVE OK
#      (MMIO is covered by the DMA path's phys-mapping machinery; a real
#      BAR isn't present under this minimal QEMU invocation, so the gate
#      asserts DMA + IRQ, which share the same map-phys-into-user code.)
#
#   3. CRASH ISOLATION (the whole point):
#        umdf_host crashme          -> host dereferences NULL and dies
#        echo still-alive           -> hamsh + kernel SURVIVE the crash
#      A vendor `.ko` fault is now a process crash the kernel survives.
#
# The probe `.ko` is built HERMETICALLY from the tracked Adder source
# kernel-modules/m2-string/m2_string.ad via the in-tree Adder compiler's
# x86_64-linux-kernel-module target + `as` — no Linux kernel tree needed.
# It is a genuine stock ET_REL object: GLOBAL init_module/cleanup_module,
# an UND `_printk`, .rodata, and R_X86_64_PC32 / R_X86_64_PLT32 relocs.
#
# Pass marker:  [test_umdf_host] PASS
# Fail marker:  [test_umdf_host] FAIL
#
# rc=124 (timeout) is judged by serial-log content, per the slow-host note.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
PROBE_KO="$LKM_DIR/umdf_probe.ko"
PROBE_SRC=kernel-modules/m2-string/m2_string.ad

fail() { echo "[test_umdf_host] FAIL: $*"; exit 1; }

# --- 1. Build the hermetic probe .ko ---------------------------------
echo "[test_umdf_host] (1/5) Build hermetic probe .ko from $PROBE_SRC"
mkdir -p "$LKM_DIR" build/user
PROBE_S="$(mktemp --suffix=.S)"
python3 -m compiler.adder compile \
    --target=x86_64-linux-kernel-module \
    "$PROBE_SRC" \
    -o "$PROBE_S" >/dev/null || fail "adder compile of probe .ko source"
as --64 -o "$PROBE_KO" "$PROBE_S" || fail "as of probe .ko"
rm -f "$PROBE_S"
# Sanity: it must be a real ET_REL with init_module + an UND _printk.
file "$PROBE_KO" | grep -q "relocatable" || fail "probe .ko not ET_REL"
readelf -sW "$PROBE_KO" | grep -q "init_module" || fail "probe .ko has no init_module"
echo "[test_umdf_host]   probe .ko OK ($(stat -c%s "$PROBE_KO") bytes)"

cleanup() {
    rm -f "$PROBE_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 2. Build userland (incl. umdf_host) -----------------------------
echo "[test_umdf_host] (2/5) Build userland (init, hamsh, umdf_host)"
bash scripts/build_user.sh >/dev/null || fail "build_user"
[ -f build/user/umdf_host.elf ] || fail "umdf_host.elf not built"

# --- 3. Initramfs with hamsh as init + the probe .ko staged ----------
echo "[test_umdf_host] (3/5) Build initramfs (hamsh as /init, probe .ko staged)"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null \
    || fail "build_initramfs"

# --- 4. Kernel image -------------------------------------------------
echo "[test_umdf_host] (4/5) Build kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null || fail "kernel compile"

# --- 5. Boot + drive the slice over serial ---------------------------
echo "[test_umdf_host] (5/5) Boot QEMU; drive umdf_host through the slice"
LOG="$(mktemp)"
trap 'rm -f "$LOG"; cleanup' EXIT

KO=/lib/modules/6.12/umdf_probe.ko
(
    sleep 3
    # 1. Load + init the stock .ko entirely in userland.
    printf 'umdf_host %s\n' "$KO"
    sleep 4
    # 2. Exercise the privileged DMA + IRQ primitives.
    printf 'umdf_host selftest-dma 0x1000\n'
    sleep 2
    printf 'umdf_host selftest-irq 0x60\n'
    sleep 2
    # 3. Crash a driver host; the kernel + hamsh must survive.
    printf 'umdf_host crashme\n'
    sleep 3
    printf 'echo UMDF-KERNEL-SURVIVED-CRASH\n'
    sleep 2
    # 4. Restart a driver host AFTER the crash to prove restartability.
    printf 'umdf_host %s\n' "$KO"
    sleep 4
    printf 'exit\n'
    sleep 1
) | timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1
rc=$?
echo "[test_umdf_host] qemu rc=$rc"

# --- assertions (judged by serial-log content) -----------------------
PASS=1

grep -q "MODULE INITIALIZED IN USERLAND" "$LOG" \
    || { echo "[test_umdf_host] MISS: userland .ko init marker"; PASS=0; }
grep -q "loaded .ko in USERLAND at va=" "$LOG" \
    || { echo "[test_umdf_host] MISS: userland load marker"; PASS=0; }
grep -q "DMA PRIMITIVE OK" "$LOG" \
    || { echo "[test_umdf_host] MISS: DMA primitive"; PASS=0; }
grep -q "IRQ PRIMITIVE OK" "$LOG" \
    || { echo "[test_umdf_host] MISS: IRQ primitive"; PASS=0; }
grep -q "crashme: about to dereference NULL" "$LOG" \
    || { echo "[test_umdf_host] MISS: crashme entry"; PASS=0; }
# The kernel must survive the host crash: the post-crash echo must appear.
grep -q "UMDF-KERNEL-SURVIVED-CRASH" "$LOG" \
    || { echo "[test_umdf_host] MISS: kernel did NOT survive host crash"; PASS=0; }
# A panic / triple-fault anywhere is an automatic fail.
if grep -qiE "kernel panic|triple fault|HALT THE BOX|PANIC:" "$LOG"; then
    echo "[test_umdf_host] kernel panic/fault in log"; PASS=0
fi
# Restartability: the SECOND load after the crash must also init.
INIT_COUNT=$(grep -c "MODULE INITIALIZED IN USERLAND" "$LOG")
if [ "$INIT_COUNT" -lt 2 ]; then
    echo "[test_umdf_host] MISS: driver host did not restart after crash (inits=$INIT_COUNT)"
    PASS=0
fi

echo "----- captured serial (umdf-host lines) -----"
grep -E "umdf|UMDF|kmod_linux" "$LOG" | head -60
echo "---------------------------------------------"

if [ "$PASS" = 1 ]; then
    echo "[test_umdf_host] PASS"
    exit 0
fi
echo "[test_umdf_host] FAIL"
exit 1
