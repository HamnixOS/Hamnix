#!/usr/bin/env bash
# scripts/test_u_resolve.sh — U-resolve regression: a userland binary
# resolves a HOSTNAME to an IPv4 via the in-kernel DNS resolver and
# connects to it.
#
# Commit 6459613 left `apt update` able to reach a Debian mirror only
# by IPv4 literal (`http://<A.B.C.D>:port/...`). This milestone wires a
# native syscall SYS_RESOLVE (269) that bridges userland to the
# existing in-kernel resolver (drivers/net/dns.ad::dns_lookup), and
# teaches user/apt.ad's URL parser to resolve a hostname through it. An
# IPv4-literal URL keeps working unchanged.
#
# --- DNS SETUP — why this test is shaped the way it is ---------------
#
# The guest's kernel learns its DNS server from DHCP option 6. Under
# QEMU's SLIRP backend that address is ALWAYS SLIRP's own virtual
# nameserver (the `-netdev user,dns=...` value, default 10.0.2.3) and
# SLIRP intercepts UDP/53 to it with a built-in forwarder that proxies
# to the *host's* /etc/resolv.conf resolver. There is no QEMU knob to
# substitute a custom DNS server: a `dns=` outside SLIRP's /24 is
# silently remapped INTO the /24 and still intercepted; a `guestfwd`
# is TCP-only and our resolver is UDP-only. So a hand-rolled host-side
# DNS responder cannot be wired into the guest's resolve path.
#
# Therefore this test drives the resolver through SLIRP's real
# forwarder (same model as scripts/test_dns.sh) and is split in two:
#
#   PHASE 1 — IPv4-literal regression (DETERMINISTIC, always runs).
#     Stands up a host http.server rooted at a fabricated 3-package
#     Debian repo, reachable from the guest at the SLIRP host alias
#     10.0.2.2, and runs `apt update http://10.0.2.2:PORT stable`.
#     Asserts the index is fetched + decompressed + parsed. This is
#     the unchanged-IPv4-path guarantee — it must always PASS.
#
#   PHASE 2 — hostname resolve + connect (REAL DNS; SKIP if offline).
#     Runs `apt update http://deb.debian.org/<nonexistent> stable`.
#     apt's URL parser sees a non-dotted-quad host, calls
#     sys_resolve(269) -> the in-kernel resolver -> a real A-record
#     query through SLIRP's forwarder, then TCP-connects to the
#     returned IPv4 and issues an HTTP GET. Asserts the
#     "apt: resolved deb.debian.org -> <ip>" line printed by the new
#     _resolve_host path AND the "[u_socket] connect -> <ip>:80" that
#     proves the resolved address fed connect(). We deliberately point
#     the path at a NON-EXISTENT repo subtree so the mirror answers a
#     small 404 quickly — that exercises resolve + TCP connect + HTTP
#     round-trip without dragging a multi-MB real Packages.gz through
#     apt's V0 256 KiB buffer. If SLIRP's forwarder gets no answer (CI
#     sandbox blocks egress) the kernel logs "[dns] timeout" and
#     Phase 2 SKIPs — the resolve code path was still compiled + run.
#
# A real FAIL is: Phase 1 regressed, OR Phase 2 resolved a name but
# crashed / never reached connect, OR the kernel reported a CPU trap.
#
# NETWORKING NOTE — the QEMU `guestfwd=tcp:10.0.2.100:7-cmd:cat` is
# REQUIRED even though this test never uses that echo target: see the
# identical note in scripts/test_apt_get.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# The real hostname Phase 2 resolves. deb.debian.org is a stable,
# well-known mirror CNAME — RFC-2606-safe alternative is example.com
# (used by test_dns.sh); we use deb.debian.org because that is the
# actual host `apt` will need in production.
RESOLVE_HOST='deb.debian.org'

