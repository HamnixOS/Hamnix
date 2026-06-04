#!/usr/bin/env bash
# scripts/test_l2tp.sh — native L2TPv3 (RFC 3931) encap/decap self-test.
#
# Boots the kernel once with /etc/l2tp-test planted (ENABLE_L2TP_TEST=1).
# init/main.ad at boot:37.l2tp calls l2tp_selftest() (drivers/net/l2tp.ad),
# a fully in-memory test (NO external NIC required) that PROVES the native
# L2TPv3-over-UDP Ethernet-pseudowire path with per-session cookie demux:
#
#   * ENCAP: a known inner Ethernet frame is tunneled to a Session ID over
#     UDP/IPv4 producing Eth | IP(proto=UDP) | UDP(dport=1701) |
#     L2TPv3(SessionID [+ optional 64-bit Cookie] + default L2-specific
#     sublayer with S bit + 24-bit sequence number) | inner, with all lengths
#     and checksums computed via the native stack helpers (ip_csum16 + a
#     pseudo-header UDP csum).
#   * DECAP: the outer frame is validated (UDP/1701 + non-zero Session ID),
#     demultiplexed on the expected Session ID and (when negotiated) the
#     64-bit Cookie, and the L2TPv3 header + sublayer are STRIPPED to recover
#     the inner Ethernet frame BYTE-FOR-BYTE.
#   * Two distinct sessions are exercised: session A (0x11112222) WITHOUT a
#     cookie and session B (0x33334444) WITH a 64-bit cookie, each with its
#     own sequence number; the inner frame + Session ID + cookie + sequence
#     are asserted byte-identical, the IPv4 + UDP checksums are recomputed and
#     matched, and the L2TPv3 header is re-parsed off the on-wire frame.
#   * Negative tests: a wrong cookie is rejected (-4), an unknown Session ID
#     is rejected (-3), and a non-1701 frame is not recognised as L2TPv3.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [l2tp] PASS
# Fail marker:  [l2tp] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_l2tp] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_l2tp] (2/3) Build kernel with /etc/l2tp-test marker"
INIT_ELF=build/user/init.elf ENABLE_L2TP_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_l2tp] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_l2tp] --- captured (l2tp lines) ---"
grep -E '\[l2tp\]|\[boot:37.l2tp\]' "$LOG" || true
echo "[test_l2tp] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_l2tp] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[l2tp] FAIL" "$LOG"; then
    echo "[test_l2tp] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.l2tp] FAIL" "$LOG"; then
    echo "[test_l2tp] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_l2tp] PASS: $label"
    else
        echo "[test_l2tp] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"                 "[l2tp] self-test start"
check "outer length (sessionA)"       "[l2tp] PASS outer-len="
check "dport 1701"                    "[l2tp] PASS dport=1701"
check "session-id A (no-cookie)"      "[l2tp] PASS session-id="
check "seq A (no-cookie)"             "[l2tp] PASS seq="
check "ip checksum valid"             "[l2tp] PASS ip-checksum-valid"
check "ip checksum self-consistent"   "[l2tp] PASS ip-checksum-self-consistent"
check "udp checksum valid (sessionA)" "[l2tp] PASS udp-checksum-valid (sessionA)"
check "roundtrip byte-identical A"    "[l2tp] PASS roundtrip-byte-identical (sessionA no-cookie)"
check "cookie on wire"                "[l2tp] PASS cookie-on-wire (64-bit)"
check "udp checksum valid (sessionB)" "[l2tp] PASS udp-checksum-valid (sessionB)"
check "roundtrip byte-identical B"    "[l2tp] PASS roundtrip-byte-identical (sessionB cookie)"
check "reject wrong cookie"           "[l2tp] PASS reject-wrong-cookie"
check "reject unknown session"        "[l2tp] PASS reject-unknown-session"
check "reject non-l2tp"               "[l2tp] PASS reject-non-l2tp (dport 1234)"
check "l2tp PASS banner"              "[l2tp] PASS"
check "boot gate PASS"                "[boot:37.l2tp] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_l2tp] FAIL"
    exit 1
fi

echo "[test_l2tp] PASS — native L2TPv3 (RFC 3931) Ethernet pseudowire: inner-frame ENCAP into Eth|IP|UDP:1701|L2TPv3(SessionID[+Cookie]+L2-sublayer)|inner with correct lengths + IPv4/UDP checksums, byte-exact DECAP round-trip demuxed on Session ID + optional 64-bit cookie + 24-bit sequence across two sessions (one cookie-less, one cookied), and rejection of wrong-cookie / unknown-session / non-1701 frames all verified"
