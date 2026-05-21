#!/usr/bin/env bash
# scripts/test_apt_live.sh — NETWORK TEST: drive userland `apt` against
# a LIVE Debian mirror over the real internet.
#
#   *** THIS TEST REQUIRES OUTBOUND INTERNET CONNECTIVITY. ***
#   *** IT IS NOT PART OF THE GATING REGRESSION BATTERY.   ***
#   *** DO NOT ADD IT TO CI — it depends on deb.debian.org ***
#   *** being reachable and would make CI flaky.           ***
#
# Every other apt test (test_apt_get.sh / test_apt_https.sh / ...)
# fabricates a tiny fake Debian repo on the host and serves it from a
# local Python http.server. This test instead points `apt` at the
# genuine article: https://deb.debian.org/debian — the real Debian
# mirror network, reached over QEMU's user-mode (SLIRP) NAT, which
# gives the guest outbound internet on this dev box.
#
# WHAT IS EXERCISED THAT THE FIXTURE TESTS CANNOT
#
#   * TLS 1.3 against a REAL CA chain: deb.debian.org serves a 2-cert
#     wire chain (leaf `cdn-fastly.deb.debian.org` + Let's Encrypt R13
#     intermediate) chaining up to ISRG Root X1. The kernel validates
#     it against the production ISRG Root X1 anchor that
#     build_initramfs.py bakes into the initramfs from the host's
#     /etc/ssl/certs/ISRG_Root_X1.pem. A real CDN negotiates real
#     cipher/curve choices (X25519 + TLS_AES_128_GCM_SHA256).
#   * DNS resolution of a real hostname (`deb.debian.org`) through the
#     SLIRP-supplied resolver.
#   * A real `Release` file (~150 KiB) and a real gzip'd `Packages`
#     index off the live mirror — orders of magnitude bigger than the
#     few-KiB fixture, exercising the buffer caps and the gzip
#     inflater on real-world data.
#   * `apt install` downloading a real `.deb` (an `ar` archive) off the
#     mirror and SHA-256-verifying it against the live index.
#
# KNOWN GAP — .xz-compressed .deb members
#
# A real `apt install` reaches the `dpkg -i` unpack step but stops
# there: modern Debian `.deb` archives compress their `control.tar` /
# `data.tar` members with `.xz` (LZMA2), and Hamnix's dpkg_deb only
# implements gzip inflate today. This test therefore exercises and
# asserts the live path THROUGH the .deb download + SHA-256 verify
# (the apt-side work), and accepts the dpkg-side `.xz` unpack failure
# as a documented follow-up (an XZ/LZMA2 decoder in lib/) rather than
# a regression. The "fetched a real .deb + verified it" milestone is
# fully covered.
#
# COMPONENT CHOICE — why `contrib`, not `main`
#
# Debian's whole `main/binary-amd64/Packages.gz` for a release is
# ~12 MB compressed; that is far past apt's 256 KiB V0 buffer cap, so
# a full-`main` fetch is out of scope here (streaming inflate to a
# file is a documented V1 backlog item). `apt update` now takes an
# OPTIONAL 4th argument naming the archive component; this test passes
# `contrib`, whose binary-amd64 index is ~64 KiB compressed / ~230 KiB
# inflated — both inside the V0 caps — so the LIVE end-to-end path
# (TLS + DNS + real index fetch + inflate + parse) is fully exercised
# without a streaming rewrite. `crafty-bitmaps` is a small (~8 KiB),
# dependency-free `contrib` package used for the `apt install` leg.
#
# OUTCOMES
#   - apt reached the mirror + parsed the index + installed the .deb
#     -> PASS.
#   - DHCP never bound / mirror unreachable -> SKIP (treated as PASS so
#     a developer running the full suite offline isn't blocked).
#   - apt reached the mirror but something downstream broke -> FAIL.
#
# The QEMU `guestfwd=tcp:10.0.2.100:7-cmd:cat` is REQUIRED even though
# this test never uses that echo target: init/main.ad's
# net_smoke_test() calls tcp_smoke_test() unconditionally during boot
# (same rationale as test_apt_get.sh / test_apt_https.sh).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

# --- live mirror + package identities --------------------------------
MIRROR='https://deb.debian.org/debian'
SUITE='bookworm'
COMPONENT='contrib'
# A small, dependency-free package that lives in contrib/binary-amd64.
LIVE_PKG='crafty-bitmaps'

echo "[test_apt_live] *** NETWORK TEST — requires outbound internet ***"
echo "[test_apt_live] mirror=$MIRROR suite=$SUITE component=$COMPONENT"

