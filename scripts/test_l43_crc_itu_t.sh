#!/usr/bin/env bash
# scripts/test_l43_crc_itu_t.sh — L43 crc-itu-t.ko load test.
#
# Goal:
#   Third zero-UND-gap stock Debian library module in the L-track:
#   crc-itu-t.ko. As with crc7.ko (L43) and crc16.ko (L42), the only
#   undefined symbol is __x86_return_thunk, already in exports.ad
#   since L0. Pure "loader exercise" coverage — no new shims.
#
#   The CRC-ITU-T (V.41) polynomial is used by HDLC framing,
#   PPP/HDLC drivers, some PCMCIA drivers, and ISDN/serial layers in
#   Linux. Library-only: kbuild emits the module with NULL .init,
#   so the L1 loader takes the library-only branch and prints
#       kmod_linux: no init function (library-only module)
#   returning the slot index. crc_itu_t_table + crc_itu_t function
#   are live in kernel memory afterwards.
#
# Strategy (mirrors test_l42_crc16.sh / test_l43_crc7.sh):
#   1. Locate /lib/modules/$(uname -r)/kernel/lib/crc-itu-t.ko[.xz];
#      SKIP exit 0 if not present.
#   2. Static-analyse UND symbols vs. linux_abi/.
#   3. Stage under tests/linux-modules/, rebuild userland + initramfs +
#      kernel, boot QEMU, drive hamsh:
#         insmod /lib/modules/6.12/crc-itu-t.ko
#         exit
#   4. PASS bar: EITHER `kmod_linux: init returned 0` OR
#      `kmod_linux: no init function (library-only module)`, no
#      `insmod: init_module failed`.
#
# Per L43 brief: no retry logic, no backwards-compat hacks.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/crc-itu-t.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/lib/crc-itu-t.ko"
    "${HOST_LIB}/lib/crc-itu-t.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L43: crc-itu-t.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l43_crc_itu_t] picked: $picked"

cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$LKM_DIR"
case "$picked" in
    *.ko.xz)
        echo "[test_l43_crc_itu_t] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l43_crc_itu_t] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

echo
echo "[test_l43_crc_itu_t] === Static UND-symbol analysis of crc-itu-t.ko ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l43_crc_itu_t] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l43_crc_itu_t] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l43_crc_itu_t] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l43_crc_itu_t] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none - full coverage)"
    fi
fi

echo
echo "[test_l43_crc_itu_t] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l43_crc_itu_t] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l43_crc_itu_t] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

LOG="$(mktemp)"
echo "[test_l43_crc_itu_t] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/crc-itu-t.ko\n'
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

echo "[test_l43_crc_itu_t] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

echo
echo "[test_l43_crc_itu_t] =============== captured serial (tail) ==============="
tail -n 80 "$LOG" || true
echo "[test_l43_crc_itu_t] ======================================================"
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l43_crc_itu_t] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

if [ ! -s "$LOG" ]; then
    echo "[test_l43_crc_itu_t] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l43_crc_itu_t] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l43_crc_itu_t] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l43_crc_itu_t] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l43_crc_itu_t] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
else
    echo "[test_l43_crc_itu_t] INFO: no runtime unresolved-symbol lines"
fi

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l43_crc_itu_t] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l43_crc_itu_t] PASS: crc-itu-t.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l43_crc_itu_t]       (library-only path - no module_init, table+function live)"
    else
        echo "[test_l43_crc_itu_t]       (init_module returned 0)"
    fi
else
    echo
    echo "[test_l43_crc_itu_t] FAIL: crc-itu-t.ko did not finish loading."
    echo "[test_l43_crc_itu_t]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l43_crc_itu_t] full log preserved at: $LOG"
exit 0
