#!/usr/bin/env bash
# scripts/test_apt_nsrun.sh — the "apt install under nsrun" milestone
# proof: `apt install <pkg>` routes its dpkg step through `nsrun` so the
# package's files ACTUALLY LAND in the distrofs-served distro namespace
# and are readable there afterwards.
#
# Where scripts/test_apt_real_deb.sh proves `apt install` records the
# metadata (status stanza + .list manifest), and scripts/
# test_dpkg_install.sh proves a bare `dpkg -i` under nsrun lands the
# files, THIS test proves the remaining gap: `apt install` itself —
# download + SHA-256 verify + dpkg — lands the real package's binary
# and docs into the distro namespace, end to end.
#
# Pipeline (combines test_apt_real_deb.sh's fake-repo shape with
# test_dpkg_install.sh's nsrun-fixture driving):
#   1. Fetch the real Debian `hello` .deb (cached at build/cache/).
#   2. Fabricate a fake Debian repo serving that .deb via host
#      http.server (SLIRP-aliased to 10.0.2.2).
#   3. Build userland (hamsh + apt + dpkg + distrofs + nsrun + fixture).
#   4. Plant /init = hamsh in the cpio.
#   5. Rebuild the kernel.
#   6. Boot QEMU and, from hamsh:
#        /bin/apt update http://10.0.2.2:<port> stable
#        /bin/nsrun /bin/test_apt_install
#      `apt update` persists /tmp/apt/{base-url,Packages} (a global
#      tmpfs nsrun does not rebind). Then nsrun spawns three distrofs
#      daemons, mounts them at /var,/usr,/etc, and exec's the fixture.
#      The fixture spawns `apt install hello`; apt — detecting it is
#      already in a distrofs namespace — spawns `dpkg -i` directly so
#      its data.tar extraction lands on those daemons. The fixture then
#      opens /usr/bin/hello AND /usr/share/doc/hello/copyright IN THE
#      SAME namespace and asserts both are present.
#   7. Grep the serial log for the markers.
#
# OFFLINE BEHAVIOUR: if the real .deb cannot be fetched and is not
# cached, scripts/fetch_real_deb.py emits "SKIP" and this test SKIPs.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_apt_install.elf

PKG_NAME='hello'
PKG_VERSION='2.10-5'
ARCH='amd64'
DEB_URL='http://deb.debian.org/debian/pool/main/h/hello/hello_2.10-5_amd64.deb'
DEB_SHA='4536aabbb75ec21ffe161099ee4b97274945770bdb0682e25ec322421211ca5e'

echo "[test_apt_nsrun] (1/7) Fetch the real Debian $PKG_NAME .deb"
REPO_DIR=$(mktemp -d --tmpdir hamnix-apt-nsrun.XXXXXX)
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
        echo "[test_apt_nsrun] SKIP — real $PKG_NAME .deb unavailable" \
             "(offline and uncached)"
        rm -rf "$REPO_DIR"
        exit 0
    fi
    echo "[test_apt_nsrun] FAIL: could not obtain the fixture .deb"
    rm -rf "$REPO_DIR"
    exit 1
fi

GOOD_SIZE=$(stat -c%s "$GOOD_DEB")
GOOD_SHA=$(sha256sum "$GOOD_DEB" | cut -d' ' -f1)
echo "[test_apt_nsrun]   pool: $GOOD_REL ($GOOD_SIZE bytes) sha=$GOOD_SHA"

if command -v ar >/dev/null 2>&1 && ! ar t "$GOOD_DEB" | grep -F -q 'data.tar.xz'; then
    echo "[test_apt_nsrun] FAIL: fixture has no data.tar.xz —" \
         "not exercising the xz install path"
    rm -rf "$REPO_DIR"
    exit 1
fi

echo "[test_apt_nsrun] (2/7) Fabricate the fake Debian repo index"

# dists/stable/Release — one RFC822 stanza.
cat > "$DIST_DIR/Release" <<EOF
Origin: Hamnix
Label: Hamnix
Suite: stable
Codename: stable
Architectures: amd64
Components: main
Description: Hamnix apt-under-nsrun test repository
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
Description: Debian hello served as an apt-under-nsrun fixture
EOF
gzip -9 -c "$PACKAGES_PLAIN" > "$BIN_DIR/Packages.gz"
echo "[test_apt_nsrun]   Packages.gz: $(stat -c%s "$BIN_DIR/Packages.gz") bytes"

echo "[test_apt_nsrun] (3/7) Build userland (hamsh + apt + dpkg + distrofs + nsrun)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
for b in apt dpkg distrofs nsrun; do
    if [ ! -x "build/user/${b}.elf" ]; then
        echo "[test_apt_nsrun] FAIL: build/user/${b}.elf missing after build"
        rm -rf "$REPO_DIR"
        exit 1
    fi
done

