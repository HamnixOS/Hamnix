#!/usr/bin/env bash
# scripts/test_l42_crc16.sh — L42 crc16.ko load test.
#
# Goal:
#   Extend the L-track ABI coverage to ANOTHER stock Debian library
#   module: crc16.ko. Picked because of all the .ko's surveyed against
#   the current 212-symbol export table, crc16 has the smallest UND
#   gap of any module not yet shipped: zero. Its single UND symbol is
#   __x86_return_thunk, which exports.ad has carried since L0.
#
#   crc16 is library-only (no module_init); kbuild emits the module
#   without an init_module symbol and with a NULL .init pointer inside
#   struct module. The L1 loader's library-only branch (loader.ad
#   line ~715) recognises that, prints
#     kmod_linux: no init function (library-only module)
#   and returns the slot index (>= 0) directly. From insmod's
#   perspective the syscall returns success and the module's
#   crc16_table + crc16 function pointer are live in kernel memory,
#   ready to be called by any future module that EXPORT_SYMBOLs them.
#
#   This mirrors how crc8.ko shipped under the L30 sniff-test pathway,
#   except now we have a dedicated PASS/FAIL bar wired into the
#   regression suite. After L42 the stock-Debian .ko set Hamnix can
#   load with no errors is:
#     crc8, crc16, crc32c_generic, libcrc32c, nf_defrag_ipv4 — five.
#
#   Why crc16 and not crc7 / crc-itu-t (also zero-gap)?  All three are
#   morally equivalent; crc16 is the most-used in real Debian
#   filesystems (used by Bluetooth HCI, T10-PI, several SCSI ULDs),
#   so picking it first puts the broader stack one step closer to
#   working. crc7/crc-itu-t are equally valid follow-ups in L43+.
#
# Strategy (mirrors test_l41_nf_defrag_ipv4.sh):
#   1. Locate /lib/modules/$(uname -r)/kernel/lib/crc16.ko[.xz];
#      SKIP exit 0 if not present.
#   2. Static-analyse: nm -u + cross-check linux_abi/ for predicted
#      missing symbols (L42 should report empty MISSING).
#   3. Stage under tests/linux-modules/, rebuild userland + initramfs +
#      kernel, boot QEMU, drive hamsh:
#         insmod /lib/modules/6.12/crc16.ko
#         exit
#   4. Assertions:
#         a. NO kernel panic.
#         b. Log non-empty (QEMU actually booted).
#         c. EITHER `kmod_linux: init returned 0` (if kbuild surprised
#            us with an init wrapper) OR `kmod_linux: no init function
#            (library-only module)` (the expected library-only path).
#            insmod must NOT print "init_module failed".
#         d. INFO: harvest any runtime unresolved-symbol lines.
#
# Failure of (c) without panic is reported as FAIL (real PASS bar) —
# only true panics / boot failures escalate further. Per the L42
# brief, no retry logic and no backwards-compat hacks.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/crc16.ko"

# --- 1. Locate crc16.ko on the host ---------------------------------
KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/lib/crc16.ko"
    "${HOST_LIB}/lib/crc16.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L42: crc16.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l42] picked: $picked"

# Cleanup: drop staged .ko and rebuild default initramfs on exit.
cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 2. Stage the .ko ------------------------------------------------
mkdir -p "$LKM_DIR"
case "$picked" in
    *.ko.xz)
        echo "[test_l42] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l42] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

# --- 3. Static UND-symbol coverage check ----------------------------
echo
echo "[test_l42] === Static UND-symbol analysis of crc16.ko ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l42] WARN: nm -u produced no symbols (module stripped?)"
else
    COVERED=""
    MISSING=""
    for sym in $UND_SYMS; do
        if grep -rq "_add_export(\"${sym}\"" linux_abi/ 2>/dev/null; then
            COVERED+=" $sym"
        else
            MISSING+=" $sym"
        fi
    done
    echo "[test_l42] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l42] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l42] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none — full coverage)"
    fi
fi

# --- 4. Build userland + initramfs + kernel --------------------------
echo
echo "[test_l42] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l42] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l42] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# --- 5. Boot QEMU and drive insmod -----------------------------------
LOG="$(mktemp)"
echo "[test_l42] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/crc16.ko\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
qrc=$?
set -e

echo "[test_l42] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

# --- 6. Assertions ---------------------------------------------------
echo
echo "[test_l42] =============== captured serial (tail) ==============="
tail -n 80 "$LOG" || true
echo "[test_l42] ======================================================"
echo

# a. PANIC = hard fail.
if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l42] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

# b. Empty log = qemu never ran.
if [ ! -s "$LOG" ]; then
    echo "[test_l42] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

# c. Either "init returned 0" (full init path) OR "no init function
#    (library-only module)" (the expected crc16 path) counts as success.
INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l42] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l42] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l42] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

# d. Unresolved-symbol harvest from runtime log.
UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l42] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
    echo "[test_l42] INFO: distinct symbol names from runtime log:"
    echo "$UNRESOLVED" \
        | grep -oE "'[A-Za-z_][A-Za-z0-9_]*'|symbol [A-Za-z_][A-Za-z0-9_]*|: [A-Za-z_][A-Za-z0-9_]+$" \
        | sort -u \
        | sed 's/^/  /'
else
    echo "[test_l42] INFO: no runtime unresolved-symbol lines"
fi

# Outcome decision.
if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l42] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l42] PASS: crc16.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l42]       (library-only path — no module_init, table+function live)"
    else
        echo "[test_l42]       (init_module returned 0)"
    fi
else
    echo
    echo "[test_l42] FAIL: crc16.ko did not finish loading."
    echo "[test_l42]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l42] full log preserved at: $LOG"
exit 0
