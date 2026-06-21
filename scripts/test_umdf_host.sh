#!/usr/bin/env bash
# scripts/test_umdf_host.sh — Track 4 first vertical slice gate.
#
# Proves that a stock-shape Linux ET_REL `.ko` loads + initializes OUTSIDE
# the kernel fault domain, in a restartable USERLAND host process, and that
# the kernel-provided privileged primitives (DMA alloc, IRQ file) work —
# and that the kernel SURVIVES a driver-host crash, then re-inits a fresh
# host afterward.
#
# Driven DETERMINISTICALLY from /etc/hamsh.rc (sourced by hamsh-as-PID-1),
# so the assertions don't race serial latency / boot-time .ko-load spam.
#
# WHAT IT EXERCISES (all from the rc, in order):
#   1. USERLAND .ko LOAD:
#        umdf_host /lib/modules/6.12/umdf_probe.ko
#      -> [umdf-host] MODULE INITIALIZED IN USERLAND   (ELF parse + reloc +
#         symbol resolve + init_module(), all in CPL3, .ko in mmap'd RAM)
#   2. PRIVILEGED PRIMITIVES:
#        umdf_host selftest-dma 0x1000   -> DMA PRIMITIVE OK
#        umdf_host selftest-irq 0x60     -> IRQ PRIMITIVE OK
#   3. CRASH ISOLATION (the whole point):
#        umdf_host crashme               -> host derefs NULL and dies
#        echo UMDF-KERNEL-SURVIVED-CRASH -> kernel + hamsh SURVIVE
#   4. RESTARTABILITY: a second umdf_host load after the crash re-inits.
#
# The probe `.ko` is built HERMETICALLY from the tracked Adder source
# kernel-modules/m2-string/m2_string.ad via the in-tree Adder compiler's
# x86_64-linux-kernel-module target + `as` — no Linux kernel tree needed.
# It is a genuine stock ET_REL object: GLOBAL init_module/cleanup_module,
# an UND `_printk`, .rodata, and R_X86_64_PC32 / R_X86_64_PLT32 relocs.
#
# Pass marker:  [test_umdf_host] PASS
# Fail marker:  [test_umdf_host] FAIL
# rc=124 (timeout) is judged by serial-log content (slow-host tolerant).

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
KO=/lib/modules/6.12/umdf_probe.ko

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
file "$PROBE_KO" | grep -q "relocatable" || fail "probe .ko not ET_REL"
readelf -sW "$PROBE_KO" | grep -q "init_module" || fail "probe .ko has no init_module"
echo "[test_umdf_host]   probe .ko OK ($(stat -c%s "$PROBE_KO") bytes)"

# --- 2. The driving rc -----------------------------------------------
RC_TMP="$(mktemp /tmp/hamsh-rc-umdf.XXXXXX.rc)"
cat > "$RC_TMP" <<EOF
echo UMDF_RC_START
umdf_host $KO
umdf_host selftest-dma 0x1000
umdf_host selftest-irq 0x60
umdf_host crashme
echo UMDF-KERNEL-SURVIVED-CRASH
umdf_host $KO
echo UMDF_RC_DONE
EOF

cleanup() {
    rm -f "$PROBE_KO" "$RC_TMP"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 3. Build userland (incl. umdf_host) -----------------------------
echo "[test_umdf_host] (2/5) Build userland (init, hamsh, umdf_host)"
bash scripts/build_user.sh >/dev/null || fail "build_user"
[ -f build/user/umdf_host.elf ] || fail "umdf_host.elf not built"

# --- 4. Initramfs: hamsh as init + probe .ko staged + the rc ---------
echo "[test_umdf_host] (3/5) Build initramfs (hamsh as /init, probe .ko + rc)"
HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null || fail "build_initramfs"

# --- 5. Kernel + boot ------------------------------------------------
echo "[test_umdf_host] (4/5) Build kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null || fail "kernel compile"

echo "[test_umdf_host] (5/5) Boot QEMU; the rc drives the slice"
LOG="$(mktemp /tmp/test-umdf.XXXXXX.log)"
trap 'rm -f "$LOG" "$PROBE_KO" "$RC_TMP"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# hamsh sources /etc/hamsh.rc automatically as PID 1; after the rc runs we
# feed `exit` over serial to end the boot cleanly. A generous wait lets the
# boot-time .ko loads drain first.
set +e
(
    sleep 18
    printf 'exit\n'
    sleep 2
) | timeout 150s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e
echo "[test_umdf_host] qemu rc=$rc"

# --- assertions (judged by serial-log content) -----------------------
PASS=1
need() {
    if ! grep -q "$1" "$LOG"; then
        echo "[test_umdf_host] MISS: $2"
        PASS=0
    fi
}
need "UMDF_RC_START"                  "rc did not start (boot/hamsh.rc broken)"
need "loaded .ko in USERLAND at va="  "userland load marker"
need "MODULE INITIALIZED IN USERLAND" "userland .ko init marker"
need "DMA PRIMITIVE OK"               "DMA primitive"
need "IRQ PRIMITIVE OK"               "IRQ primitive"
need "crashme: about to dereference NULL" "crashme entry"
need "UMDF-KERNEL-SURVIVED-CRASH"     "kernel did NOT survive host crash"

if grep -qiE "kernel panic|triple fault|HALT THE BOX|PANIC:" "$LOG"; then
    echo "[test_umdf_host] kernel panic/fault in log"; PASS=0
fi
INIT_COUNT=$(grep -c "MODULE INITIALIZED IN USERLAND" "$LOG")
if [ "${INIT_COUNT:-0}" -lt 2 ]; then
    echo "[test_umdf_host] MISS: host did not restart after crash (inits=$INIT_COUNT)"
    PASS=0
fi

echo "----- captured serial (umdf / kmod / UMDF lines) -----"
grep -aE "umdf|UMDF|kmod_linux: init returned" "$LOG" | head -50
echo "------------------------------------------------------"

if [ "$PASS" = 1 ]; then
    echo "[test_umdf_host] PASS"
    exit 0
fi
echo "[test_umdf_host] FAIL"
exit 1