echo "[test_apt_nsrun] (4/7) Build tests/test_apt_install.ad -> $TEST_ELF"
mkdir -p build/user
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_apt_install.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_apt_nsrun] (5/7) Plant /init = hamsh in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_apt_nsrun] (6/7) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_apt_nsrun] (7/7) Start host http.server + boot QEMU"
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_apt_nsrun]   using host port $PORT"

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
# Prompt-synced feed: wait for hamsh's stable readiness marker in $LOG
# before sending the first command, instead of a blind fixed sleep. The
# 16550 RX FIFO has no software buffer — a byte sent before hamsh has a
# live SYS_READ on stdin is dropped, which is exactly how the old
# fixed-`sleep` feed desynced against the rewritten shell.
(
    waited=0
    while [ "$waited" -lt 120 ]; do
        if [ -f "$LOG" ] && grep -F -q "[hamsh] M16.35 shell ready" "$LOG"; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    # A short settle so the prompt is printed and stdin is being read.
    sleep 2
    printf '/bin/apt update http://10.0.2.2:%s stable\n' "$PORT"
    sleep 20
    printf 'echo APT_NSRUN_INSTALL_START\n'
    printf '/bin/nsrun /bin/test_apt_install\n'
    # apt install drives a real .deb download + SHA-256 verify, then a
    # dpkg unpack that lands ~140 entries over 9P (each Tcreate/Twrite a
    # synchronous round trip); give it a generous window before exit.
    sleep 60
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

echo "[test_apt_nsrun] --- captured output ---"
cat "$LOG"
echo "[test_apt_nsrun] --- end output ---"

fail=0
check_marker() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_apt_nsrun] OK: $2"
    else
        echo "[test_apt_nsrun] MISS: $2 ($1)"
        fail=1
    fi
}

# Any fixture FAIL line means a check broke.
if grep -F -q "[apt_install] FAIL:" "$LOG"; then
    echo "[test_apt_nsrun] MISS: fixture FAIL line(s) present:"
    grep -F "[apt_install] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
fi

# apt update fetched + parsed the index.
check_marker "apt-get: fetched index, 1 packages" "apt update fetched the index"
# nsrun set up the distrofs namespace.
check_marker "[nsrun] distrofs mounted at /usr" "nsrun mounted distrofs at /usr"
check_marker "[nsrun] exec target in namespace" "nsrun exec'd the fixture"
# The fixture ran and drove apt install.
check_marker "[apt_install] start" "fixture ran"
check_marker "[apt_install] apt spawned" "fixture spawned apt install"
# apt downloaded + SHA-256-verified the real .deb.
check_marker "apt: fetching $GOOD_REL" "apt downloaded the real .deb"
check_marker "apt: SHA256 OK (" "apt SHA-256-verified the .deb"
# apt detected it is inside a distro namespace -> spawned dpkg directly
# (NOT a nested nsrun). The "running dpkg under nsrun" line MUST be
# ABSENT here: apt is already under nsrun.
if grep -F -q "apt: running dpkg under nsrun" "$LOG"; then
    echo "[test_apt_nsrun] MISS: apt nested a second nsrun (should spawn dpkg directly here)"
    fail=1
else
    echo "[test_apt_nsrun] OK: apt detected the distro namespace, spawned dpkg directly"
fi
# dpkg registered AND unpacked the package.
check_marker "dpkg: registered $PKG_NAME $PKG_VERSION (" "dpkg recorded the package"
if grep -E -q 'dpkg: unpacked [1-9][0-9]* files to the distro namespace' "$LOG"; then
    echo "[test_apt_nsrun] OK: dpkg unpacked files to the distro namespace"
else
    echo "[test_apt_nsrun] MISS: dpkg did not report unpacking files"
    fail=1
fi
check_marker "apt: installed $PKG_NAME $PKG_VERSION" "apt reported the install"
# THE MILESTONE: the installed binary is present + non-empty in the
# namespace, read back by a subsequent open(2) in the fixture.
if grep -E -q '\[apt_install\] bin present bytes=[1-9][0-9]*' "$LOG"; then
    echo "[test_apt_nsrun] OK: /usr/bin/hello landed and is readable"
else
    echo "[test_apt_nsrun] MISS: /usr/bin/hello not present in the namespace"
    fail=1
fi
# A deep nested file proves the mkdir -p directory chain worked.
if grep -E -q '\[apt_install\] doc present bytes=[1-9][0-9]*' "$LOG"; then
    echo "[test_apt_nsrun] OK: /usr/share/doc/hello/copyright landed (mkdir -p)"
else
    echo "[test_apt_nsrun] MISS: deep nested copyright file not present"
    fail=1
fi
check_marker "[apt_install] PASS" "fixture reached PASS"

# No decompression error and no CPU exception.
if grep -E -q "dpkg: (xz decompress failed|gzip inflate failed)" "$LOG"; then
    echo "[test_apt_nsrun] MISS: dpkg reported a decompression error"
    fail=1
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_apt_nsrun] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_apt_nsrun] FAIL (qemu rc=$rc)"
    echo "[test_apt_nsrun] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    echo "[test_apt_nsrun] --- http.server log ---"
    cat "$SRVLOG" || true
    exit 1
fi

echo "[test_apt_nsrun] PASS — apt install of a REAL Debian package," \
     "run under nsrun, downloaded + SHA-256-verified the .deb and" \
     "landed its files into the distrofs namespace; the installed" \
     "binary and a deep nested doc file are present and readable there"