# --- fixture package identities (Phase 1) ----------------------------
PKG_A='hamnix-base'
VER_A='1.0.0'
PKG_B='libhamc1'
VER_B='2.4.1'
PKG_C='hamnix-utils'
VER_C='0.9'

# --- pick a free host port for the fixture http.server --------------
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_u_resolve] fixture http.server host port: $PORT"

echo "[test_u_resolve] (1/6) Build userland (hamsh + apt + helpers) + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

if [ ! -x "build/user/apt.elf" ]; then
    echo "[test_u_resolve] FAIL: build/user/apt.elf missing after build_user.sh"
    exit 1
fi

echo "[test_u_resolve] (2/6) Fabricate fake Debian repo tree (Phase 1)"
REPO_DIR=$(mktemp -d --tmpdir hamnix-resolve-repo.XXXXXX)
DIST_DIR="$REPO_DIR/dists/stable"
BIN_DIR="$DIST_DIR/main/binary-amd64"
mkdir -p "$BIN_DIR"

cat > "$DIST_DIR/Release" <<EOF
Origin: Hamnix
Label: Hamnix
Suite: stable
Codename: stable
Architectures: amd64
Components: main
Description: Hamnix U-resolve test repository
EOF

PACKAGES_PLAIN="$REPO_DIR/Packages.plain"
cat > "$PACKAGES_PLAIN" <<EOF
Package: $PKG_A
Version: $VER_A
Architecture: amd64
Filename: pool/main/h/hamnix-base/${PKG_A}_${VER_A}_amd64.deb
Size: 4096
SHA256: 0000000000000000000000000000000000000000000000000000000000000001
Depends: libhamc1
Description: APTV0_OK Hamnix base system metapackage
 This is the continuation line for the base package.

Package: $PKG_B
Version: $VER_B
Architecture: amd64
Filename: pool/main/libh/libhamc1/${PKG_B}_${VER_B}_amd64.deb
Size: 20480
SHA256: 0000000000000000000000000000000000000000000000000000000000000002
Description: Hamnix C runtime shared library

Package: $PKG_C
Version: $VER_C
Architecture: amd64
Filename: pool/main/h/hamnix-utils/${PKG_C}_${VER_C}_amd64.deb
Size: 8192
SHA256: 0000000000000000000000000000000000000000000000000000000000000003
Depends: hamnix-base
Description: Assorted Hamnix command-line utilities
EOF

gzip -9 -c "$PACKAGES_PLAIN" > "$BIN_DIR/Packages.gz"
echo "[test_u_resolve]   repo: $REPO_DIR"

echo "[test_u_resolve] (3/6) Swap /init = hamsh in cpio initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_u_resolve] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_u_resolve] (5/6) Start host http.server, boot QEMU"
LOG=$(mktemp)
SRVLOG=$(mktemp)

python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$REPO_DIR" \
    > "$SRVLOG" 2>&1 &
SRV_PID=$!

cleanup() {
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
    rm -rf "$LOG" "$SRVLOG" "$REPO_DIR"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Give the http.server a moment to bind.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if python3 - "$PORT" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket()
s.settimeout(0.3)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    s.close()
except Exception:
    sys.exit(1)
PY
    then
        break
    fi
    sleep 0.3
done

set +e
(
    sleep 60
    # PHASE 1 — IPv4 literal against the local fixture (deterministic).
    printf 'echo APT_LITERAL_START\n'
    printf '/bin/apt update http://10.0.2.2:%s stable\n' "$PORT"
    sleep 20
    # PHASE 2 — resolve a real hostname via the kernel DNS resolver and
    # connect to it. The /hamnix-no-such-repo subtree does not exist on
    # the mirror, so the GET for its dists/stable/Release gets a small
    # 404 — apt resolves + connects + does the HTTP round-trip + bails
    # fast, proving the hostname path without a multi-MB fetch.
    printf 'echo APT_RESOLVE_START\n'
    printf '/bin/apt update http://%s/hamnix-no-such-repo stable\n' \
        "$RESOLVE_HOST"
    sleep 25
    printf 'echo APT_DONE\n'
    printf 'exit\n'
    sleep 2
) | timeout 240s qemu-system-x86_64 \
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

echo "[test_u_resolve] --- captured (apt / dns / u_socket / tcp) ---"
grep -E 'apt:|apt-get:|APT_|\[dns\]|\[u_socket\]|\[tcp\]|Package:' "$LOG" \
    || true
echo "[test_u_resolve] --- end ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_u_resolve] OK: '$1'"
    else
        echo "[test_u_resolve] MISS: '$1'"
        fail=1
    fi
}

