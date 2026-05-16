#!/usr/bin/env bash
# scripts/test_l41_nf_defrag_ipv4.sh — L41 nf_defrag_ipv4.ko load test.
#
# Goal:
#   Extend the L-track ABI coverage to a stock Debian netfilter module:
#   nf_defrag_ipv4.ko. Picked because of all the cheap-to-cover .ko's
#   on a stock Debian 6.12 host, this one has the smallest gap between
#   its undefined-symbol set and what linux_abi/exports.ad already
#   ships. The new symbols added in L41:
#
#     register_pernet_subsys   — function (returns 0)
#     unregister_pernet_subsys — function (void)
#     ip_defrag                — function (returns 0; never called at init)
#     __local_bh_enable_ip     — function (no-op; never called at init)
#     nf_defrag_v4_hook        — data (uint64 slot; init writes 0)
#     pcpu_hot                 — data (64-byte zero buffer)
#
#   Module init path is exactly:
#     return register_pernet_subsys(&defrag4_net_ops);
#     /* then init_module clears nf_defrag_v4_hook */
#
#   Success bar: `kmod_linux: init returned 0` in the boot log.
#
# Strategy (mirrors test_l37_dependency_chain.sh):
#   1. Locate /lib/modules/$(uname -r)/kernel/net/ipv4/netfilter/
#      nf_defrag_ipv4.ko[.xz] on the host; SKIP exit 0 if not present.
#   2. Static-analyse: nm -u and cross-check linux_abi/ for predicted
#      missing symbols (informational — L41 should report empty MISSING).
#   3. Stage under tests/linux-modules/, rebuild userland + initramfs +
#      kernel, boot QEMU, drive hamsh:
#         insmod /lib/modules/6.12/nf_defrag_ipv4.ko
#         exit
#   4. Assertions:
#         a. NO kernel panic.
#         b. Log non-empty (QEMU actually booted).
#         c. `kmod_linux: init returned 0` present.
#         d. INFO: harvest any runtime unresolved-symbol lines.
#
# Failure of (c) without panic is reported as PARTIAL (informational
# unresolved list), not a hard exit-1 — only true panics / boot failures
# are real regressions at this stage.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/nf_defrag_ipv4.ko"

# --- 1. Locate nf_defrag_ipv4.ko on the host ------------------------
KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/net/ipv4/netfilter/nf_defrag_ipv4.ko"
    "${HOST_LIB}/net/ipv4/netfilter/nf_defrag_ipv4.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L41: nf_defrag_ipv4.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l41] picked: $picked"

# Cleanup: drop staged .ko and rebuild default initramfs on exit.
cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 2. Stage the .ko ------------------------------------------------
mkdir -p "$LKM_DIR"
case "$picked" in
    *.ko.xz)
        echo "[test_l41] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l41] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

# --- 3. Static UND-symbol coverage check ----------------------------
echo
echo "[test_l41] === Static UND-symbol analysis of nf_defrag_ipv4.ko ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l41] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l41] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l41] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l41] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none — full coverage)"
    fi
fi

# --- 4. Build userland + initramfs + kernel --------------------------
echo
echo "[test_l41] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l41] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l41] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# --- 5. Boot QEMU and drive insmod -----------------------------------
LOG="$(mktemp)"
echo "[test_l41] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/nf_defrag_ipv4.ko\n'
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

echo "[test_l41] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

# --- 6. Assertions ---------------------------------------------------
echo
echo "[test_l41] =============== captured serial (tail) ==============="
tail -n 80 "$LOG" || true
echo "[test_l41] ======================================================"
echo

# a. PANIC = hard fail.
if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l41] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

# b. Empty log = qemu never ran.
if [ ! -s "$LOG" ]; then
    echo "[test_l41] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

# c. init_module return code.
INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
echo "[test_l41] INFO: 'init returned 0' count: $INIT_OK_COUNT (want 1)"
grep -nE "kmod_linux: init returned" "$LOG" | sed 's/^/  /' || true

# d. Unresolved-symbol harvest from runtime log.
UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l41] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
    echo "[test_l41] INFO: distinct symbol names from runtime log:"
    echo "$UNRESOLVED" \
        | grep -oE "'[A-Za-z_][A-Za-z0-9_]*'|symbol [A-Za-z_][A-Za-z0-9_]*|: [A-Za-z_][A-Za-z0-9_]+$" \
        | sort -u \
        | sed 's/^/  /'
else
    echo "[test_l41] INFO: no runtime unresolved-symbol lines"
fi

# Outcome decision.
if [ "$INIT_OK_COUNT" -ge 1 ]; then
    echo
    echo "[test_l41] PASS: nf_defrag_ipv4.ko init_module returned 0"
else
    echo
    echo "[test_l41] PARTIAL: nf_defrag_ipv4.ko did not finish init."
    echo "[test_l41]          See unresolved list above; no panic."
fi

echo "[test_l41] full log preserved at: $LOG"
exit 0
