#!/usr/bin/env bash
# scripts/test_dpkg_install.sh — the "real install" milestone proof:
# `dpkg -i` of a genuine Debian package ACTUALLY LANDS the package's
# files into the distrofs-served distro namespace, so the installed
# program is present and usable.
#
# Where scripts/test_dpkg_real_deb.sh proved dpkg -i records the
# metadata (status stanza + .list manifest), this test proves the
# remaining gap: the binary, docs and locale files are extracted to
# their nested absolute paths and a SUBSEQUENT command in the same
# namespace can open them.
#
# Pipeline:
#   1. Fetch the real Debian `hello` .deb (cached at build/cache/).
#   2. Build userland (hamsh + dpkg + distrofs + nsrun + the fixture).
#   3. Plant /init = hamsh + /tests/sample.deb in the cpio.
#   4. Rebuild the kernel.
#   5. Boot QEMU and run, from hamsh:
#        /bin/nsrun /bin/test_dpkg_install
#      nsrun spawns three distrofs daemons, mounts them at /var, /usr,
#      /etc, then exec's the fixture. The fixture spawns `dpkg -i
#      /tests/sample.deb` (which extracts data.tar to /usr/...), waits,
#      then opens /usr/bin/hello AND /usr/share/doc/hello/copyright IN
#      THE SAME namespace and asserts both are present.
#   6. Grep the serial log for the markers.
#
# OFFLINE BEHAVIOUR: if the real .deb cannot be fetched and is not
# cached, scripts/fetch_real_deb.py emits "SKIP" and this test SKIPs.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_dpkg_install.elf

PKG_NAME='hello'
PKG_VERSION='2.10-5'
DEB_URL='http://deb.debian.org/debian/pool/main/h/hello/hello_2.10-5_amd64.deb'
DEB_SHA='4536aabbb75ec21ffe161099ee4b97274945770bdb0682e25ec322421211ca5e'

echo "[test_dpkg_install] (1/6) Fetch the real Debian $PKG_NAME .deb"
FIXTURE_DIR=$(mktemp -d --tmpdir hamnix-dpkginstall.XXXXXX)
cleanup_fixture() { rm -rf "$FIXTURE_DIR"; }
DEB_PATH="$FIXTURE_DIR/sample.deb"

set +e
FETCH_OUT=$(python3 scripts/fetch_real_deb.py "$DEB_PATH" \
    --url "$DEB_URL" --sha256 "$DEB_SHA" 2>&1)
FETCH_RC=$?
set -e
echo "$FETCH_OUT"
if [ "$FETCH_RC" -ne 0 ]; then
    if echo "$FETCH_OUT" | grep -F -q "SKIP"; then
        echo "[test_dpkg_install] SKIP — real $PKG_NAME .deb unavailable" \
             "(offline and uncached)"
        cleanup_fixture
        exit 0
    fi
    echo "[test_dpkg_install] FAIL: could not obtain the fixture .deb"
    cleanup_fixture
    exit 1
fi
echo "[test_dpkg_install]   fixture: $DEB_PATH ($(stat -c%s "$DEB_PATH") bytes)"

echo "[test_dpkg_install] (2/6) Build userland (hamsh + dpkg + distrofs + nsrun)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

for b in dpkg distrofs nsrun; do
    if [ ! -x "build/user/${b}.elf" ]; then
        echo "[test_dpkg_install] FAIL: build/user/${b}.elf missing after build"
        cleanup_fixture
        exit 1
    fi
done

echo "[test_dpkg_install] (3/6) Build tests/test_dpkg_install.ad -> $TEST_ELF"
mkdir -p build/user
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_dpkg_install.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_dpkg_install] (4/6) Plant /init = hamsh + /tests/sample.deb in cpio"
INIT_ELF="$HAMSH_ELF" HAMNIX_DEB_FIXTURE="$DEB_PATH" \
    python3 scripts/build_initramfs.py >/dev/null

trap 'cleanup_fixture; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_dpkg_install] (5/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_dpkg_install] (6/6) Boot QEMU + run nsrun /bin/test_dpkg_install"
LOG=$(mktemp)
trap 'rm -f "$LOG"; cleanup_fixture; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'echo DPKG_INSTALL_START\n'
    printf '/bin/nsrun /bin/test_dpkg_install\n'
    # The install lands ~140 entries over 9P (each Tcreate / Twrite is
    # a synchronous round trip), so give it a generous window before
    # sending `exit`.
    sleep 45
    printf 'exit\n'
    sleep 2
) | timeout 200s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_dpkg_install] --- captured output ---"
cat "$LOG"
echo "[test_dpkg_install] --- end output ---"

fail=0
check_marker() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_dpkg_install] OK: $2"
    else
        echo "[test_dpkg_install] MISS: $2 ($1)"
        fail=1
    fi
}

# Any fixture FAIL line means a check broke.
if grep -F -q "[dpkg_install] FAIL:" "$LOG"; then
    echo "[test_dpkg_install] MISS: fixture FAIL line(s) present:"
    grep -F "[dpkg_install] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
fi

# nsrun set up the distrofs namespace.
check_marker "[nsrun] distrofs mounted at /usr" "nsrun mounted distrofs at /usr"
check_marker "[nsrun] exec target in namespace" "nsrun exec'd the fixture"
# The fixture ran and drove dpkg.
check_marker "[dpkg_install] start" "fixture ran"
check_marker "[dpkg_install] dpkg spawned" "fixture spawned dpkg"
# dpkg -i registered AND unpacked the package.
check_marker "dpkg: registered $PKG_NAME $PKG_VERSION (" "dpkg recorded the package"
if grep -E -q 'dpkg: unpacked [1-9][0-9]* files to the distro namespace' "$LOG"; then
    echo "[test_dpkg_install] OK: dpkg unpacked files to the distro namespace"
else
    echo "[test_dpkg_install] MISS: dpkg did not report unpacking files"
    fail=1
fi
# THE MILESTONE: the installed binary is present + non-empty in the
# namespace, read back by a subsequent open(2).
if grep -E -q '\[dpkg_install\] bin present bytes=[1-9][0-9]*' "$LOG"; then
    echo "[test_dpkg_install] OK: /usr/bin/hello landed and is readable"
else
    echo "[test_dpkg_install] MISS: /usr/bin/hello not present in the namespace"
    fail=1
fi
# A deep nested file proves the mkdir -p directory chain worked.
if grep -E -q '\[dpkg_install\] doc present bytes=[1-9][0-9]*' "$LOG"; then
    echo "[test_dpkg_install] OK: /usr/share/doc/hello/copyright landed (mkdir -p)"
else
    echo "[test_dpkg_install] MISS: deep nested copyright file not present"
    fail=1
fi
check_marker "[dpkg_install] PASS" "fixture reached PASS"

# No decompression error and no CPU exception.
if grep -E -q "dpkg: (xz decompress failed|gzip inflate failed)" "$LOG"; then
    echo "[test_dpkg_install] MISS: dpkg reported a decompression error"
    fail=1
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_dpkg_install] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_dpkg_install] FAIL (qemu rc=$rc)"
    echo "[test_dpkg_install] --- full kernel log (last 160 lines) ---"
    tail -n 160 "$LOG"
    exit 1
fi

echo "[test_dpkg_install] PASS — dpkg -i of a REAL Debian package landed" \
     "its files into the distrofs namespace; the installed binary and a" \
     "deep nested doc file are present and readable in that namespace"
