#!/usr/bin/env bash
# scripts/test_l50_curve25519_generic.sh — L50 curve25519-generic.ko load test.
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
STAGED_KO="$LKM_DIR/curve25519-generic.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/crypto/curve25519-generic.ko"
    "${HOST_LIB}/crypto/curve25519-generic.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L50: curve25519-generic.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l50_curve25519_generic] picked: $picked"

cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$LKM_DIR"
case "$picked" in
    *.ko.xz)
        echo "[test_l50_curve25519_generic] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l50_curve25519_generic] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

echo
echo "[test_l50_curve25519_generic] === Static UND-symbol analysis ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l50_curve25519_generic] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l50_curve25519_generic] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l50_curve25519_generic] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l50_curve25519_generic] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none - full coverage)"
    fi
fi

echo
echo "[test_l50_curve25519_generic] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l50_curve25519_generic] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l50_curve25519_generic] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

LOG="$(mktemp)"
echo "[test_l50_curve25519_generic] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/curve25519-generic.ko\n'
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

echo "[test_l50_curve25519_generic] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

echo
echo "[test_l50_curve25519_generic] =============== captured serial (tail) ==============="
tail -n 120 "$LOG" || true
echo "[test_l50_curve25519_generic] ======================================================"
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l50_curve25519_generic] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

if [ ! -s "$LOG" ]; then
    echo "[test_l50_curve25519_generic] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l50_curve25519_generic] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l50_curve25519_generic] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l50_curve25519_generic] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l50_curve25519_generic] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
else
    echo "[test_l50_curve25519_generic] INFO: no runtime unresolved-symbol lines"
fi

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l50_curve25519_generic] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l50_curve25519_generic] PASS: curve25519-generic.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l50_curve25519_generic]       (library-only path)"
    else
        echo "[test_l50_curve25519_generic]       (init_module returned 0)"
    fi
else
    echo
    echo "[test_l50_curve25519_generic] FAIL: curve25519-generic.ko did not finish loading."
    echo "[test_l50_curve25519_generic]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l50_curve25519_generic] full log preserved at: $LOG"
exit 0
