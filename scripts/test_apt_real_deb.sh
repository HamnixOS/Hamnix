#!/usr/bin/env bash
# scripts/test_apt_real_deb.sh — apt-path end-to-end regression:
# `apt install` of a REAL Debian package.
#
# This is the goal-3 milestone proof for the FULL apt chain. Where
# scripts/test_apt_install.sh fabricates its `.deb` on the host with
# `ar + tar + gzip` (gzip codepath only), this test serves a GENUINE
# Debian `hello` package — an `ar` archive with xz-compressed
# control.tar / data.tar members, fetched once from deb.debian.org and
# cached at build/cache/ — from a local fake repo, and drives:
#
#   apt update   -> fetch + decompress the Packages index, persist the
#                   base-url to /tmp/apt/base-url
#   apt install  -> look hello up in the index, HTTP GET the real
#                   .deb, SHA-256-verify it against the index, spawn
#                   `dpkg -i`
#   dpkg -s      -> confirm the real package registered in the dpkg DB
#
# The .deb served is byte-identical to what `apt install hello` would
# pull from a live Debian mirror, so this exercises the genuine
# ar-walk + xz-decompress + ustar-parse install path; the only thing
# faked is the network endpoint (a host http.server, SLIRP-aliased to
# 10.0.2.2 — the same shape as test_apt_install.sh / test_apt_get.sh).
#
# OFFLINE BEHAVIOUR: if the real `.deb` cannot be fetched and is not
# cached, scripts/fetch_real_deb.py emits "SKIP" and this test SKIPs
# (exit 0) rather than FAILing. Once build/cache/hello_*.deb exists
# every subsequent run is fully offline + deterministic.
#
# NETWORKING NOTE — the QEMU guestfwd is REQUIRED even though this
# test never uses that echo target: init/main.ad's net_smoke_test()
# runs unconditionally during boot and a tcp_connect to an
# unreachable host would spin forever. Same shape as
# scripts/test_apt_install.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# The real Debian package under test. `hello` is Debian's canonical
# tiny package; pinned to 2.10-5 so the fixture is stable.
PKG_NAME='hello'
PKG_VERSION='2.10-5'
ARCH='amd64'
DEB_URL='http://deb.debian.org/debian/pool/main/h/hello/hello_2.10-5_amd64.deb'
DEB_SHA='4536aabbb75ec21ffe161099ee4b97274945770bdb0682e25ec322421211ca5e'

echo "[test_apt_real_deb] (1/6) Fetch the real Debian $PKG_NAME .deb"
REPO_DIR=$(mktemp -d --tmpdir hamnix-apt-realdeb.XXXXXX)
DIST_DIR="$REPO_DIR/dists/stable"
BIN_DIR="$DIST_DIR/main/binary-amd64"
mkdir -p "$BIN_DIR"

# Place the real .deb in the repo pool tree at the canonical Debian
# pool path so the index Filename field is realistic.
GOOD_REL="pool/main/h/${PKG_NAME}/${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"
GOOD_DEB="$REPO_DIR/$GOOD_REL"
mkdir -p "$(dirname "$GOOD_DEB")"

set +e
FETCH_OUT=$(python3 scripts/fetch_real_deb.py "$GOOD_DEB" \
    --url "$DEB_URL" --sha256 "$DEB_SHA" 2>&1)
FETCH_RC=$?
set -e
echo "$FETCH_OUT"
if [ "$FETCH_RC" -ne 0 ]; then
    if echo "$FETCH_OUT" | grep -F -q "SKIP"; then
        echo "[test_apt_real_deb] SKIP — real $PKG_NAME .deb unavailable" \
             "(offline and uncached)"
        rm -rf "$REPO_DIR"
        exit 0
    fi
    echo "[test_apt_real_deb] FAIL: could not obtain the fixture .deb"
    rm -rf "$REPO_DIR"
    exit 1
fi

GOOD_SIZE=$(stat -c%s "$GOOD_DEB")
GOOD_SHA=$(sha256sum "$GOOD_DEB" | cut -d' ' -f1)
echo "[test_apt_real_deb]   pool: $GOOD_REL ($GOOD_SIZE bytes) sha=$GOOD_SHA"

if command -v ar >/dev/null 2>&1 && ! ar t "$GOOD_DEB" | grep -F -q 'data.tar.xz'; then
    echo "[test_apt_real_deb] FAIL: fixture has no data.tar.xz —" \
         "not exercising the xz install path"
    rm -rf "$REPO_DIR"
    exit 1
fi

echo "[test_apt_real_deb] (2/6) Fabricate the fake Debian repo index"

# dists/stable/Release — one RFC822 stanza.
cat > "$DIST_DIR/Release" <<EOF
Origin: Hamnix
Label: Hamnix
Suite: stable
Codename: stable
Architectures: amd64
Components: main
Description: Hamnix apt real-deb test repository
EOF

