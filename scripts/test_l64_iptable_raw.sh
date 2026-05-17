#!/usr/bin/env bash
# scripts/test_l64_iptable_raw.sh — L64 iptable_raw.ko load test.
#
# Goal:
#   Ship iptable_raw.ko (Linux's IPv4 RAW chain — exposes the
#   PREROUTING / OUTPUT hooks that fire *before* conntrack, used to
#   set CONNMARK / NOTRACK / TRACE before the connection tracker
#   sees the packet). Layers on L62's ip_tables.ko engine. Fully
#   covered by L<=63 with ZERO new exports (15 UND, all already
#   shipped — iptable_filter UND set plus _printk).
#
#   41st distro .ko to load. Total exports unchanged from L63.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/iptable_raw.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/net/ipv4/netfilter/iptable_raw.ko"
    "${HOST_LIB}/net/ipv4/netfilter/iptable_raw.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then picked="$c"; break; fi
done

if [ -z "$picked" ]; then
    echo "L64: iptable_raw.ko not present; skipping"
    exit 0
fi

echo "[test_l64_iptable_raw] picked: $picked"

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
echo "[test_l64_iptable_raw] UND ($(echo "$UND_SYMS" | wc -w)):"
for s in $UND_SYMS; do echo "  $s"; done
echo "[test_l64_iptable_raw] MISSING:"
if [ -n "$MISSING" ]; then for s in $MISSING; do echo "  - $s"; done; else echo "  (none - full coverage)"; fi

bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF"

LOG="$(mktemp)"
set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/iptable_raw.ko\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

tail -n 40 "$LOG" || true

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l64_iptable_raw] FAIL: kernel panic"
    exit 1
fi

INIT_OK=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK=${INIT_OK:-0}
LIB_ONLY=$(grep -cE "kmod_linux: no init function" "$LOG" || true)
LIB_ONLY=${LIB_ONLY:-0}
INSMOD_FAIL=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL=${INSMOD_FAIL:-0}

echo "[test_l64_iptable_raw] init_OK=$INIT_OK lib_only=$LIB_ONLY fail=$INSMOD_FAIL"

if [ "$INSMOD_FAIL" -ge 1 ]; then echo "[test_l64_iptable_raw] FAIL"; exit 1; fi
if [ "$INIT_OK" -ge 1 ] || [ "$LIB_ONLY" -ge 1 ]; then
    echo "[test_l64_iptable_raw] PASS: iptable_raw.ko loaded"
    exit 0
fi
echo "[test_l64_iptable_raw] FAIL: no PASS markers"
exit 1
