#!/usr/bin/env bash
# scripts/test_l50_crypto_null.sh — L50 crypto_null.ko load test.
#
# See linux_abi/api_l50.ad for the full L50 design notes covering all
# seven crypto modules shipped in this batch.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/crypto_null.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/crypto/crypto_null.ko"
    "${HOST_LIB}/crypto/crypto_null.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L50: crypto_null.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l50_crypto_null] picked: $picked"

cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$LKM_DIR"
case "$picked" in
    *.ko.xz)
        echo "[test_l50_crypto_null] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l50_crypto_null] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

echo
echo "[test_l50_crypto_null] === Static UND-symbol analysis ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l50_crypto_null] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l50_crypto_null] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l50_crypto_null] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l50_crypto_null] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none - full coverage)"
    fi
fi

echo
echo "[test_l50_crypto_null] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l50_crypto_null] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l50_crypto_null] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

LOG="$(mktemp)"
echo "[test_l50_crypto_null] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/crypto_null.ko\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
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

echo "[test_l50_crypto_null] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

echo
echo "[test_l50_crypto_null] =============== captured serial (tail) ==============="
tail -n 120 "$LOG" || true
echo "[test_l50_crypto_null] ======================================================"
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l50_crypto_null] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

if [ ! -s "$LOG" ]; then
    echo "[test_l50_crypto_null] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l50_crypto_null] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l50_crypto_null] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l50_crypto_null] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l50_crypto_null] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
else
    echo "[test_l50_crypto_null] INFO: no runtime unresolved-symbol lines"
fi

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l50_crypto_null] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l50_crypto_null] PASS: crypto_null.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l50_crypto_null]       (library-only path)"
    else
        echo "[test_l50_crypto_null]       (init_module returned 0)"
    fi
else
    echo
    echo "[test_l50_crypto_null] FAIL: crypto_null.ko did not finish loading."
    echo "[test_l50_crypto_null]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l50_crypto_null] full log preserved at: $LOG"
exit 0
