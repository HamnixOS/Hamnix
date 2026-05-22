#!/usr/bin/env bash
# scripts/test_dpkg_real_deb.sh — apt-path end-to-end regression:
# `dpkg -i` of a REAL Debian package.
#
# This is the goal-3 milestone proof: every prior dpkg test fabricated
# its `.deb` on the host with `ar + tar + gzip`, so it only ever
# exercised the gzip codepath. A genuine modern Debian `.deb` is an
# `ar` archive whose control.tar / data.tar members are xz-compressed
# (LZMA2). This test bakes a real Debian `hello` package — fetched
# once from deb.debian.org and cached at build/cache/ — into the cpio
# initramfs and drives:
#
#     /bin/dpkg -i /tests/sample.deb     install the real package
#     /bin/dpkg -s hello                 read its status stanza back
#     /bin/dpkg -L hello                 list its installed files
#
# It proves dpkg.ad's V3 xz path: the `ar` walk locates
# `control.tar.xz` + `data.tar.xz`, lib/xz/xz.ad single-shot
# decompresses each (control.tar.xz -> ~10 KiB, data.tar.xz ->
# ~256 KiB, both inside dpkg's 512 KiB tar_buf), the ustar walker
# parses the real GNU/ustar tar, the control RFC822 fields are
# recorded in the status DB, and the data.tar manifest is written to
# the per-package .list.
#
# OFFLINE BEHAVIOUR: if the package cannot be fetched and is not
# cached, scripts/fetch_real_deb.py exits with a "SKIP" message and
# this test SKIPs (exit 0) rather than FAILing — an offline CI box
# does not spuriously fail. Once build/cache/hello_*.deb exists every
# subsequent run is fully offline + deterministic.
#
# Shape mirrors scripts/test_dpkg_db.sh — build user + modules +
# kernel, plant the fixture .deb in the cpio initramfs, boot, grep the
# serial log — but the fixture is a real Debian package, not a host
# fabrication.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# The real Debian package under test. `hello` is Debian's canonical
# tiny package; pinned to 2.10-5 so the fixture is stable. Its name is
# 5 chars, well inside dpkg's 16-char flattened-.list-name budget, so
# /tmp/dpkg.hello.list is exact (not truncated).
PKG_NAME='hello'
PKG_VERSION='2.10-5'
DEB_URL='http://deb.debian.org/debian/pool/main/h/hello/hello_2.10-5_amd64.deb'
DEB_SHA='4536aabbb75ec21ffe161099ee4b97274945770bdb0682e25ec322421211ca5e'
LIST_PATH="/tmp/dpkg.${PKG_NAME}.list"
# A file the real `hello` data.tar carries — used to prove `dpkg -L`
# read the genuine xz-decompressed data.tar manifest.
DATA_ENTRY='./usr/bin/hello'

echo "[test_dpkg_real_deb] (1/6) Fetch the real Debian $PKG_NAME .deb"
FIXTURE_DIR=$(mktemp -d --tmpdir hamnix-realdeb.XXXXXX)
cleanup_fixture() { rm -rf "$FIXTURE_DIR"; }
DEB_PATH="$FIXTURE_DIR/sample.deb"

# fetch_real_deb.py SKIPs (exit non-zero, prints "SKIP") when the
# package is neither reachable nor cached. Catch that and treat it as
# a test SKIP, not a FAIL.
set +e
FETCH_OUT=$(python3 scripts/fetch_real_deb.py "$DEB_PATH" \
    --url "$DEB_URL" --sha256 "$DEB_SHA" 2>&1)
FETCH_RC=$?
set -e
echo "$FETCH_OUT"
if [ "$FETCH_RC" -ne 0 ]; then
    if echo "$FETCH_OUT" | grep -F -q "SKIP"; then
        echo "[test_dpkg_real_deb] SKIP — real $PKG_NAME .deb unavailable" \
             "(offline and uncached)"
        cleanup_fixture
        exit 0
    fi
    echo "[test_dpkg_real_deb] FAIL: could not obtain the fixture .deb"
    cleanup_fixture
    exit 1
fi
echo "[test_dpkg_real_deb]   fixture: $DEB_PATH" \
     "($(stat -c%s "$DEB_PATH") bytes)"

# Sanity-check on the host that this really is an xz-membered .deb —
# if it weren't, the test would not be exercising the new codepath.
if command -v ar >/dev/null 2>&1; then
    if ar t "$DEB_PATH" | grep -F -q 'data.tar.xz'; then
        echo "[test_dpkg_real_deb]   confirmed: data.tar.xz member present"
    else
        echo "[test_dpkg_real_deb] FAIL: fixture has no data.tar.xz —" \
             "not exercising the xz path"
        cleanup_fixture
        exit 1
    fi
fi

echo "[test_dpkg_real_deb] (2/6) Build userland (hamsh + dpkg + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

