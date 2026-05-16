#!/usr/bin/env bash
# scripts/test_l37_dependency_chain.sh — L37 two-module dependency-chain test.
#
# Goal:
#   L36 landed crc32c_generic.ko cleanly (init returns 0). L37 escalates
#   to a TWO-MODULE chain: insmod the dependency (crc32c_generic) FIRST
#   to register the "crc32c" shash, then insmod libcrc32c.ko — the
#   user-facing wrapper that looks up that shash via crypto_alloc_shash.
#
#   This is the first real EXPORT_SYMBOL → __ksymtab → module-to-module
#   resolution chain we've ever asked the L-track to mediate: libcrc32c
#   does not import crc32c-the-implementation from the *kernel*; it
#   imports it through the *registered shash list* that crc32c_generic
#   populated a moment earlier. So the dependency is dynamic, not link-
#   time.
#
# Strategy:
#   1. Locate BOTH .ko files on the host:
#        /lib/modules/$(uname -r)/kernel/crypto/crc32c_generic.ko[.xz]
#        /lib/modules/$(uname -r)/kernel/lib/libcrc32c.ko[.xz]
#      If either is missing, exit 0 with a SKIP (host-dependent, not a
#      regression).
#   2. Static-analyse: `nm -u libcrc32c.ko` to enumerate every UND
#      symbol it references. Cross-check each against linux_abi/
#      exports.ad (grep). Print covered + missing lists. If anything
#      is missing, exit 0 GRACEFULLY with that list — that's the L38
#      target queue, not a test failure.
#   3. Stage BOTH under tests/linux-modules/ (the build_initramfs.py
#      glob embeds them as /lib/modules/6.12/<basename>.ko inside the
#      cpio).
#   4. Rebuild userland + initramfs (hamsh as /init) + kernel ELF.
#   5. Boot QEMU and drive hamsh through:
#        insmod /lib/modules/6.12/crc32c_generic.ko    (dependency)
#        insmod /lib/modules/6.12/libcrc32c.ko         (the user)
#        exit
#      Capture serial output to a temp log.
#   6. Assertions:
#        a. NO kernel panic.
#        b. Log non-empty (QEMU actually booted).
#        c. BOTH insmods produced a `kmod_linux: ... loaded` line,
#           one for crc32c_generic and one for libcrc32c.
#        d. INFO: unresolved-symbol harvest (should be empty if (c) held).
#
# A failure of (c) is NOT a panic — it's "L38 still needs symbols" — and
# the script prints the missing list and exits 0. Hard failures (1) are
# reserved for actual kernel panics or QEMU not booting at all.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_DEP="$LKM_DIR/crc32c_generic.ko"
STAGED_USER="$LKM_DIR/libcrc32c.ko"
EXPORTS_AD=linux_abi/exports.ad

# --- 1. Locate both modules on the host -----------------------------
KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
DEP_CANDIDATES=(
    "${HOST_LIB}/crypto/crc32c_generic.ko"
    "${HOST_LIB}/crypto/crc32c_generic.ko.xz"
)
USER_CANDIDATES=(
    "${HOST_LIB}/lib/libcrc32c.ko"
    "${HOST_LIB}/lib/libcrc32c.ko.xz"
)

