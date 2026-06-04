#!/usr/bin/env bash
# scripts/test_igmp.sh — native IPv4 multicast + IGMPv2/v3 self-test.
#
# Boots the kernel once with /etc/igmp-test planted (ENABLE_IGMP_TEST=1).
# init/main.ad at boot:37.igmp calls igmp_selftest() (drivers/net/igmp.ad),
# a fully in-memory test (NO external NIC required) that PROVES the native
# IPv4 multicast + IGMP (RFC 2236 / RFC 3376) path:
#
#   * IGMPv2 (type 0x16) and IGMPv3 (type 0x22) Membership Reports are
#     built and parsed back, asserting the message type, the carried group
#     (239.1.2.3), and the RFC-1071 IGMP checksum.
#   * The multicast-MAC mapping 239.1.2.3 -> 01:00:5e:01:02:03 is asserted
#     (incl. the 23-bit fold: 239.129.2.3 maps to the same MAC).
#   * join(239.1.2.3) records the membership and sends an unsolicited
#     Report; the multicast RX-accept predicate then ACCEPTs a datagram to
#     that group, REJECTs an unjoined group, and always ACCEPTs the
#     all-hosts 224.0.0.1.
#   * leave(239.1.2.3) sends a Leave and clears the membership; the
#     predicate flips back to REJECT for that group.
#   * A Membership Query (type 0x11) produces a Report for the joined group.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [igmp] PASS
# Fail marker:  [igmp] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_igmp] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_igmp] (2/3) Build kernel with /etc/igmp-test marker"
INIT_ELF=build/user/init.elf ENABLE_IGMP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_igmp] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_igmp] --- captured (igmp lines) ---"
grep -E '\[igmp\]|\[boot:37.igmp\]' "$LOG" || true
echo "[test_igmp] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_igmp] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[igmp] FAIL" "$LOG"; then
    echo "[test_igmp] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.igmp] FAIL" "$LOG"; then
    echo "[test_igmp] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_igmp] PASS: $label"
    else
        echo "[test_igmp] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"               "[igmp] self-test start"
check "v2 report build/parse"       "[igmp] PASS v2-report-build-parse"
check "v3 report build/parse"       "[igmp] PASS v3-report-build-parse"
check "mcast mac mapping"           "[igmp] PASS mcast-mac (239.1.2.3 -> 01:00:5e:01:02:03)"
check "mcast mac 23-bit fold"       "[igmp] PASS mcast-mac-23bit-fold"
check "rx reject before join"       "[igmp] PASS rx-reject-before-join"
check "rx accept all-hosts"         "[igmp] PASS rx-accept-all-hosts (224.0.0.1)"
check "join sends report"           "[igmp] PASS join-sends-report"
check "rx accept after join"        "[igmp] PASS rx-accept-after-join"
check "rx reject unjoined"          "[igmp] PASS rx-reject-unjoined"
check "query produces report"       "[igmp] PASS query-produces-report"
check "query group-specific miss"   "[igmp] PASS query-group-specific-mismatch"
check "leave clears membership"     "[igmp] PASS leave-clears-membership"
check "all-hosts still accept"      "[igmp] PASS all-hosts-still-accept-after-leave"
check "igmp PASS banner"            "[igmp] PASS"
check "boot gate PASS"              "[boot:37.igmp] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_igmp] FAIL"
    exit 1
fi

echo "[test_igmp] PASS — native IPv4 multicast + IGMPv2/v3 (RFC 2236 / RFC 3376): v2+v3 Membership Report build/parse with correct type/group/checksum, group-IP -> 01:00:5e multicast-MAC mapping, join/leave membership driving the multicast RX-accept predicate (joined ACCEPT, unjoined REJECT, all-hosts 224.0.0.1 always ACCEPT), and Membership-Query -> Report all verified"