if [ ! -x "build/user/dpkg.elf" ]; then
    echo "[test_dpkg_real_deb] FAIL: build/user/dpkg.elf missing after build"
    cleanup_fixture
    exit 1
fi

echo "[test_dpkg_real_deb] (3/6) Plant /init = hamsh + /tests/sample.deb in cpio"
INIT_ELF="$HAMSH_ELF" HAMNIX_DEB_FIXTURE="$DEB_PATH" \
    python3 scripts/build_initramfs.py >/dev/null

# Restore the canonical initramfs on exit so other tests in this
# worktree see a clean state.
trap 'cleanup_fixture; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_dpkg_real_deb] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_dpkg_real_deb] (5/6) Boot QEMU + drive /bin/dpkg via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; cleanup_fixture; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'echo DPKG_REAL_INSTALL_START\n'
    printf '/bin/dpkg -i /tests/sample.deb\n'
    sleep 4
    printf 'echo DPKG_REAL_S_START\n'
    printf '/bin/dpkg -s %s\n' "$PKG_NAME"
    sleep 3
    printf 'echo DPKG_REAL_L_START\n'
    printf '/bin/dpkg -L %s\n' "$PKG_NAME"
    sleep 3
    printf 'echo DPKG_REAL_LIST_START\n'
    printf '/bin/dpkg -l\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 90s qemu-system-x86_64 \
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

echo "[test_dpkg_real_deb] --- captured output ---"
cat "$LOG"
echo "[test_dpkg_real_deb] --- end output ---"

fail=0

# (a) dpkg -i printed its success summary for the real package. The
#     entry count is whatever the genuine data.tar carries — assert the
#     prefix + version rather than a brittle exact number.
if grep -F -q "dpkg: registered $PKG_NAME $PKG_VERSION (" "$LOG"; then
    echo "[test_dpkg_real_deb] OK: dpkg -i registered the real package"
else
    echo "[test_dpkg_real_deb] MISS: 'dpkg: registered $PKG_NAME" \
         "$PKG_VERSION (...)' absent — xz install path did not complete"
    fail=1
fi

# (b) dpkg -s reads the recorded status stanza back. The Status line is
#     written only by dpkg's install path, so finding it after an
#     `echo DPKG_REAL_S_START` boundary is a genuine DB read-back.
S_WINDOW=$(sed -n '/DPKG_REAL_S_START/,/DPKG_REAL_L_START/p' "$LOG")
if echo "$S_WINDOW" | grep -F -q "Package: $PKG_NAME" \
   && echo "$S_WINDOW" | grep -F -q "Status: install ok installed" \
   && echo "$S_WINDOW" | grep -F -q "Version: $PKG_VERSION"; then
    echo "[test_dpkg_real_deb] OK: dpkg -s shows the real package's stanza"
else
    echo "[test_dpkg_real_deb] MISS: dpkg -s did not show the recorded stanza"
    fail=1
fi

# (c) dpkg -L lists the per-package .list — proving the xz-decompressed
#     data.tar manifest was parsed + recorded. The real `hello` package
#     carries /usr/bin/hello.
L_WINDOW=$(sed -n '/DPKG_REAL_L_START/,/DPKG_REAL_LIST_START/p' "$LOG")
if echo "$L_WINDOW" | grep -F -q "$DATA_ENTRY"; then
    echo "[test_dpkg_real_deb] OK: dpkg -L lists $DATA_ENTRY from data.tar.xz"
else
    echo "[test_dpkg_real_deb] MISS: dpkg -L did not list $DATA_ENTRY"
    fail=1
fi

# (d) dpkg -l shows the package with the ii prefix.
if grep -E -q "(^|\] )ii  +$PKG_NAME " "$LOG"; then
    echo "[test_dpkg_real_deb] OK: dpkg -l lists $PKG_NAME"
else
    echo "[test_dpkg_real_deb] MISS: dpkg -l did not list $PKG_NAME"
    fail=1
fi

# (e) no decompression error leaked to the log — a regression in the
#     xz path would surface as one of these dpkg diagnostics.
if grep -E -q "dpkg: (xz decompress failed|unsupported compression|gzip inflate failed)" "$LOG"; then
    echo "[test_dpkg_real_deb] MISS: dpkg reported a decompression error"
    grep -E "dpkg: (xz decompress failed|unsupported compression|gzip inflate failed)" "$LOG" | head -3
    fail=1
else
    echo "[test_dpkg_real_deb] OK: no decompression error in the log"
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_dpkg_real_deb] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_dpkg_real_deb] FAIL (qemu rc=$rc)"
    echo "[test_dpkg_real_deb] --- full kernel log (last 120 lines) ---"
    tail -n 120 "$LOG"
    exit 1
fi

echo "[test_dpkg_real_deb] PASS — dpkg -i installed a REAL Debian package" \
     "(ar + xz-compressed control.tar/data.tar), recorded it, and the" \
     "query sub-commands read it back"