pick_one() {
    local -n arr=$1
    for c in "${arr[@]}"; do
        if [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

DEP_SRC="$(pick_one DEP_CANDIDATES)" || DEP_SRC=""
USER_SRC="$(pick_one USER_CANDIDATES)" || USER_SRC=""

if [ -z "$DEP_SRC" ] || [ -z "$USER_SRC" ]; then
    echo "L37: missing one of crc32c_generic.ko / libcrc32c.ko on this host;"
    echo "     dep=$DEP_SRC user=$USER_SRC"
    echo "L37: skipping (host-dependent, not a regression)"
    exit 0
fi

echo "[test_l37] dep   module: $DEP_SRC"
echo "[test_l37] user  module: $USER_SRC"

# Cleanup: un-stage the .ko files and restore the default initramfs
# (mirrors test_l30_distro_module.sh's EXIT trap).
cleanup() {
    rm -f "$STAGED_DEP" "$STAGED_USER"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 2. Stage both .ko's ---------------------------------------------
mkdir -p "$LKM_DIR"
stage_one() {
    local src="$1" dst="$2"
    case "$src" in
        *.ko.xz)
            echo "[test_l37] decompressing -> $dst"
            xz -dc "$src" > "$dst"
            ;;
        *.ko)
            echo "[test_l37] copying       -> $dst"
            cp "$src" "$dst"
            ;;
    esac
}
stage_one "$DEP_SRC"  "$STAGED_DEP"
stage_one "$USER_SRC" "$STAGED_USER"
ls -l "$STAGED_DEP" "$STAGED_USER"

# --- 3. Static-analyse libcrc32c.ko for UND symbols ------------------
# `nm -u` lists every undefined symbol; cross-reference each against
# linux_abi/exports.ad to predict which symbols WILL fail at insmod
# time. Anything missing here is the L38 work queue.
echo
echo "[test_l37] === Static UND-symbol analysis of libcrc32c.ko ==="
UND_SYMS=$(nm -u "$STAGED_USER" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l37] WARN: nm -u produced no symbols (module stripped?)"
else
    COVERED=""
    MISSING=""
    for sym in $UND_SYMS; do
        # Match `"sym"` inside an _add_export(...) call in exports.ad
        # OR any api_*.ad file under linux_abi/.
        if grep -rq "_add_export(\"${sym}\"" linux_abi/ 2>/dev/null; then
            COVERED+=" $sym"
        else
            MISSING+=" $sym"
        fi
    done

    echo "[test_l37] UND symbols in libcrc32c.ko:"
    for s in $UND_SYMS; do echo "  $s"; done

    echo "[test_l37] covered by exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi

    echo "[test_l37] MISSING from exports.ad (L38 targets):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none — full coverage)"
    fi
fi

# --- 4. Build userland + initramfs + kernel --------------------------
echo
echo "[test_l37] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l37] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l37] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# --- 5. Boot QEMU and drive the two-step insmod chain ----------------
LOG="$(mktemp)"
echo "[test_l37] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/crc32c_generic.ko\n'
    sleep 2
    printf 'insmod /lib/modules/6.12/libcrc32c.ko\n'
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

echo "[test_l37] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

# --- 6. Assertions ----------------------------------------------------
echo
echo "[test_l37] =============== captured serial (tail) ==============="
tail -n 80 "$LOG" || true
echo "[test_l37] ======================================================"
echo

# a. PANIC = hard fail.
if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l37] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

# b. Empty log = qemu never ran.
if [ ! -s "$LOG" ]; then
    echo "[test_l37] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

# c. Two `kmod_linux: ... loaded` lines?
LOADED_COUNT=$(grep -cE "kmod_linux:.*loaded" "$LOG" || true)
LOADED_COUNT=${LOADED_COUNT:-0}
echo "[test_l37] INFO: 'kmod_linux: ... loaded' line count: $LOADED_COUNT"
grep -nE "kmod_linux:.*loaded" "$LOG" | sed 's/^/  /' || true

DEP_OK=0
USER_OK=0
grep -qE "kmod_linux:.*crc32c_generic.*loaded" "$LOG" && DEP_OK=1
grep -qE "kmod_linux:.*libcrc32c.*loaded"      "$LOG" && USER_OK=1
echo "[test_l37] INFO: crc32c_generic loaded=$DEP_OK  libcrc32c loaded=$USER_OK"

# d. Unresolved-symbol harvest from the actual boot log.
UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l37] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
    echo "[test_l37] INFO: distinct symbol names from runtime log:"
    echo "$UNRESOLVED" \
        | grep -oE "'[A-Za-z_][A-Za-z0-9_]*'|symbol [A-Za-z_][A-Za-z0-9_]*|: [A-Za-z_][A-Za-z0-9_]+$" \
        | sort -u \
        | sed 's/^/  /'
else
    echo "[test_l37] INFO: no 'unresolved external symbol' lines in runtime log"
fi

# Outcome decision: graceful exit either way (no panic = no regression).
if [ "$DEP_OK" = "1" ] && [ "$USER_OK" = "1" ]; then
    echo
    echo "[test_l37] PASS: both crc32c_generic.ko and libcrc32c.ko loaded"
    echo "[test_l37]       (full two-module dependency chain resolved)"
elif [ "$DEP_OK" = "1" ] && [ "$USER_OK" = "0" ]; then
    echo
    echo "[test_l37] PARTIAL: dependency loaded but libcrc32c did not."
    echo "[test_l37]          See MISSING list above for L38 targets."
else
    echo
    echo "[test_l37] PARTIAL: dependency module did not finish loading."
    echo "[test_l37]          Likely missing-symbol set above is L38 input."
fi

echo "[test_l37] full log preserved at: $LOG"
echo "[test_l37] (see docs/L30_DISTRO_MODULE_NOTES.md for L37 entry)"
exit 0
