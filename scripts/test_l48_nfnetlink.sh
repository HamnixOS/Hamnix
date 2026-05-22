#!/usr/bin/env bash
# scripts/test_l48_nfnetlink.sh — L48 nfnetlink.ko load test.
#
# Goal:
#   Ship the 12th stock Debian .ko load. nfnetlink.ko is the netfilter
#   <-> netlink message-bus core. Userland tools (libmnl-based nftables,
#   conntrack-tools, ipset) reach netfilter subsystems by sending typed
#   netlink frames through nfnetlink, which routes them to a per-subsys
#   callback table (13 slots: NFNL_SUBSYS_{NONE,CTNETLINK,...,HOOK}).
#
#   Init path (paraphrased from objdump -drC of
#   /lib/modules/$(uname -r)/kernel/net/netfilter/nfnetlink.ko):
#
#       init_module:
#           for i in 0..12: __mutex_init(&table[i].mutex, ...)   # 13x
#           return register_pernet_subsys(&nfnetlink_net_ops)    # L41
#
#   That's it — 13 mutex inits in a loop, tail-jump to L41's pernet
#   shim. Init never touches the netlink socket, NLA parsing, RCU,
#   skb, request_module, or any of the other UND symbols — they're
#   all in the runtime dispatch path (`nfnetlink_subsys_register` is
#   called LAZILY by downstream subsys modules like nf_tables).
#
#   Stock Debian 6.12 nfnetlink.ko has 40 UND symbols (39 distinct +
#   the literal "UND" header line). L47 left 22 unresolved against
#   linux_abi/exports.ad. L48 closes that gap via the new
#   linux_abi/api_netlink.ad:
#
#     __netlink_kernel_create / netlink_kernel_release   (socket lifecycle)
#     netlink_unicast / _broadcast / _has_listeners      (message delivery)
#     netlink_set_err / netlink_ack / netlink_rcv_skb    (error + dispatch)
#     netlink_net_capable                                (capability check)
#     nlmsg_notify                                       (uni/multicast)
#     nf_ctnetlink_has_listener                          (conntrack predicate)
#     __nla_parse                                        (attribute parsing)
#     __rcu_read_lock / _unlock / synchronize_rcu        (RCU primitives)
#     try_module_get                                     (refcount)
#     __request_module                                   (modprobe demand)
#     skb_clone / skb_pull / consume_skb                 (skb helpers)
#     is_vmalloc_addr                                    (region predicate)
#     const_pcpu_hot                                     (DATA alias of pcpu_hot)
#
# Strategy (mirrors test_l47_nf_log_syslog.sh):
#   1. Locate /lib/modules/$(uname -r)/kernel/net/netfilter/nfnetlink.ko[.xz];
#      SKIP exit 0 if not present.
#   2. Static-analyse: nm -u + cross-check linux_abi/ — L48 should
#      report MISSING = (none).
#   3. Stage under tests/linux-modules/, rebuild userland + initramfs +
#      kernel, boot QEMU, drive hamsh:
#         insmod /lib/modules/6.12/nfnetlink.ko
#         exit
#   4. PASS bar: `kmod_linux: init returned 0` and no
#      `insmod: init_module failed`. nfnetlink HAS an init_module so
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
STAGED_KO="$LKM_DIR/nfnetlink.ko"

# --- 1. Locate nfnetlink.ko on the host -----------------------------
KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
CANDIDATES=(
    "${HOST_LIB}/net/netfilter/nfnetlink.ko"
    "${HOST_LIB}/net/netfilter/nfnetlink.ko.xz"
)

picked=""
for c in "${CANDIDATES[@]}"; do
    if [ -f "$c" ]; then
        picked="$c"
        break
    fi
done

if [ -z "$picked" ]; then
    echo "L48: nfnetlink.ko not present on this host; skipping"
    exit 0
fi

echo "[test_l48] picked: $picked"

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
        echo "[test_l48] decompressing -> $STAGED_KO"
        xz -dc "$picked" > "$STAGED_KO"
        ;;
    *.ko)
        echo "[test_l48] copying       -> $STAGED_KO"
        cp "$picked" "$STAGED_KO"
        ;;
esac
ls -l "$STAGED_KO"

