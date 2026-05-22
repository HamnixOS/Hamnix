#!/usr/bin/env bash
# scripts/test_l43_crc7.sh — L43 crc7.ko load test.
#
# Goal:
#   Extend the L-track ABI coverage with another zero-UND-gap stock
#   Debian library module: crc7.ko. Like crc16.ko (L42), crc7's only
#   undefined symbol is __x86_return_thunk, which exports.ad has
#   carried since L0. So this is a pure "loader produces the right
#   metadata + library-only branch fires" test — no new shims, no
#   new exports.
#
#   crc7 is the 7-bit polynomial CRC used by MMC/SD card commands and
#   a handful of audio codecs in Linux. Library-only: kbuild emits the
#   module without an init_module symbol and with a NULL .init
#   pointer in struct module. The L1 loader's library-only branch
#   (loader.ad ~line 715) recognises this, prints
#       kmod_linux: no init function (library-only module)
#   and returns the slot index directly. From insmod's perspective
#   the syscall returns success; crc7_be_syndrome_table + crc7_be
#   function live in kernel memory for any EXPORT_SYMBOL consumer.
#
# Strategy (mirrors test_l42_crc16.sh):
#   1. Locate /lib/modules/$(uname -r)/kernel/lib/crc7.ko[.xz];
#      SKIP exit 0 if not present.
#   2. Static-analyse: nm -u + cross-check linux_abi/ for predicted
#      missing symbols (L43 should report empty MISSING).
#   3. Stage under tests/linux-modules/, rebuild userland + initramfs +
#      kernel, boot QEMU, drive hamsh:
#         insmod /lib/modules/6.12/crc7.ko
#         exit
#   4. PASS bar: EITHER `kmod_linux: init returned 0` OR
#      `kmod_linux: no init function (library-only module)`, and
#      no `insmod: init_module failed`.
#
# Per the L43 brief: no retry logic, no backwards-compat hacks.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/crc7.ko"

# --- 1. Locate crc7.ko on the host ----------------------------------
KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/lib/crc7.ko"
    "${HOST_LIB}/lib/crc7.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L43: crc7.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l43_crc7] picked: $picked"

cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 2. Stage the .ko -----------------------------------------------
mkdir -p "$LKM_DIR"
case "$picked" in
    *.ko.xz)
        echo "[test_l43_crc7] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l43_crc7] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

# --- 3. Static UND-symbol coverage check ----------------------------
echo
echo "[test_l43_crc7] === Static UND-symbol analysis of crc7.ko ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l43_crc7] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l43_crc7] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l43_crc7] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l43_crc7] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none - full coverage)"
    fi
fi

# --- 4. Build userland + initramfs + kernel -------------------------
echo
echo "[test_l43_crc7] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l43_crc7] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l43_crc7] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# --- 5. Boot QEMU and drive insmod ----------------------------------
LOG="$(mktemp)"
echo "[test_l43_crc7] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/crc7.ko\n'
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

echo "[test_l43_crc7] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

# --- 6. Assertions --------------------------------------------------
echo
echo "[test_l43_crc7] =============== captured serial (tail) ==============="
tail -n 80 "$LOG" || true
echo "[test_l43_crc7] ======================================================"
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l43_crc7] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

if [ ! -s "$LOG" ]; then
    echo "[test_l43_crc7] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l43_crc7] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l43_crc7] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l43_crc7] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l43_crc7] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
else
    echo "[test_l43_crc7] INFO: no runtime unresolved-symbol lines"
fi

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l43_crc7] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l43_crc7] PASS: crc7.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l43_crc7]       (library-only path - no module_init, table+function live)"
    else
        echo "[test_l43_crc7]       (init_module returned 0)"
    fi
else
    echo
    echo "[test_l43_crc7] FAIL: crc7.ko did not finish loading."
    echo "[test_l43_crc7]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l43_crc7] full log preserved at: $LOG"
exit 0
