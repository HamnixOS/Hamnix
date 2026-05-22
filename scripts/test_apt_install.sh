#!/usr/bin/env bash
# scripts/test_apt_install.sh — apt-path end-to-end regression:
# `apt install <pkg>` downloads a package's .deb over HTTP, SHA-256-
# verifies it against the repo index, and installs it via `dpkg -i`.
#
# This chains every apt-path piece built so far:
#
#   apt update   -> fetch + decompress the Packages index, persist the
#                   base-url to /tmp/apt/base-url
#   apt install  -> look the package up in the index, HTTP GET its
#                   .deb, SHA-256-verify the bytes, spawn `dpkg -i`
#   dpkg -s      -> confirm the package registered in the dpkg DB
#
# Companion to scripts/test_apt_get.sh — same fake-repo + host
# http.server + SLIRP-alias-10.0.2.2 shape — extended with a real .deb
# in the repo pool tree, and a deliberately-corrupted second .deb so
# the SHA-256 rejection path is exercised too.
#
# NETWORKING NOTE — the QEMU `-netdev user,...guestfwd=tcp:10.0.2.100:
# 7-cmd:cat` is REQUIRED even though this test never uses that echo
# target: init/main.ad's net_smoke_test() runs unconditionally during
# boot and a tcp_connect to an unreachable host would spin forever.
# Same shape as scripts/test_apt_get.sh / test_u_socket.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# --- fixture package identities --------------------------------------
# A real, installable package — apt install fetches + verifies + dpkg's
# it. PKG_GOOD must be <=16 chars so dpkg's flattened .list path is
# exact (see test_dpkg_db.sh's DB-PATH note).
PKG_GOOD='hamtool'
VER_GOOD='1.4.2'
ARCH='amd64'
MAINT='Hamnix Tests <noreply@hamnix.local>'
DESC_GOOD='APTINST_OK end-to-end install fixture'
# A second package whose index SHA256 is WRONG — drives the rejection.
PKG_BAD='badpkg'
VER_BAD='9.9.9'

# --- pick a free host port -------------------------------------------
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_apt_install] using host port $PORT"

echo "[test_apt_install] (1/6) Build userland (hamsh + apt + dpkg + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

for b in apt dpkg; do
    if [ ! -x "build/user/${b}.elf" ]; then
        echo "[test_apt_install] FAIL: build/user/${b}.elf missing after build"
        exit 1
    fi
done

echo "[test_apt_install] (2/6) Fabricate fake Debian repo tree + .debs"
REPO_DIR=$(mktemp -d --tmpdir hamnix-apt-inst-repo.XXXXXX)
DIST_DIR="$REPO_DIR/dists/stable"
BIN_DIR="$DIST_DIR/main/binary-amd64"
mkdir -p "$BIN_DIR"

# dists/stable/Release — one RFC822 stanza.
cat > "$DIST_DIR/Release" <<EOF
Origin: Hamnix
Label: Hamnix
Suite: stable
Codename: stable
Architectures: amd64
Components: main
Description: Hamnix apt install test repository
EOF

# build_deb <pkg> <ver> <desc> <out.deb> — fabricate a tiny installable
# .deb via host ar+tar+gzip (same shape as test_dpkg_db.sh's fixture).
build_deb() {
    local pkg="$1" ver="$2" desc="$3" out="$4"
    local d
    d=$(mktemp -d --tmpdir hamnix-deb.XXXXXX)
    printf '2.0\n' > "$d/debian-binary"

    mkdir -p "$d/ctl"
    cat > "$d/ctl/control" <<CTL
Package: $pkg
Version: $ver
Section: misc
Priority: optional
Architecture: $ARCH
Maintainer: $MAINT
Description: $desc
 Continuation line for the install fixture.
CTL
    tar -C "$d/ctl" -czf "$d/control.tar.gz" ./control

    mkdir -p "$d/data/usr/bin"
    printf 'hamtool binary payload\n' > "$d/data/usr/bin/${pkg}"
    tar -C "$d/data" -czf "$d/data.tar.gz" ./usr/bin/${pkg}

    ( cd "$d" && ar rc "$out" debian-binary control.tar.gz data.tar.gz )
    rm -rf "$d"
}

# The good package — index will carry its correct SHA256 + Size.
GOOD_REL="pool/main/h/${PKG_GOOD}/${PKG_GOOD}_${VER_GOOD}_${ARCH}.deb"
GOOD_DEB="$REPO_DIR/$GOOD_REL"
mkdir -p "$(dirname "$GOOD_DEB")"
build_deb "$PKG_GOOD" "$VER_GOOD" "$DESC_GOOD" "$GOOD_DEB"
GOOD_SIZE=$(stat -c%s "$GOOD_DEB")
GOOD_SHA=$(sha256sum "$GOOD_DEB" | cut -d' ' -f1)

# The bad package — a real .deb is planted in the pool, but the index
# advertises a deliberately-wrong SHA256 so `apt install` must reject
# it before ever spawning dpkg.
BAD_REL="pool/main/b/${PKG_BAD}/${PKG_BAD}_${VER_BAD}_${ARCH}.deb"
BAD_DEB="$REPO_DIR/$BAD_REL"
mkdir -p "$(dirname "$BAD_DEB")"
build_deb "$PKG_BAD" "$VER_BAD" "badpkg corrupt-hash fixture" "$BAD_DEB"
BAD_SIZE=$(stat -c%s "$BAD_DEB")
# A SHA256 that is valid-shape (64 lowercase hex) but is NOT the file's.
BAD_SHA='deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'

