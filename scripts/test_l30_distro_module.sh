#!/usr/bin/env bash
# scripts/test_l30_distro_module.sh — L30 distro .ko sniff test.
#
# Goal:
#   Take an UNMODIFIED kernel module shipped by the host's Debian/Linux
#   distribution and point Hamnix's L1 module loader at it. We are NOT
#   expecting success on the first run — the loader will almost certainly
#   complain about unresolved external symbols (the L-track ABI only
#   covers the symbols we've explicitly exported so far). The point is
#   to harvest a concrete list of WHICH symbols the next L-track
#   milestone needs to provide.
#
# Strategy (mirrors scripts/test_l_track.sh):
#   1. Find the smallest no-hardware crypto helper .ko on the host:
#        /lib/modules/$(uname -r)/kernel/lib/crc8.ko
#        /lib/modules/$(uname -r)/kernel/lib/libcrc32c.ko
#        /lib/modules/$(uname -r)/kernel/crypto/crc32c_generic.ko
#      (each in either plain or .xz form). If none exist, exit 0 with a
#      SKIP — this is host-dependent and not a real regression.
#   2. Stage it as tests/linux-modules/distro_crc.ko so the existing
#      build_initramfs.py glob embeds it at
#      /lib/modules/6.12/distro_crc.ko inside the cpio.
#   3. Rebuild userland + initramfs + the bare-metal kernel image.
#   4. Boot QEMU with hamsh as /init, drive:
#         insmod /lib/modules/6.12/distro_crc.ko
#         exit
#      Capture all serial output to a temp log.
#   5. Best-effort assertions on the captured log:
#         a. NO "PANIC" / "panic:" lines.
#         b. The hamsh prompt re-appeared after insmod (loader did not
#            wedge the kernel).
#         c. INFO: list any "unresolved external symbol" lines we found.
#         d. INFO: report whether "kmod_linux: ... loaded" appeared.
#
# Whatever happens, this script EXITS 0 unless the kernel itself
# panicked or the QEMU process never produced any output — those are
# the only true regressions at this stage.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/distro_crc.ko"

# --- 1. Locate a candidate distro .ko --------------------------------
KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    # crc32c_generic FIRST — it has module_init(), exercising the
    # full L32 struct module.init path.
    "${HOST_LIB}/crypto/crc32c_generic.ko"
    "${HOST_LIB}/crypto/crc32c_generic.ko.xz"
    "${HOST_LIB}/lib/libcrc32c.ko"
    "${HOST_LIB}/lib/libcrc32c.ko.xz"
    # crc8 is library-only (no init); useful fallback for hosts
    # without the others, but it doesn't validate the init call.
    "${HOST_LIB}/lib/crc8.ko"
    "${HOST_LIB}/lib/crc8.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L30: no candidate distro module on this host; skipping"
    exit 0
fi

echo "[test_l30] picked distro module: $picked"

# Restore initramfs to the default on exit (mirrors test_l_track.sh).
# Also unstage the distro .ko so subsequent L-track runs don't see it.
cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 2. Stage as tests/linux-modules/distro_crc.ko ------------------
mkdir -p "$LKM_DIR"
case "$picked" in
    *.ko.xz)
        echo "[test_l30] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l30] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac

ls -l "$STAGED_KO"
file  "$STAGED_KO" || true

# --- 3. Build userland, initramfs, kernel ---------------------------
echo "[test_l30] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l30] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l30] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# --- 4. Boot QEMU and drive the shell -------------------------------
LOG="$(mktemp)"
echo "[test_l30] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/distro_crc.ko\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
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

echo "[test_l30] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

# --- 5. Best-effort assertions --------------------------------------
echo
echo "[test_l30] =============== captured serial (tail) ==============="
tail -n 60 "$LOG" || true
echo "[test_l30] ======================================================"
echo

# a. PANIC?
if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l30] FAIL: kernel panic detected"
    echo "[test_l30] --- panic context ---"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

# b. Empty log = qemu never ran
if [ ! -s "$LOG" ]; then
    echo "[test_l30] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

# c. Loader success line
if grep -E -q "kmod_linux:.*loaded" "$LOG"; then
    echo "[test_l30] INFO: 'kmod_linux: ... loaded' marker found:"
    grep -nE "kmod_linux:.*loaded" "$LOG" || true
else
    echo "[test_l30] INFO: no 'kmod_linux: ... loaded' marker (expected"
    echo "[test_l30]       on first run — most stock modules will fail"
    echo "[test_l30]       to resolve before reaching the 'loaded' log)"
fi

# d. Unresolved external symbols
UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l30] INFO: unresolved-symbol lines (not a failure):"
    echo "$UNRESOLVED" | sed 's/^/  /'
    # Extract just the symbol names for the docs page
    echo
    echo "[test_l30] INFO: distinct symbols the loader complained about:"
    echo "$UNRESOLVED" \
        | grep -oE "'[A-Za-z_][A-Za-z0-9_]*'|symbol [A-Za-z_][A-Za-z0-9_]*|: [A-Za-z_][A-Za-z0-9_]+$" \
        | sort -u \
        | sed 's/^/  /'
else
    echo "[test_l30] INFO: no 'unresolved external symbol' lines found"
fi

# e. Did hamsh prompt return after insmod?
# The hamsh prompt token is "hamsh$ " (consistent with other test_*.sh).
PROMPT_COUNT=$(grep -c "hamsh\\\$\\|hamsh\\\$ \\|hamsh#" "$LOG" 2>/dev/null || true)
PROMPT_COUNT=${PROMPT_COUNT:-0}
echo "[test_l30] INFO: hamsh prompt occurrences: $PROMPT_COUNT"
if [ "$PROMPT_COUNT" -ge 2 ]; then
    echo "[test_l30] INFO: prompt re-appeared after insmod (no wedge)"
fi

echo
echo "[test_l30] PASS (best-effort): no panic, kernel survived insmod"
echo "[test_l30] full log preserved at: $LOG"
echo "[test_l30] (see docs/L30_DISTRO_MODULE_NOTES.md for first-run notes)"
# Deliberately do NOT rm "$LOG" — caller may want to inspect it.
exit 0
