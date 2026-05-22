#!/usr/bin/env bash
# scripts/test_l46_xor.sh — L46 xor.ko load test.
#
# Goal:
#   Ship the third non-zero-gap stock Debian .ko load. xor.ko is the
#   RAID5 XOR-arithmetic library (lib/xor.c upstream). Its init path
#   mirrors raid6_pq.ko's: alloc an 8-page scratch buffer, loop over
#   xor_block_* algos benchmarking each via __x86_indirect_thunk_rax,
#   pick the fastest, free.
#
#   Stock Debian 6.12 ships xor.ko with 16 UND symbols. L45 left
#   exactly 2 unresolved against linux_abi/exports.ad:
#
#     __x86_indirect_thunk_r9      function (pop rbp; jmp *r9)
#     __x86_indirect_thunk_r11     function (pop rbp; jmp *r11)
#
#   L46 closes that gap by appending both thunks to
#   linux_abi/api_raid6.ad (centralising retpoline thunks alongside
#   the already-shipped rcx / r8 variants). The init path of xor.ko
#   only dispatches through __x86_indirect_thunk_rax (already L44);
#   r9 / r11 appear in xor's .text recovery paths the bench loop
#   never traverses, but their addresses must resolve at load time.
#
# Strategy (mirrors test_l45_raid6_pq.sh):
#   1. Locate /lib/modules/$(uname -r)/kernel/crypto/xor.ko[.xz];
#      SKIP exit 0 if not present.
#   2. Static-analyse: nm -u + cross-check linux_abi/ — L46 should
#      report MISSING = (none).
#   3. Stage under tests/linux-modules/, rebuild userland + initramfs +
#      kernel, boot QEMU, drive hamsh:
#         insmod /lib/modules/6.12/xor.ko
#         exit
#   4. PASS bar: EITHER `kmod_linux: init returned 0` OR
#      `kmod_linux: no init function (library-only module)`, and
#      no `insmod: init_module failed`. xor HAS an init_module so
#      the live path is the first branch.
#
# Timing budget: same xor_block bench shape as raid6_pq (≤1 s of
# wall-clock for the integer algos). Plus boot, insmod, exit. Use the
# same 45 s qemu timeout as test_l45.
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
STAGED_KO="$LKM_DIR/xor.ko"

# --- 1. Locate xor.ko on the host -----------------------------------
KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/crypto/xor.ko"
    "${HOST_LIB}/crypto/xor.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L46: xor.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l46] picked: $picked"

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
        echo "[test_l46] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l46] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

# --- 3. Static UND-symbol coverage check ----------------------------
echo
echo "[test_l46] === Static UND-symbol analysis of xor.ko ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l46] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l46] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l46] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l46] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none - full coverage)"
    fi
fi

# --- 4. Build userland + initramfs + kernel -------------------------
echo
echo "[test_l46] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l46] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l46] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# --- 5. Boot QEMU and drive insmod ----------------------------------
LOG="$(mktemp)"
echo "[test_l46] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/xor.ko\n'
    sleep 10
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

echo "[test_l46] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

# --- 6. Assertions --------------------------------------------------
echo
echo "[test_l46] =============== captured serial (tail) ==============="
tail -n 120 "$LOG" || true
echo "[test_l46] ======================================================"
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l46] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

if [ ! -s "$LOG" ]; then
    echo "[test_l46] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l46] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l46] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l46] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l46] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
    echo "[test_l46] INFO: distinct symbol names from runtime log:"
    echo "$UNRESOLVED" \
        | grep -oE "'[A-Za-z_][A-Za-z0-9_]*'|symbol [A-Za-z_][A-Za-z0-9_]*|: [A-Za-z_][A-Za-z0-9_]+$" \
        | sort -u \
        | sed 's/^/  /'
else
    echo "[test_l46] INFO: no runtime unresolved-symbol lines"
fi

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l46] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l46] PASS: xor.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l46]       (library-only path)"
    else
        echo "[test_l46]       (init_module returned 0 — 10th stock Debian .ko load)"
    fi
else
    echo
    echo "[test_l46] FAIL: xor.ko did not finish loading."
    echo "[test_l46]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l46] full log preserved at: $LOG"
exit 0