echo "[test_apt_install]   good: $GOOD_REL ($GOOD_SIZE bytes) sha=$GOOD_SHA"
echo "[test_apt_install]   bad : $BAD_REL ($BAD_SIZE bytes, index sha intentionally wrong)"

# A hand-written Packages file: 2 stanzas referencing the .debs above
# by their real Filename/Size and (for the good one) real SHA256.
PACKAGES_PLAIN="$REPO_DIR/Packages.plain"
cat > "$PACKAGES_PLAIN" <<EOF
Package: $PKG_GOOD
Version: $VER_GOOD
Architecture: $ARCH
Filename: $GOOD_REL
Size: $GOOD_SIZE
SHA256: $GOOD_SHA
Description: $DESC_GOOD

Package: $PKG_BAD
Version: $VER_BAD
Architecture: $ARCH
Filename: $BAD_REL
Size: $BAD_SIZE
SHA256: $BAD_SHA
Description: badpkg with a deliberately wrong index SHA256
EOF

gzip -9 -c "$PACKAGES_PLAIN" > "$BIN_DIR/Packages.gz"
echo "[test_apt_install]   Packages.gz: $(stat -c%s "$BIN_DIR/Packages.gz") bytes"

echo "[test_apt_install] (3/6) Swap /init = hamsh in cpio initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_apt_install] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_apt_install] (5/6) Start host http.server + boot QEMU"
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
    printf 'echo APT_INSTALL_START\n'
    printf '/bin/apt install %s\n' "$PKG_GOOD"
    sleep 15
    printf 'echo APT_DPKG_S_START\n'
    printf '/bin/dpkg -s %s\n' "$PKG_GOOD"
    sleep 5
    printf 'echo APT_DPKG_L_START\n'
    printf '/bin/dpkg -l\n'
    sleep 5
    printf 'echo APT_BADINST_START\n'
    printf '/bin/apt install %s\n' "$PKG_BAD"
    sleep 15
    printf 'echo APT_BAD_DPKG_S_START\n'
    printf '/bin/dpkg -s %s\n' "$PKG_BAD"
    sleep 5
    printf 'exit\n'
    sleep 2
) | timeout 300s qemu-system-x86_64 \
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

echo "[test_apt_install] --- captured (apt / dpkg / APT_) ---"
grep -E 'apt:|apt-get:|dpkg:|dpkg-query:|APT_|Package:|Status:' "$LOG" || true
echo "[test_apt_install] --- end ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_apt_install] OK: '$1'"
    else
        echo "[test_apt_install] MISS: '$1'"
        fail=1
    fi
}

# (a) `apt update` fetched the index and persisted the base-url.
check "apt-get: fetched index, 2 packages"

# (b) `apt install hamtool` downloaded the .deb and SHA-256-verified it.
check "apt: fetching $GOOD_REL"
check "apt: SHA256 OK ("
check "apt: installed $PKG_GOOD $VER_GOOD"

# (c) dpkg actually registered the package — its status stanza, read
#     back via `dpkg -s` (the Status line is unique to the dpkg DB, so
#     this is a genuine read-back, not an echo).
S_WINDOW=$(sed -n '/APT_DPKG_S_START/,/APT_DPKG_L_START/p' "$LOG")
if echo "$S_WINDOW" | grep -F -q "Package: $PKG_GOOD" \
   && echo "$S_WINDOW" | grep -F -q "Status: install ok installed"; then
    echo "[test_apt_install] OK: dpkg -s shows $PKG_GOOD registered"
else
    echo "[test_apt_install] MISS: dpkg -s did not show $PKG_GOOD"
    fail=1
fi

# (d) `dpkg -l` lists the installed package with the ii prefix.
if grep -E -q "(^|\] )ii  +$PKG_GOOD " "$LOG"; then
    echo "[test_apt_install] OK: dpkg -l lists $PKG_GOOD"
else
    echo "[test_apt_install] MISS: dpkg -l did not list $PKG_GOOD"
    fail=1
fi

# (e) the SHA-256 rejection path: `apt install badpkg` must FAIL the
#     verification and refuse to install.
check "apt: SHA256 verification FAILED for $PKG_BAD"
check "apt: refusing to install a corrupt package"

# (f) and the corrupt package must NOT have reached the dpkg DB.
if grep -F -q "dpkg-query: package '$PKG_BAD' is not installed" "$LOG"; then
    echo "[test_apt_install] OK: corrupt $PKG_BAD never registered in dpkg DB"
else
    echo "[test_apt_install] MISS: corrupt $PKG_BAD leaked into the dpkg DB"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_apt_install] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_apt_install] FAIL (qemu rc=$rc)"
    echo "[test_apt_install] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    echo "[test_apt_install] --- http.server log ---"
    cat "$SRVLOG" || true
    exit 1
fi

echo "[test_apt_install] PASS — apt install downloaded a .deb over HTTP," \
     "SHA-256-verified it, dpkg-installed it, and rejected a corrupt .deb"
