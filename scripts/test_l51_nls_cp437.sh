#!/usr/bin/env bash
# scripts/test_l51_nls_cp437.sh — L51 nls_cp437.ko load test.
#
# Goal:
#   Ship the 25th stock Debian .ko load. nls_cp437.ko is the
#   IBM PC codepage 437 (the original DOS character set) Native
#   Language Support table — used by FAT/iso9660/joliet for filename
#   round-trip. The module registers a single struct nls_table
#   ("cp437") via __register_nls(table, &__this_module) and
#   tail-returns.
#
#   Init path (.init.text, paraphrased from objdump -drC of
#   /lib/modules/$(uname -r)/kernel/fs/nls/nls_cp437.ko.xz):
#
#       init_module:
#           call __fentry__
#           mov  $&__this_module, %rsi      # owner
#           mov  $&table_cp437, %rdi        # struct nls_table
#           jmp  __register_nls             # L51: returns 0
#
#   nls_cp437.ko has 4 UND symbols. Two are already in exports.ad
#   (__fentry__, __x86_return_thunk). The other two (__register_nls,
#   unregister_nls) ship from linux_abi/api_l51.ad as "registry
#   accepted" placeholders.
#
# PASS bar: `kmod_linux: init returned 0`.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/nls_cp437.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/fs/nls/nls_cp437.ko"
    "${HOST_LIB}/fs/nls/nls_cp437.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L51: nls_cp437.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l51_nls_cp437] picked: $picked"

cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$LKM_DIR"
case "$picked" in
    *.ko.xz)
        echo "[test_l51_nls_cp437] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l51_nls_cp437] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

echo
echo "[test_l51_nls_cp437] === Static UND-symbol analysis ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l51_nls_cp437] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l51_nls_cp437] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l51_nls_cp437] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l51_nls_cp437] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none - full coverage)"
    fi
fi

echo
echo "[test_l51_nls_cp437] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l51_nls_cp437] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l51_nls_cp437] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

LOG="$(mktemp)"
echo "[test_l51_nls_cp437] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/nls_cp437.ko\n'
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

echo "[test_l51_nls_cp437] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

echo
echo "[test_l51_nls_cp437] =============== captured serial (tail) ==============="
tail -n 120 "$LOG" || true
echo "[test_l51_nls_cp437] ======================================================"
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l51_nls_cp437] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

if [ ! -s "$LOG" ]; then
    echo "[test_l51_nls_cp437] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l51_nls_cp437] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l51_nls_cp437] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l51_nls_cp437] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l51_nls_cp437] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
else
    echo "[test_l51_nls_cp437] INFO: no runtime unresolved-symbol lines"
fi

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l51_nls_cp437] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l51_nls_cp437] PASS: nls_cp437.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l51_nls_cp437]       (library-only path)"
    else
        echo "[test_l51_nls_cp437]       (init_module returned 0)"
    fi
else
    echo
    echo "[test_l51_nls_cp437] FAIL: nls_cp437.ko did not finish loading."
    echo "[test_l51_nls_cp437]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l51_nls_cp437] full log preserved at: $LOG"
exit 0
