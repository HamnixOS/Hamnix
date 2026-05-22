#!/usr/bin/env bash
# scripts/test_l57_fat.sh — L57 fat.ko load test.
#
# Goal:
#   Ship fat.ko (Linux's core FAT filesystem module — the foundation
#   for vfat/exfat/msdos/iso9660). init_module calls fat_cache_init,
#   which uses __kmem_cache_create_args (NEW in L57) to create two
#   slab caches. Both calls return non-NULL via the L57 slab-noprof
#   shim → init returns 0.
#
#   This is the 23rd distro module to load (after binfmt_misc at L56).
#   fat.ko is library-only from Hamnix's perspective: it never backs
#   a real mount (Hamnix has its own native FAT32 driver at
#   fs/fat32_*.ad). Loading fat.ko unlocks the symbol surface that
#   vfat.ko / msdos.ko / exfat.ko / udf.ko / isofs.ko depend on for
#   their own module loads.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/fat.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/fs/fat/fat.ko"
    "${HOST_LIB}/fs/fat/fat.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then picked="$c"; break; fi
done

if [ -z "$picked" ]; then
    echo "L57: fat.ko not present; skipping"
    exit 0
fi

echo "[test_l57_fat] picked: $picked"

cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$LKM_DIR"
case "$picked" in
    *.ko.xz) xz -dc "$picked" > "$STAGED_KO" ;;
    *.ko)    cp "$picked" "$STAGED_KO" ;;
esac
ls -l "$STAGED_KO"

UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
MISSING=""
for sym in $UND_SYMS; do
    if ! grep -rq "_add_export(\"${sym}\"" linux_abi/ 2>/dev/null; then
        MISSING+=" $sym"
    fi
done
echo "[test_l57_fat] UND ($(echo "$UND_SYMS" | wc -w)):"
for s in $UND_SYMS; do echo "  $s"; done
echo "[test_l57_fat] MISSING:"
if [ -n "$MISSING" ]; then for s in $MISSING; do echo "  - $s"; done; else echo "  (none - full coverage)"; fi

bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF"

LOG="$(mktemp)"
set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/fat.ko\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

tail -n 40 "$LOG" || true

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l57_fat] FAIL: kernel panic"
    exit 1
fi

INIT_OK=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK=${INIT_OK:-0}
LIB_ONLY=$(grep -cE "kmod_linux: no init function" "$LOG" || true)
LIB_ONLY=${LIB_ONLY:-0}
INSMOD_FAIL=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL=${INSMOD_FAIL:-0}

echo "[test_l57_fat] init_OK=$INIT_OK lib_only=$LIB_ONLY fail=$INSMOD_FAIL"

if [ "$INSMOD_FAIL" -ge 1 ]; then echo "[test_l57_fat] FAIL"; exit 1; fi
if [ "$INIT_OK" -ge 1 ] || [ "$LIB_ONLY" -ge 1 ]; then
    echo "[test_l57_fat] PASS: fat.ko loaded"
    exit 0
fi
echo "[test_l57_fat] FAIL: no PASS markers"
exit 1