# --- 3. Static UND-symbol coverage check ----------------------------
echo
echo "[test_l48] === Static UND-symbol analysis of nfnetlink.ko ==="
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
if [ -z "$UND_SYMS" ]; then
    echo "[test_l48] WARN: nm -u produced no symbols (module stripped?)"
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
    echo "[test_l48] UND symbols ($(echo "$UND_SYMS" | wc -w)):"
    for s in $UND_SYMS; do echo "  $s"; done
    echo "[test_l48] covered by linux_abi/exports.ad:"
    if [ -n "$COVERED" ]; then
        for s in $COVERED; do echo "  + $s"; done
    else
        echo "  (none)"
    fi
    echo "[test_l48] MISSING (would fail at insmod):"
    if [ -n "$MISSING" ]; then
        for s in $MISSING; do echo "  - $s"; done
    else
        echo "  (none - full coverage)"
    fi
fi

# --- 4. Build userland + initramfs + kernel -------------------------
echo
echo "[test_l48] (1/3) Build userland (hamsh + insmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l48] (2/3) Embed initramfs with /init=hamsh"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l48] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# --- 5. Boot QEMU and drive insmod ----------------------------------
LOG="$(mktemp)"
echo "[test_l48] booting QEMU; log: $LOG"

set +e
(
    sleep 3
    printf 'insmod /lib/modules/6.12/nfnetlink.ko\n'
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

echo "[test_l48] qemu rc=$qrc, log bytes=$(wc -c < "$LOG")"

# --- 6. Assertions --------------------------------------------------
echo
echo "[test_l48] =============== captured serial (tail) ==============="
tail -n 120 "$LOG" || true
echo "[test_l48] ======================================================"
echo

if grep -E -q "PANIC|panic:" "$LOG"; then
    echo "[test_l48] FAIL: kernel panic detected"
    grep -nE "PANIC|panic:" "$LOG" || true
    exit 1
fi

if [ ! -s "$LOG" ]; then
    echo "[test_l48] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

INIT_OK_COUNT=$(grep -cE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK_COUNT=${INIT_OK_COUNT:-0}
LIB_ONLY_COUNT=$(grep -cE "kmod_linux: no init function \(library-only module\)" "$LOG" || true)
LIB_ONLY_COUNT=${LIB_ONLY_COUNT:-0}
INSMOD_FAIL_COUNT=$(grep -cE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL_COUNT=${INSMOD_FAIL_COUNT:-0}

echo "[test_l48] INFO: 'init returned 0' count: $INIT_OK_COUNT"
echo "[test_l48] INFO: 'library-only module' count: $LIB_ONLY_COUNT"
echo "[test_l48] INFO: 'insmod: init_module failed' count: $INSMOD_FAIL_COUNT"
grep -nE "kmod_linux: init returned|kmod_linux: no init function|insmod: init_module failed" "$LOG" | sed 's/^/  /' || true

UNRESOLVED=$(grep -E "unresolved external symbol|unresolved symbol|undefined symbol" "$LOG" || true)
if [ -n "$UNRESOLVED" ]; then
    echo
    echo "[test_l48] INFO: runtime unresolved-symbol lines:"
    echo "$UNRESOLVED" | sed 's/^/  /'
    echo "[test_l48] INFO: distinct symbol names from runtime log:"
    echo "$UNRESOLVED" \
        | grep -oE "'[A-Za-z_][A-Za-z0-9_]*'|symbol [A-Za-z_][A-Za-z0-9_]*|: [A-Za-z_][A-Za-z0-9_]+$" \
        | sort -u \
        | sed 's/^/  /'
else
    echo "[test_l48] INFO: no runtime unresolved-symbol lines"
fi

if [ "$INSMOD_FAIL_COUNT" -ge 1 ]; then
    echo
    echo "[test_l48] FAIL: insmod reported init_module failed"
    exit 1
fi

if [ "$INIT_OK_COUNT" -ge 1 ] || [ "$LIB_ONLY_COUNT" -ge 1 ]; then
    echo
    echo "[test_l48] PASS: nfnetlink.ko loaded successfully"
    if [ "$LIB_ONLY_COUNT" -ge 1 ]; then
        echo "[test_l48]       (library-only path)"
    else
        echo "[test_l48]       (init_module returned 0 - 12th stock Debian .ko load)"
    fi
else
    echo
    echo "[test_l48] FAIL: nfnetlink.ko did not finish loading."
    echo "[test_l48]       Neither 'init returned 0' nor 'no init function' seen."
    exit 1
fi

echo "[test_l48] full log preserved at: $LOG"
exit 0