# A hand-written Packages index: one stanza for the real package,
# carrying its REAL Filename / Size / SHA256 so apt's verification is
# a genuine check against the genuine bytes.
PACKAGES_PLAIN="$REPO_DIR/Packages.plain"
cat > "$PACKAGES_PLAIN" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION
Architecture: $ARCH
Filename: $GOOD_REL
Size: $GOOD_SIZE
SHA256: $GOOD_SHA
Description: Debian hello served as an apt real-package fixture
EOF
gzip -9 -c "$PACKAGES_PLAIN" > "$BIN_DIR/Packages.gz"
echo "[test_apt_real_deb]   Packages.gz: $(stat -c%s "$BIN_DIR/Packages.gz") bytes"

echo "[test_apt_real_deb] (3/6) Build userland + swap /init = hamsh in cpio"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
for b in apt dpkg; do
    if [ ! -x "build/user/${b}.elf" ]; then
        echo "[test_apt_real_deb] FAIL: build/user/${b}.elf missing after build"
        rm -rf "$REPO_DIR"
        exit 1
    fi
done
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_apt_real_deb] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_apt_real_deb] (5/6) Start host http.server + boot QEMU"
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_apt_real_deb]   using host port $PORT"

LOG=$(mktemp)
SRVLOG=$(mktemp)
python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$REPO_DIR" \
    > "$SRVLOG" 2>&1 &
SRV_PID=$!

cleanup() {
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
    rm -rf "$LOG" "$SRVLOG" "$REPO_DIR"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Give the server a moment to bind.
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
    printf '/bin/apt update http://10.0.2.2:%s stable\n' "$PORT"
    sleep 20
    printf 'echo APT_REAL_INSTALL_START\n'
    printf '/bin/apt install %s\n' "$PKG_NAME"
    sleep 25
    printf 'echo APT_REAL_DPKG_S_START\n'
    printf '/bin/dpkg -s %s\n' "$PKG_NAME"
    sleep 5
    printf 'echo APT_REAL_DPKG_L_START\n'
    printf '/bin/dpkg -L %s\n' "$PKG_NAME"
    sleep 5
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

echo "[test_apt_real_deb] --- captured (apt / dpkg / APT_) ---"
grep -E 'apt:|apt-get:|dpkg:|dpkg-query:|APT_REAL|Package:|Status:' "$LOG" || true
echo "[test_apt_real_deb] --- end ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_apt_real_deb] OK: '$1'"
    else
        echo "[test_apt_real_deb] MISS: '$1'"
        fail=1
    fi
}

# (a) apt update fetched + parsed the index.
check "apt-get: fetched index, 1 packages"

# (b) apt install downloaded the real .deb and SHA-256-verified it.
check "apt: fetching $GOOD_REL"
check "apt: SHA256 OK ("

# (c) dpkg installed the real package (its xz members decompressed).
check "dpkg: registered $PKG_NAME $PKG_VERSION ("
check "apt: installed $PKG_NAME $PKG_VERSION"

# (d) the package is in the dpkg DB — read back via dpkg -s.
S_WINDOW=$(sed -n '/APT_REAL_DPKG_S_START/,/APT_REAL_DPKG_L_START/p' "$LOG")
if echo "$S_WINDOW" | grep -F -q "Package: $PKG_NAME" \
   && echo "$S_WINDOW" | grep -F -q "Status: install ok installed"; then
    echo "[test_apt_real_deb] OK: dpkg -s shows $PKG_NAME registered"
else
    echo "[test_apt_real_deb] MISS: dpkg -s did not show $PKG_NAME"
    fail=1
fi

# (e) dpkg -L lists a file from the real xz-decompressed data.tar.
if grep -F -q "./usr/bin/hello" "$LOG"; then
    echo "[test_apt_real_deb] OK: dpkg -L lists ./usr/bin/hello"
else
    echo "[test_apt_real_deb] MISS: dpkg -L did not list ./usr/bin/hello"
    fail=1
fi

# (f) no decompression error leaked.
if grep -E -q "dpkg: (xz decompress failed|unsupported compression|gzip inflate failed)" "$LOG"; then
    echo "[test_apt_real_deb] MISS: dpkg reported a decompression error"
    grep -E "dpkg: (xz decompress failed|unsupported compression|gzip inflate failed)" "$LOG" | head -3
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_apt_real_deb] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_apt_real_deb] FAIL (qemu rc=$rc)"
    echo "[test_apt_real_deb] --- full kernel log (last 160 lines) ---"
    tail -n 160 "$LOG"
    echo "[test_apt_real_deb] --- http.server log ---"
    cat "$SRVLOG" || true
    exit 1
fi

echo "[test_apt_real_deb] PASS — apt install fetched a REAL Debian .deb" \
     "over HTTP, SHA-256-verified it, and dpkg-installed it" \
     "(xz-compressed control.tar/data.tar)"
