#!/usr/bin/env bash
# scripts/test_apt_install_large.sh — apt-path regression guard for the
# lifted cap pair (DEB_CAP + TMPFS_FILE_CAP).
#
# Where test_apt_real_deb.sh installs `hello` — a 52 KiB .deb whose
# largest extracted file is ~28 KiB — this test installs `libc-bin`,
# whose .deb is ~640 KiB (well above the old 256 KiB DEB_CAP) and
# whose `/usr/sbin/ldconfig` is ~990 KiB (well above the old 512 KiB
# TMPFS_FILE_CAP). Before the cap-lift change this test fails:
#   * apt would either truncate the .deb body (256 KiB short of the
#     real package) or hit "apt: .deb exceeds 256 KiB cap (V0 limit)";
#   * dpkg would silently short-write `/usr/sbin/ldconfig` after the
#     first 512 KiB, leaving an unusable binary on the distro tree.
# After the cap-lift it passes — the .deb streams through a chunked
# tmpfs file under /tmp/apt/, the SHA-256 verifies over the full body,
# and dpkg lands every byte of `/usr/sbin/ldconfig`.
#
# The fixture serves the REAL `libc-bin` .deb (cached via
# scripts/fetch_real_deb.py) from a hand-fabricated single-stanza
# Packages index. Importantly the fabricated stanza STRIPS the
# `Depends: libc6 (>> 2.41), libc6 (<< 2.42)` field so apt does NOT
# walk the dependency closure — installing real libc6 would pull in
# ~13 MiB of files and exceed both QEMU's RAM budget and the
# per-test boot time. This narrows the test to the cap-lift surface.
#
# NETWORKING NOTE — the QEMU guestfwd is REQUIRED even though this
# test never uses that echo target: init/main.ad's net_smoke_test()
# runs unconditionally during boot and a tcp_connect to an
# unreachable host would spin forever. Same shape as
# test_apt_real_deb.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# The real Debian package under test. `libc-bin` was chosen because
# its .deb (~640 KiB) AND one of its files (/usr/sbin/ldconfig at
# ~990 KiB) are BOTH past the pre-cap-lift limits.
PKG_NAME='libc-bin'
PKG_VERSION='2.41-12+deb13u3'
ARCH='amd64'
DEB_URL='http://deb.debian.org/debian/pool/main/g/glibc/libc-bin_2.41-12+deb13u3_amd64.deb'
DEB_SHA='0105bbe1f317d8992bd73217ea9f3dd63e7f1195841f6aca346c570566628fb8'
# A real extracted file that exceeds the pre-cap-lift 512 KiB tmpfs
# per-file size. `dpkg -L libc-bin` must list this and dpkg's "unpacked"
# step must succeed; pre-cap-lift it short-wrote silently after 512 KiB.
LARGE_FILE='/usr/sbin/ldconfig'

echo "[test_apt_install_large] (1/6) Fetch the real Debian $PKG_NAME .deb"
REPO_DIR=$(mktemp -d --tmpdir hamnix-apt-large.XXXXXX)
DIST_DIR="$REPO_DIR/dists/stable"
BIN_DIR="$DIST_DIR/main/binary-amd64"
mkdir -p "$BIN_DIR"

GOOD_REL="pool/main/g/glibc/${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"
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
        echo "[test_apt_install_large] SKIP — real $PKG_NAME .deb unavailable" \
             "(offline and uncached)"
        rm -rf "$REPO_DIR"
        exit 0
    fi
    echo "[test_apt_install_large] FAIL: could not obtain the fixture .deb"
    rm -rf "$REPO_DIR"
    exit 1
fi

GOOD_SIZE=$(stat -c%s "$GOOD_DEB")
GOOD_SHA=$(sha256sum "$GOOD_DEB" | cut -d' ' -f1)
echo "[test_apt_install_large]   pool: $GOOD_REL ($GOOD_SIZE bytes) sha=$GOOD_SHA"

# Sanity-check the cap-lift premise: the .deb really must be past
# the OLD 256 KiB DEB_CAP for this test to be a meaningful regression
# guard.
if [ "$GOOD_SIZE" -le 262144 ]; then
    echo "[test_apt_install_large] FAIL: fixture .deb is only $GOOD_SIZE bytes — " \
         "not large enough to exercise the lifted DEB_CAP."
    rm -rf "$REPO_DIR"
    exit 1
fi

echo "[test_apt_install_large] (2/6) Fabricate the fake Debian repo index"

cat > "$DIST_DIR/Release" <<EOF
Origin: Hamnix
Label: Hamnix
Suite: stable
Codename: stable
Architectures: amd64
Components: main
Description: Hamnix apt large-deb cap-lift fixture
EOF

