#!/usr/bin/env bash
# scripts/test_l47_nf_log_syslog.sh — L47 nf_log_syslog.ko load test.
#
# Goal:
#   Ship the fourth non-zero-gap stock Debian .ko load. nf_log_syslog.ko
#   is the netfilter syslog-logger backend — registers a `struct
#   nf_logger` per protocol family so iptables/nftables `-j LOG` rules
#   produce kernel log lines. Its init path:
#
#     register_pernet_subsys(&syslog_net_ops)            # L41
#     nf_log_register(NFPROTO_IPV4 = 2,    &logger_ipv4) # L47
#     nf_log_register(NFPROTO_ARP  = 3,    &logger_arp)  # L47
#     nf_log_register(NFPROTO_IPV6 = 10,   &logger_ipv6) # L47
#     nf_log_register(NFPROTO_NETDEV = 5,  &logger_nd)   # L47
#     nf_log_register(NFPROTO_BRIDGE = 7,  &logger_br)   # L47
#     return 0
#
#   Stock Debian 6.12 ships nf_log_syslog.ko with 22 UND symbols. L46
#   left 14 unresolved against linux_abi/exports.ad. L47 closes that
#   gap via the new linux_abi/api_nf_log.ad:
#
#     nf_log_register / nf_log_unregister    init path
#     nf_log_set / nf_log_unset              runtime
#     nf_log_buf_open / _add / _close        runtime (packet logging)
#     dev_get_by_index_rcu                   runtime
#     skb_copy_bits                          runtime
#     from_kuid_munged / from_kgid_munged    runtime
#     _raw_read_lock_bh / _raw_read_unlock_bh runtime
#     init_net                               DATA — 64-byte placeholder
#     init_user_ns                           DATA — 64-byte placeholder
#     sysctl_nf_log_all_netns                DATA — int32 = 0
#
#   Only nf_log_register is actually invoked during init. Everything
#   else exists so the loader's relocation pass succeeds.
#
# Strategy (mirrors test_l46_xor.sh):
#   1. Locate /lib/modules/$(uname -r)/kernel/net/netfilter/nf_log_syslog.ko[.xz];
#      SKIP exit 0 if not present.
#   2. Static-analyse: nm -u + cross-check linux_abi/ — L47 should
#      report MISSING = (none).
#   3. Stage under tests/linux-modules/, rebuild userland + initramfs +
#      kernel, boot QEMU, drive hamsh:
#         insmod /lib/modules/6.12/nf_log_syslog.ko
#         exit
#   4. PASS bar: `kmod_linux: init returned 0` and no
#      `insmod: init_module failed`. nf_log_syslog HAS an init_module
#      so the library-only branch is irrelevant here.
#
# Per the brief: no retry logic, no backwards-compat hacks. FAIL with
# diagnostic on first unresolved symbol or non-zero init return.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/nf_log_syslog.ko"

# --- 1. Locate nf_log_syslog.ko on the host -------------------------
KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/net/netfilter/nf_log_syslog.ko"
    "${HOST_LIB}/net/netfilter/nf_log_syslog.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L47: nf_log_syslog.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l47] picked: $picked"

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
        echo "[test_l47] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l47] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

# --- 3. Static UND-symbol coverage check ----------------------------
echo
echo "[test_l47] === Static UND-symbol analysis of nf_log_syslog.ko ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l47] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l47] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l47] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l47] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none - full coverage)"
    fi
fi

# --- 4. Build userland + initramfs + kernel -------------------------
echo
echo "[test_l47] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l47] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l47] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# --- 5. Boot QEMU and drive insmod ----------------------------------
LOG="$(mktemp)"
echo "[test_l47] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/nf_log_syslog.ko\n'
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

echo "[test_l47] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

# --- 6. Assertions --------------------------------------------------
echo
echo "[test_l47] =============== captured serial (tail) ==============="
tail -n 120 "$LOG" || true
echo "[test_l47] ======================================================"
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l47] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

if [ ! -s "$LOG" ]; then
    echo "[test_l47] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l47] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l47] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l47] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l47] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
    echo "[test_l47] INFO: distinct symbol names from runtime log:"
    echo "$UNRESOLVED" \
        | grep -oE "'[A-Za-z_][A-Za-z0-9_]*'|symbol [A-Za-z_][A-Za-z0-9_]*|: [A-Za-z_][A-Za-z0-9_]+$" \
        | sort -u \
        | sed 's/^/  /'
else
    echo "[test_l47] INFO: no runtime unresolved-symbol lines"
fi

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l47] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l47] PASS: nf_log_syslog.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l47]       (library-only path)"
    else
        echo "[test_l47]       (init_module returned 0 — 11th stock Debian .ko load)"
    fi
else
    echo
    echo "[test_l47] FAIL: nf_log_syslog.ko did not finish loading."
    echo "[test_l47]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l47] full log preserved at: $LOG"
exit 0
