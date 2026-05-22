#!/usr/bin/env bash
# scripts/test_l45_raid6_pq.sh — L45 raid6_pq.ko load test.
#
# Goal:
#   Ship the second non-zero-gap stock Debian .ko load. raid6_pq.ko is
#   the RAID6 P+Q syndrome math library. Stock Debian 6.12 ships it
#   with 16 UND symbols; L44 left 7 unresolved against
#   linux_abi/exports.ad. L45 closes that gap via the new
#   linux_abi/api_raid6.ad:
#
#     get_free_pages_noprof          function (forward to alloc_pages)
#     free_pages                     function (forward to free_pages)
#     __SCT__preempt_schedule        function (no-op ret)
#     kernel_fpu_begin_mask          function (no-op; .text-only)
#     kernel_fpu_end                 function (no-op; .text-only)
#     __x86_indirect_thunk_rcx       function (pop rbp; jmp *rcx)
#     __x86_indirect_thunk_r8        function (pop rbp; jmp *r8)
#
#   Init path (.init.text): get_free_pages_noprof(GFP_KERNEL, order=3)
#   for a 32 KiB scratch buffer, loop over raid6_algos[] running
#   gen_syndrome via __x86_indirect_thunk_rax (already L44) inside a
#   jiffies-bounded bench window, pick the fastest, do the same for
#   recovery algos, free_pages the scratch buffer, return 0.
#
#   The bench only exercises raid6_intx* (pure integer) algorithms.
#   The SIMD `.valid()` callbacks read boot_cpu_data.x86_capability,
#   which L39 exports as 64 zero bytes — every SIMD algo's valid()
#   returns false and is skipped, so the FPU pair is never reached
#   during init. The FPU shims exist only so the loader can resolve
#   the relocations in raid6_pq's recovery .text paths.
#
# Strategy (mirrors test_l44_lib80211.sh):
#   1. Locate /lib/modules/$(uname -r)/kernel/lib/raid6/raid6_pq.ko[.xz];
#      SKIP exit 0 if not present.
#   2. Static-analyse: nm -u + cross-check linux_abi/ — L45 should
#      report MISSING = (none).
#   3. Stage under tests/linux-modules/, rebuild userland + initramfs +
#      kernel, boot QEMU, drive hamsh:
#         insmod /lib/modules/6.12/raid6_pq.ko
#         exit
#   4. PASS bar: EITHER `kmod_linux: init returned 0` OR
#      `kmod_linux: no init function (library-only module)`, and
#      no `insmod: init_module failed`. raid6_pq HAS an init_module
#      so the live path is the first branch.
#
# Timing budget: the bench loops over ~6 integer algos × 16 jiffies
# @ 100 Hz = ~1 second of wall-clock. Plus boot, insmod, exit. Use a
# 45 s qemu timeout (bumped from L44's 30 s) for headroom.
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
STAGED_KO="$LKM_DIR/raid6_pq.ko"

# --- 1. Locate raid6_pq.ko on the host -------------------------------
KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/lib/raid6/raid6_pq.ko"
    "${HOST_LIB}/lib/raid6/raid6_pq.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L45: raid6_pq.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l45] picked: $picked"

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
        echo "[test_l45] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l45] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

# --- 3. Static UND-symbol coverage check ----------------------------
echo
echo "[test_l45] === Static UND-symbol analysis of raid6_pq.ko ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l45] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l45] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l45] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l45] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none - full coverage)"
    fi
fi

# --- 4. Build userland + initramfs + kernel -------------------------
echo
echo "[test_l45] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l45] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l45] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# --- 5. Boot QEMU and drive insmod ----------------------------------
LOG="$(mktemp)"
echo "[test_l45] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/raid6_pq.ko\n'
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

echo "[test_l45] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

# --- 6. Assertions --------------------------------------------------
echo
echo "[test_l45] =============== captured serial (tail) ==============="
tail -n 120 "$LOG" || true
echo "[test_l45] ======================================================"
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l45] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

if [ ! -s "$LOG" ]; then
    echo "[test_l45] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l45] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l45] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l45] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l45] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
    echo "[test_l45] INFO: distinct symbol names from runtime log:"
    echo "$UNRESOLVED" \
        | grep -oE "'[A-Za-z_][A-Za-z0-9_]*'|symbol [A-Za-z_][A-Za-z0-9_]*|: [A-Za-z_][A-Za-z0-9_]+$" \
        | sort -u \
        | sed 's/^/  /'
else
    echo "[test_l45] INFO: no runtime unresolved-symbol lines"
fi

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l45] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l45] PASS: raid6_pq.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l45]       (library-only path)"
    else
        echo "[test_l45]       (init_module returned 0 — 9th stock Debian .ko load)"
    fi
else
    echo
    echo "[test_l45] FAIL: raid6_pq.ko did not finish loading."
    echo "[test_l45]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l45] full log preserved at: $LOG"
exit 0
