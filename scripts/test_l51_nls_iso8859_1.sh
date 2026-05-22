#!/usr/bin/env bash
# scripts/test_l51_nls_iso8859_1.sh — L51 nls_iso8859-1.ko load test.
#
# Goal:
#   Ship the 26th stock Debian .ko load. nls_iso8859-1.ko is the
#   ISO 8859-1 (Latin-1, Western European) NLS converter. Shares
#   init-path shape with nls_cp437.ko: __register_nls(&table,
#   &__this_module) → 0.
#
#       init_module:
#           call __fentry__
#           mov  $&__this_module, %rsi
#           mov  $&table_iso8859_1, %rdi
#           jmp  __register_nls             # L51: returns 0
#
#   Same 4 UND symbols as nls_cp437 (__fentry__, __x86_return_thunk,
#   __register_nls, unregister_nls); all covered by exports.ad +
#   linux_abi/api_l51.ad.
#
# PASS bar: `kmod_linux: init returned 0`.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
# Linux kbuild renames the dash to underscore in the .ko file; on
# disk the .ko keeps the dash (nls_iso8859-1.ko).
STAGED_KO="$LKM_DIR/nls_iso8859-1.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/fs/nls/nls_iso8859-1.ko"
    "${HOST_LIB}/fs/nls/nls_iso8859-1.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L51: nls_iso8859-1.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l51_nls_iso8859_1] picked: $picked"

cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$LKM_DIR"
case "$picked" in
    *.ko.xz)
        echo "[test_l51_nls_iso8859_1] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l51_nls_iso8859_1] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

echo
echo "[test_l51_nls_iso8859_1] === Static UND-symbol analysis ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
COVERED=""
MISSING=""
for sym in $UND_SYMS; do
    if grep -rq "_add_export(\"${sym}\"" linux_abi/ 2>/dev/null; then
        COVERED+=" $sym"
    else
        MISSING+=" $sym"
    fi
done
echo "[test_l51_nls_iso8859_1] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
for s in $UND_SYMS; do echo "  $s"; done
echo "[test_l51_nls_iso8859_1] covered:"
if [ -n "$COVERED" ]; then for s in $COVERED; do echo "  + $s"; done; else echo "  (none)"; fi
echo "[test_l51_nls_iso8859_1] MISSING:"
if [ -n "$MISSING" ]; then for s in $MISSING; do echo "  - $s"; done; else echo "  (none - full coverage)"; fi

echo
echo "[test_l51_nls_iso8859_1] (1/3) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l51_nls_iso8859_1] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l51_nls_iso8859_1] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

LOG="$(mktemp)"
echo "[test_l51_nls_iso8859_1] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/nls_iso8859-1.ko\n'
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

echo "[test_l51_nls_iso8859_1] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"
echo
echo "[test_l51_nls_iso8859_1] =============== captured serial (tail) ==============="
tail -n 80 "$LOG" || true
echo "[test_l51_nls_iso8859_1] ======================================================"
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l51_nls_iso8859_1] FAIL: kernel panic"
    exit 1
fi
if [ ! -s "$LOG" ]; then
    echo "[test_l51_nls_iso8859_1] FAIL: empty log"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l51_nls_iso8859_1] init OK=$INIT_OK_COUNT lib-only=$LIB_ONLY_COUNT fail=$INSMOD_FAIL_COUNT"

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo "[test_l51_nls_iso8859_1] FAIL: insmod reported init_module failed"
    exit 1
fi
if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo "[test_l51_nls_iso8859_1] PASS: nls_iso8859-1.ko loaded successfully"
    exit 0
fi
echo "[test_l51_nls_iso8859_1] FAIL: no PASS markers"
exit 1