# Strip Depends so apt does NOT try to resolve libc6. The point of
# the test is to drive the cap-lift codepath end-to-end, not to
# install all of glibc.
PACKAGES_PLAIN="$REPO_DIR/Packages.plain"
cat > "$PACKAGES_PLAIN" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION
Architecture: $ARCH
Filename: $GOOD_REL
Size: $GOOD_SIZE
SHA256: $GOOD_SHA
Description: Debian libc-bin served as apt large-cap regression fixture
EOF
gzip -9 -c "$PACKAGES_PLAIN" > "$BIN_DIR/Packages.gz"
echo "[test_apt_install_large]   Packages.gz: $(stat -c%s "$BIN_DIR/Packages.gz") bytes"

echo "[test_apt_install_large] (3/6) Build userland + swap /init = hamsh in cpio"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
for b in apt dpkg; do
    if [ ! -x "build/user/${b}.elf" ]; then
        echo "[test_apt_install_large] FAIL: build/user/${b}.elf missing after build"
        rm -rf "$REPO_DIR"
        exit 1
    fi
done
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_apt_install_large] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_apt_install_large] (5/6) Start host http.server + boot QEMU"
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_apt_install_large]   using host port $PORT"

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
    printf 'echo APT_LARGE_INSTALL_START\n'
    printf '/bin/apt install %s\n' "$PKG_NAME"
    sleep 60
    printf 'echo APT_LARGE_DPKG_S_START\n'
    printf '/bin/dpkg -s %s\n' "$PKG_NAME"
    sleep 5
    printf 'echo APT_LARGE_DPKG_L_START\n'
    printf '/bin/dpkg -L %s\n' "$PKG_NAME"
    sleep 5
    printf 'exit\n'
    sleep 2
) | timeout 360s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_apt_install_large] --- captured (apt / dpkg / APT_) ---"
grep -aE 'apt:|apt-get:|dpkg:|dpkg-query:|APT_LARGE|Package:|Status:' "$LOG" || true
echo "[test_apt_install_large] --- end ---"

fail=0
check() {
    if grep -aF -q "$1" "$LOG"; then
        echo "[test_apt_install_large] OK: '$1'"
    else
        echo "[test_apt_install_large] MISS: '$1'"
        fail=1
    fi
}

# (a) apt update fetched + parsed the index.
check "apt-get: fetched index, 1 packages"

# (b) apt install downloaded the real (large) .deb and verified its
#     SHA-256 against the index. The "SHA256 OK (NNNNNN bytes)" line
#     confirms the FULL .deb was streamed — pre-cap-lift the SHA-256
#     would either fail (wrong hash over a truncated body) or the
#     fetch would abort with "exceeds 256 KiB cap".
check "apt: fetching $GOOD_REL"
check "apt: SHA256 OK ($GOOD_SIZE bytes)"

# (c) dpkg installed the package (xz members decompressed past the old
#     512 KiB tmpfs cap, ~990 KiB ldconfig binary landed).
check "dpkg: registered $PKG_NAME $PKG_VERSION ("
check "apt: installed $PKG_NAME $PKG_VERSION"

# (d) dpkg -s read it back from the on-disk status DB.
S_WINDOW=$(sed -n '/APT_LARGE_DPKG_S_START/,/APT_LARGE_DPKG_L_START/p' "$LOG")
if echo "$S_WINDOW" | grep -aF -q "Package: $PKG_NAME" \
   && echo "$S_WINDOW" | grep -aF -q "Status: install ok installed"; then
    echo "[test_apt_install_large] OK: dpkg -s shows $PKG_NAME registered"
else
    echo "[test_apt_install_large] MISS: dpkg -s did not show $PKG_NAME"
    fail=1
fi

# (e) the large file made the package's .list manifest — proof dpkg
#     walked far enough into the data.tar to record it AND that the
#     manifest file (which grows past the 4 KiB pre-lift LIST_CAP for
#     a real-package manifest) was actually persisted past its old
#     cap.
if grep -aF -q "$LARGE_FILE" "$LOG"; then
    echo "[test_apt_install_large] OK: dpkg -L lists $LARGE_FILE"
else
    echo "[test_apt_install_large] MISS: dpkg -L did not list $LARGE_FILE"
    fail=1
fi

# (f) no short-write or tmpfs-out-of-space surfaced; these are the
#     telltales of the cap NOT being lifted.
if grep -aE "dpkg: short write|tmpfs: out of (file slots|entry slots)" "$LOG"; then
    echo "[test_apt_install_large] MISS: dpkg/tmpfs surfaced a short-write or out-of-space"
    fail=1
fi

if grep -aF -q "TRAP: vector" "$LOG"; then
    echo "[test_apt_install_large] DIAG: kernel reported a CPU exception"
    grep -aF "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_apt_install_large] FAIL (qemu rc=$rc)"
    echo "[test_apt_install_large] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    echo "[test_apt_install_large] --- http.server log ---"
    cat "$SRVLOG" || true
    exit 1
fi

echo "[test_apt_install_large] PASS — apt install handled a real .deb past" \
     "the old 256 KiB DEB_CAP and dpkg landed a file past the old 512 KiB" \
     "tmpfs cap (libc-bin, /usr/sbin/ldconfig ~990 KiB)"