# --- host-side reachability probe ------------------------------------
# If the dev box itself can't reach deb.debian.org there is no point
# booting QEMU; SKIP straight away (treated as PASS).
if ! curl -s -o /dev/null --max-time 15 \
        "$MIRROR/dists/$SUITE/$COMPONENT/binary-amd64/Packages.gz"; then
    echo "[test_apt_live] SKIP — host cannot reach $MIRROR (no internet)"
    echo "[test_apt_live] PASS (SKIP)"
    exit 0
fi
echo "[test_apt_live] host reachability probe OK"

echo "[test_apt_live] (1/4) Build userland (hamsh + apt + helpers) + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
if [ ! -x "build/user/apt.elf" ]; then
    echo "[test_apt_live] FAIL: build/user/apt.elf missing after build_user.sh"
    exit 1
fi

echo "[test_apt_live] (2/4) Swap /init = hamsh in cpio initramfs"
# build_initramfs.py bakes the host's ISRG Root X1 into the initramfs
# as /etc/tls-ca-isrg-x1.der automatically — that is the trust anchor
# the live deb.debian.org chain validates against.
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

TMPDIR=$(mktemp -d -t hamnix-apt-live-XXXXXX)
LOG="$TMPDIR/qemu.log"
cleanup() {
    rm -rf "$TMPDIR"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_apt_live] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_apt_live] (4/4) Boot QEMU with virtio-net + SLIRP default NAT"
# SLIRP's default NAT gives the guest outbound internet; no per-host
# guestfwd is needed for the apt fetch itself. The guestfwd below is
# only for the boot-time tcp_smoke_test (see header).
set +e
(
    sleep 60
    printf '/bin/apt update %s %s %s\n' "$MIRROR" "$SUITE" "$COMPONENT"
    sleep 45
    printf 'echo APT_SHOW_START\n'
    printf '/bin/apt show %s\n' "$LIVE_PKG"
    sleep 8
    printf 'echo APT_INSTALL_START\n'
    printf '/bin/apt install %s\n' "$LIVE_PKG"
    sleep 35
    printf 'echo APT_DONE\n'
    printf 'exit\n'
    sleep 2
) | timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_apt_live] --- captured (apt / tls / dns / tcp / dhcp) ---"
grep -E 'apt-get:|apt-cache:|apt:|APT_|\[tls\]|\[dns\]|\[tcp\]|\[dhcp\]|Package:|Status:' \
    "$LOG" || true
echo "[test_apt_live] --- end ---"

# --- skip path: no internet during boot (DHCP never bound) -----------
if grep -F -q "no ACK received during init poll" "$LOG"; then
    echo "[test_apt_live] SKIP (no network — DHCP unbound in guest)"
    echo "[test_apt_live] PASS (SKIP)"
    exit 0
fi
# apt couldn't resolve / connect to the mirror — also a connectivity
# SKIP rather than a code defect.
if grep -F -q "apt: cannot resolve" "$LOG" \
        || grep -F -q "is the mirror reachable?" "$LOG"; then
    echo "[test_apt_live] SKIP (guest could not reach the live mirror)"
    echo "[test_apt_live] PASS (SKIP)"
    exit 0
fi

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_apt_live] OK: '$1'"
    else
        echo "[test_apt_live] MISS: '$1'"
        fail=1
    fi
}

# (a) TLS 1.3 handshake to the real mirror + kernel cert-chain
#     validation against the production ISRG Root X1 anchor.
check "apt: TLS handshake ok for deb.debian.org"
check "[tls] cert chain validated"

# (b) `apt update` fetched the real Release + Packages.gz, inflated
#     and parsed the live contrib index.
check "apt-get: fetched Release ("
check "apt-get: fetched index,"

# (c) `apt show` found a real package's stanza in the live index.
check "Package: $LIVE_PKG"

# (d) `apt install` downloaded a real .deb off the mirror and
#     SHA-256-verified it against the live index. (The subsequent
#     `dpkg -i` unpack fails on the .xz-compressed tar members — a
#     documented follow-up, see the header KNOWN GAP note — so the
#     install itself is NOT asserted here.)
check "apt: fetching pool/contrib/"
check "apt: SHA256 OK ("

# Informational: surface the known .xz unpack gap without failing.
if grep -F -q "unknown .tar compression extension" "$LOG"; then
    echo "[test_apt_live] NOTE: dpkg -i stopped at the .xz unpack step" \
         "(known follow-up — dpkg_deb needs an XZ/LZMA2 decoder)"
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_apt_live] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_apt_live] FAIL (qemu rc=$rc)"
    echo "[test_apt_live] --- full kernel log (last 250 lines) ---"
    tail -n 250 "$LOG"
    exit 1
fi

echo "[test_apt_live] PASS — userland apt reached the LIVE deb.debian.org" \
     "mirror over validated TLS 1.3, fetched + inflated + parsed the real" \
     "$COMPONENT index, and downloaded + SHA-256-verified a real .deb"
