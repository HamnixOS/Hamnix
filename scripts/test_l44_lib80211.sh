#!/usr/bin/env bash
# scripts/test_l44_lib80211.sh — L44 lib80211.ko load test.
#
# Goal:
#   Ship Hamnix's first non-zero-gap stock Debian .ko load. lib80211.ko
#   is the 802.11 crypto-ops registration core. Stock Debian 6.12
#   ships it with 17 UND symbols; L43 left 9 unresolved against
#   linux_abi/exports.ad. L44 closes that gap via the new
#   linux_abi/api_lib80211.ad:
#
#     __list_add_valid_or_report           function (returns 1; caller
#                                          has already wired the list)
#     __list_del_entry_valid_or_report     function (unlinks + true)
#     __x86_indirect_thunk_rax             function (pop rbp; jmp *rax)
#     module_put                           function (no-op)
#     add_timer                            function (records arm)
#     init_timer_key                       function (writes fn into
#                                          timer->function)
#     __kmalloc_cache_noprof               function (forwards to
#                                          mm.slab.kmalloc)
#     jiffies                              DATA — addr of the
#                                          arch/x86/kernel/time.ad
#                                          tick counter
#     kmalloc_caches                       DATA — 832 zero bytes
#                                          (4 * 26 * 8 = TYPES*SHIFTS*ptr)
#
#   Init path (.init.text): _printk + tail-jmp to
#   lib80211_register_crypto_ops, which kmallocs a 0x18-byte slot,
#   spin_lock_irqsave / __list_add_valid_or_report / unlock, _printk,
#   return 0. Every one of those symbols now resolves through
#   linux_abi/exports.ad.
#
# Strategy (mirrors test_l43_crc7.sh):
#   1. Locate /lib/modules/$(uname -r)/kernel/net/wireless/lib80211.ko[.xz];
#      SKIP exit 0 if not present.
#   2. Static-analyse: nm -u + cross-check linux_abi/ — L44 should
#      report MISSING = (none).
#   3. Stage under tests/linux-modules/, rebuild userland + initramfs +
#      kernel, boot QEMU, drive hamsh:
#         insmod /lib/modules/6.12/lib80211.ko
#         exit
#   4. PASS bar: EITHER `kmod_linux: init returned 0` OR
#      `kmod_linux: no init function (library-only module)`, and
#      no `insmod: init_module failed`. lib80211 HAS an init_module
#      so the live path is the first branch.
#
# Per the brief: no retry logic, no backwards-compat hacks. FAIL with
# diagnostic on first unresolved symbol or non-zero init return.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/lib80211.ko"

# --- 1. Locate lib80211.ko on the host ------------------------------
KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/net/wireless/lib80211.ko"
    "${HOST_LIB}/net/wireless/lib80211.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L44: lib80211.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l44] picked: $picked"

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
        echo "[test_l44] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l44] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

# --- 3. Static UND-symbol coverage check ----------------------------
echo
echo "[test_l44] === Static UND-symbol analysis of lib80211.ko ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l44] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l44] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l44] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l44] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none - full coverage)"
    fi
fi

# --- 4. Build userland + initramfs + kernel -------------------------
echo
echo "[test_l44] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l44] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l44] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# --- 5. Boot QEMU and drive insmod ----------------------------------
LOG="$(mktemp)"
echo "[test_l44] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/lib80211.ko\n'
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

echo "[test_l44] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

# --- 6. Assertions --------------------------------------------------
echo
echo "[test_l44] =============== captured serial (tail) ==============="
tail -n 100 "$LOG" || true
echo "[test_l44] ======================================================"
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l44] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

if [ ! -s "$LOG" ]; then
    echo "[test_l44] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l44] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l44] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l44] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l44] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
    echo "[test_l44] INFO: distinct symbol names from runtime log:"
    echo "$UNRESOLVED" \
        | grep -oE "'[A-Za-z_][A-Za-z0-9_]*'|symbol [A-Za-z_][A-Za-z0-9_]*|: [A-Za-z_][A-Za-z0-9_]+$" \
        | sort -u \
        | sed 's/^/  /'
else
    echo "[test_l44] INFO: no runtime unresolved-symbol lines"
fi

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l44] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l44] PASS: lib80211.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l44]       (library-only path)"
    else
        echo "[test_l44]       (init_module returned 0 — first non-zero-gap distro module!)"
    fi
else
    echo
    echo "[test_l44] FAIL: lib80211.ko did not finish loading."
    echo "[test_l44]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l44] full log preserved at: $LOG"
exit 0
