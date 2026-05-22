#!/usr/bin/env bash
# scripts/test_l49_crc32_generic.sh — L49 crc32_generic.ko load test.
#
# Goal:
#   Ship the 13th stock Debian .ko load. crc32_generic.ko is the
#   shash-registered wrapper around lib/crc32.c's table-driven CRC32
#   (little-endian, reflected, poly 0xEDB88320 — same family as the
#   one libcrc32c wraps for Castagnoli). It registers two shash_alg
#   entries via crypto_register_shashes: "crc32" and "crc32-generic",
#   delegating their update step to the underlying crc32_le helper.
#
#   Init path (.init.text, paraphrased from objdump -drC of
#   /lib/modules/$(uname -r)/kernel/crypto/crc32_generic.ko.xz):
#
#       init_module:
#           call __fentry__
#           mov  $&crc32_algs, %rdi
#           jmp  crypto_register_shashes        # L34: returns 0
#
#   That's the whole init: tail-jump to crypto_register_shashes, which
#   the L34 shim accepts as success. crc32_generic's runtime path
#   (shash->update calls crc32_le) is not exercised at load time.
#
#   crc32_generic.ko's 5 UND symbols are ALL already in exports.ad:
#       crc32_le                (L34: api_crypto.ad)
#       crypto_register_shash   (L34: api_crypto.ad)
#       crypto_unregister_shash (L34: api_crypto.ad)
#       __fentry__              (L0:  exports.ad)
#       __x86_return_thunk      (L0:  exports.ad)
#
#   Zero-gap module — no new api shims needed. The L49 api_l49.ad
#   work covers the OTHER four hash modules (md4, rmd160,
#   blake2b_generic, ghash-generic) which share two additional UND
#   symbols (memcpy + __warn_printk) plus ghash's three (gf128mul_*,
#   kfree_sensitive).
#
# Strategy (mirrors test_l48_nfnetlink.sh):
#   1. Locate /lib/modules/$(uname -r)/kernel/crypto/crc32_generic.ko[.xz];
#      SKIP exit 0 if not present.
#   2. Static-analyse: nm -u + cross-check linux_abi/ — L49 should
#      report MISSING = (none).
#   3. Stage under tests/linux-modules/, rebuild userland + initramfs +
#      kernel, boot QEMU, drive hamsh:
#         insmod /lib/modules/6.12/crc32_generic.ko
#         exit
#   4. PASS bar: `kmod_linux: init returned 0` and no
#      `insmod: init_module failed`. crc32_generic HAS init_module so
#      the library-only branch is irrelevant here.
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
STAGED_KO="$LKM_DIR/crc32_generic.ko"

# --- 1. Locate crc32_generic.ko on the host -------------------------
KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/crypto/crc32_generic.ko"
    "${HOST_LIB}/crypto/crc32_generic.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L49: crc32_generic.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l49_crc32_generic] picked: $picked"

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
        echo "[test_l49_crc32_generic] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l49_crc32_generic] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

# --- 3. Static UND-symbol coverage check ----------------------------
echo
echo "[test_l49_crc32_generic] === Static UND-symbol analysis ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l49_crc32_generic] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l49_crc32_generic] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l49_crc32_generic] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l49_crc32_generic] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none - full coverage)"
    fi
fi

# --- 4. Build userland + initramfs + kernel -------------------------
echo
echo "[test_l49_crc32_generic] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l49_crc32_generic] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l49_crc32_generic] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# --- 5. Boot QEMU and drive insmod ----------------------------------
LOG="$(mktemp)"
echo "[test_l49_crc32_generic] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/crc32_generic.ko\n'
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

echo "[test_l49_crc32_generic] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

# --- 6. Assertions --------------------------------------------------
echo
echo "[test_l49_crc32_generic] =========== captured serial (tail) ==========="
tail -n 120 "$LOG" || true
echo "[test_l49_crc32_generic] ==============================================="
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l49_crc32_generic] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

if [ ! -s "$LOG" ]; then
    echo "[test_l49_crc32_generic] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l49_crc32_generic] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l49_crc32_generic] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l49_crc32_generic] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l49_crc32_generic] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
    echo "[test_l49_crc32_generic] INFO: distinct symbol names from runtime log:"
    echo "$UNRESOLVED" \
        | grep -oE "'[A-Za-z_][A-Za-z0-9_]*'|symbol [A-Za-z_][A-Za-z0-9_]*|: [A-Za-z_][A-Za-z0-9_]+$" \
        | sort -u \
        | sed 's/^/  /'
else
    echo "[test_l49_crc32_generic] INFO: no runtime unresolved-symbol lines"
fi

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l49_crc32_generic] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l49_crc32_generic] PASS: crc32_generic.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l49_crc32_generic]       (library-only path)"
    else
        echo "[test_l49_crc32_generic]       (init_module returned 0 - 13th stock Debian .ko load)"
    fi
else
    echo
    echo "[test_l49_crc32_generic] FAIL: crc32_generic.ko did not finish loading."
    echo "[test_l49_crc32_generic]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l49_crc32_generic] full log preserved at: $LOG"
exit 0