# === PHASE 1 — IPv4-literal path must still work (DETERMINISTIC) ======
# The "fetched index, 3 packages" line proves the IPv4-literal pipeline
# end to end: TCP connect to 10.0.2.2, two HTTP GETs, gunzip, and an
# RFC822 stanza count — exactly the apt-get V0 path commit f61d70f
# shipped, unchanged by the U-resolve work.
check "APT_LITERAL_START"
check "apt-get: fetched Release ("
check "apt-get: fetched index, 3 packages"

# === PHASE 2 — hostname resolve via the kernel DNS resolver ===========
# Outcome tree (mirrors test_dns.sh's SKIP-on-no-internet rule):
#   * "apt: resolved deb.debian.org -> "  — the userland resolve path
#       reached the kernel DNS resolver, got an A-record, and apt is
#       proceeding to connect. PASS for Phase 2.
#   * "[dns] timeout" or "apt: cannot resolve" — no internet in the
#       sandbox; the resolve code path compiled + ran but the SLIRP
#       forwarder had nothing to answer with. SKIP (accepted).
#   * neither, but APT_RESOLVE_START seen — the guest never reached
#       sys_resolve; that's a real regression.
phase2='UNKNOWN'
if grep -F -q "apt: resolved $RESOLVE_HOST -> " "$LOG"; then
    phase2='RESOLVED'
    echo "[test_u_resolve] OK: userland resolved '$RESOLVE_HOST' via" \
         "the kernel DNS resolver"
    # Having resolved, apt must have attempted a TCP connect — the
    # u_socket connect log line proves the resolved IP fed connect().
    if grep -F -q "[u_socket] connect ->" "$LOG"; then
        echo "[test_u_resolve] OK: apt connected to the resolved IP"
    else
        echo "[test_u_resolve] MISS: resolved but no TCP connect attempt"
        fail=1
    fi
elif grep -F -q "[dns] timeout" "$LOG" \
     || grep -F -q "apt: cannot resolve" "$LOG"; then
    phase2='SKIP'
    echo "[test_u_resolve] SKIP Phase 2: no internet — DNS resolve" \
         "code path exercised but the SLIRP forwarder had no answer"
elif grep -F -q "APT_RESOLVE_START" "$LOG"; then
    echo "[test_u_resolve] FAIL Phase 2: guest reached the resolve" \
         "command but never resolved or timed out (regression)"
    fail=1
else
    echo "[test_u_resolve] FAIL Phase 2: guest never reached the" \
         "resolve command"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u_resolve] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u_resolve] FAIL (qemu rc=$rc)"
    echo "[test_u_resolve] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    echo "[test_u_resolve] --- http.server log ---"
    cat "$SRVLOG" || true
    exit 1
fi

if [ "$phase2" = "SKIP" ]; then
    echo "[test_u_resolve] PASS — IPv4-literal apt path intact;" \
         "hostname-resolve path compiled + exercised (Phase 2 SKIP," \
         "no internet)"
else
    echo "[test_u_resolve] PASS — a userland binary resolved" \
         "'$RESOLVE_HOST' to an IPv4 via the in-kernel DNS resolver" \
         "and TCP-connected to it; the IPv4-literal path still works"
fi
