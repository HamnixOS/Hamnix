#!/usr/bin/env bash
# scripts/test_l62_ip_tables.sh — L62 ip_tables.ko load test.
#
# Goal:
#   Ship ip_tables.ko (Linux's IPv4 netfilter table engine — the
#   kernel module that registers the xt_table per-net infrastructure
#   for IPv4 and exports ipt_do_table / ipt_register_table /
#   ipt_alloc_initial_table to chain modules like iptable_filter /
#   iptable_nat / iptable_mangle). 72 UND total; 40 covered by
#   L<=61 (xt_register_match/target, nf_register_net_hooks,
#   register_pernet_subsys, ...); 32 new at L62 — the xt_table_info
#   lifecycle (xt_alloc_table_info, xt_free_table_info,
#   xt_replace_table, xt_check_*), xt_table register/find
#   (xt_register_table, xt_find_table*, xt_request_find_*),
#   xt_counters (xt_counters_alloc, xt_percpu_counter_*,
#   xt_copy_counters), xt_proto_{init,fini}, xt_find_jump_offset,
#   xt_match/target_to_user, the three DATA exports (xt_recseq,
#   nf_skb_duplicated, xt_tee_enabled), nf_log_trace, __copy_overflow
#   and __sw_hweight32.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/ip_tables.ko"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/net/ipv4/netfilter/ip_tables.ko"
    "${HOST_LIB}/net/ipv4/netfilter/ip_tables.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then picked="$c"; break; fi
done

if [ -z "$picked" ]; then
    echo "L62: ip_tables.ko not present; skipping"
    exit 0
fi

echo "[test_l62_ip_tables] picked: $picked"

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
echo "[test_l62_ip_tables] UND ($(echo "$UND_SYMS" | wc -w)):"
for s in $UND_SYMS; do echo "  $s"; done
echo "[test_l62_ip_tables] MISSING:"
if [ -n "$MISSING" ]; then for s in $MISSING; do echo "  - $s"; done; else echo "  (none - full coverage)"; fi

bash scripts/build_user.sh
bash scripts/build_modules.sh
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF"

LOG="$(mktemp)"
set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/ip_tables.ko\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

tail -n 40 "$LOG" || true

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l62_ip_tables] FAIL: kernel panic"
    exit 1
fi

INIT_OK=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK=${INIT_OK:-0}
LIB_ONLY=$(grep -cE "kmod_linux: no init function" "$LOG" || true)
LIB_ONLY=${LIB_ONLY:-0}
INSMOD_FAIL=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL=${INSMOD_FAIL:-0}

echo "[test_l62_ip_tables] init_OK=$INIT_OK lib_only=$LIB_ONLY fail=$INSMOD_FAIL"

if [ "$INSMOD_FAIL" -ge 1 ]; then echo "[test_l62_ip_tables] FAIL"; exit 1; fi
if [ "$INIT_OK" -ge 1 ] || [ "$LIB_ONLY" -ge 1 ]; then
    echo "[test_l62_ip_tables] PASS: ip_tables.ko loaded"
    exit 0
fi
echo "[test_l62_ip_tables] FAIL: no PASS markers"
exit 1
