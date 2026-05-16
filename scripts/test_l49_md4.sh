#!/usr/bin/env bash
# scripts/test_l49_md4.sh — L49 md4.ko load test.
#
# Goal:
#   Ship the 14th stock Debian .ko load. md4.ko is the MD4 message-
#   digest shash implementation (RFC 1320, used today only by legacy
#   protocols — CIFS/SMB challenge-response, NTLMv1 password hashing).
#   It registers a single struct shash_alg ("md4") via
#   crypto_register_shash and tail-returns.
#
#   Init path (.init.text, paraphrased from objdump -drC of
#   /lib/modules/$(uname -r)/kernel/crypto/md4.ko.xz):
#
#       init_module:
#           call __fentry__
#           mov  $&md4_alg, %rdi
#           jmp  crypto_register_shash      # L34: returns 0
#
#   md4.ko has 7 UND symbols. Five are already in exports.ad:
#       crypto_register_shash, crypto_unregister_shash (L34)
#       __fentry__, __x86_return_thunk, __warn_printk (L0 / L49)
#   Wait — __warn_printk comes from L49. The two NEW symbols vs the
#   prior table are memcpy + __warn_printk, both freshly exported by
#   linux_abi/api_l49.ad in the L49 batch.
#
#   memcpy: shipped by api_l49.ad — exposes the existing C-runtime
#   memcpy under the Linux ABI name. md4's runtime calls it from its
#   shash->update implementation (block-buffered digest accumulation),
#   not from init.
#
#   __warn_printk: shipped by api_l49.ad — printk-backed WARN()
#   handler. md4's runtime can trip WARN_ON_ONCE under pathological
#   key/desc-size combos; init never reaches it.
#
# Strategy (mirrors test_l49_crc32_generic.sh): locate -> stage ->
# static-check -> build -> boot -> assert.
#
# PASS bar: `kmod_linux: init returned 0`. No init_module failed.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/md4.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/crypto/md4.ko"
    "${HOST_LIB}/crypto/md4.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L49: md4.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l49_md4] picked: $picked"

cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$LKM_DIR"
case "$picked" in
    *.ko.xz)
        echo "[test_l49_md4] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l49_md4] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

echo
echo "[test_l49_md4] === Static UND-symbol analysis ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l49_md4] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l49_md4] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l49_md4] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l49_md4] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none - full coverage)"
    fi
fi

echo
echo "[test_l49_md4] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l49_md4] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l49_md4] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

LOG="$(mktemp)"
echo "[test_l49_md4] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/md4.ko\n'
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

echo "[test_l49_md4] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

echo
echo "[test_l49_md4] =============== captured serial (tail) ==============="
tail -n 120 "$LOG" || true
echo "[test_l49_md4] ======================================================"
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l49_md4] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

if [ ! -s "$LOG" ]; then
    echo "[test_l49_md4] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l49_md4] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l49_md4] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l49_md4] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l49_md4] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
else
    echo "[test_l49_md4] INFO: no runtime unresolved-symbol lines"
fi

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l49_md4] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l49_md4] PASS: md4.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l49_md4]       (library-only path)"
    else
        echo "[test_l49_md4]       (init_module returned 0 - 14th stock Debian .ko load)"
    fi
else
    echo
    echo "[test_l49_md4] FAIL: md4.ko did not finish loading."
    echo "[test_l49_md4]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l49_md4] full log preserved at: $LOG"
exit 0
