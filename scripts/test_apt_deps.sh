#!/usr/bin/env bash
# scripts/test_apt_deps.sh — apt dependency-resolution regression:
# `apt install <pkg>` resolves the package's transitive `Depends:` and
# installs the whole closure in dependency order (deps before
# dependents).
#
# Companion to scripts/test_apt_install.sh — same fake-repo + host
# http.server + SLIRP-alias-10.0.2.2 shape — extended with a three-
# package dependency CHAIN and a deliberately-broken package:
#
#   app      Depends: libmid          (the named install root)
#   libmid   Depends: libbase
#   libbase  (no Depends)
#   brokenpkg Depends: noexist        (noexist is NOT in the index)
#
# The test boots Hamnix and drives:
#
#   apt update              -> fetch + decompress the Packages index
#   apt install app         -> on a clean dpkg DB: must resolve libmid
#                              + libbase, print the plan, and install
#                              libbase -> libmid -> app in that order
#   apt install libmid      -> libmid (and its dep libbase) are now
#                              already installed: must SKIP both and
#                              install nothing
#   apt install brokenpkg   -> must ABORT cleanly (missing dependency
#                              'noexist'), installing nothing
#
# Asserts via dpkg -l that all of libbase/libmid/app registered, and
# greps the serial log to confirm the install order libbase < libmid
# < app, the already-installed skip lines, and the missing-dep abort.
#
# NETWORKING NOTE — the QEMU `-netdev user,...guestfwd=tcp:10.0.2.100:
# 7-cmd:cat` is REQUIRED even though this test never uses that echo
# target: init/main.ad's net_smoke_test() runs unconditionally during
# boot and a tcp_connect to an unreachable host would spin forever.
# Same shape as scripts/test_apt_install.sh / test_apt_get.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

# --- fixture package identities --------------------------------------
# A three-package dependency chain. Names <=16 chars so dpkg's
# flattened .list path is exact (see test_dpkg_db.sh's DB-PATH note).
PKG_BASE='libbase'
VER_BASE='1.0.0'
PKG_MID='libmid'
VER_MID='2.1.0'
PKG_APP='app'
VER_APP='3.3.3'
# A package whose Depends names a package absent from the index.
PKG_BROKEN='brokenpkg'
VER_BROKEN='0.0.1'
DEP_MISSING='noexist'

ARCH='amd64'
MAINT='Hamnix Tests <noreply@hamnix.local>'

# --- pick a free host port -------------------------------------------
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_apt_deps] using host port $PORT"

echo "[test_apt_deps] (1/6) Build userland (hamsh + apt + dpkg + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

for b in apt dpkg; do
    if [ ! -x "build/user/${b}.elf" ]; then
        echo "[test_apt_deps] FAIL: build/user/${b}.elf missing after build"
        exit 1
    fi
done

echo "[test_apt_deps] (2/6) Fabricate fake Debian repo tree + .debs"
REPO_DIR=$(mktemp -d --tmpdir hamnix-apt-deps-repo.XXXXXX)
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
Description: Hamnix apt dependency-resolution test repository
EOF

# build_deb <pkg> <ver> <desc> <out.deb> — fabricate a tiny installable
# .deb via host ar+tar+gzip (same shape as test_apt_install.sh).
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
 Continuation line for the dependency fixture.
CTL
    tar -C "$d/ctl" -czf "$d/control.tar.gz" ./control

    mkdir -p "$d/data/usr/bin"
    printf '%s binary payload\n' "$pkg" > "$d/data/usr/bin/${pkg}"
    tar -C "$d/data" -czf "$d/data.tar.gz" ./usr/bin/${pkg}

    ( cd "$d" && ar rc "$out" debian-binary control.tar.gz data.tar.gz )
    rm -rf "$d"
}

# fabricate <pkg> <ver> — build the .deb under the pool tree and echo
# "<rel-path>|<size>|<sha256>" for the Packages stanza.
fabricate() {
    local pkg="$1" ver="$2"
    local first="${pkg:0:1}"
    local rel="pool/main/${first}/${pkg}/${pkg}_${ver}_${ARCH}.deb"
    local deb="$REPO_DIR/$rel"
    mkdir -p "$(dirname "$deb")"
    build_deb "$pkg" "$ver" "${pkg} dependency-chain fixture" "$deb"
    local size sha
    size=$(stat -c%s "$deb")
    sha=$(sha256sum "$deb" | cut -d' ' -f1)
    echo "${rel}|${size}|${sha}"
}

IFS='|' read -r BASE_REL BASE_SIZE BASE_SHA <<<"$(fabricate "$PKG_BASE" "$VER_BASE")"
IFS='|' read -r MID_REL  MID_SIZE  MID_SHA  <<<"$(fabricate "$PKG_MID"  "$VER_MID")"
IFS='|' read -r APP_REL  APP_SIZE  APP_SHA  <<<"$(fabricate "$PKG_APP"  "$VER_APP")"
IFS='|' read -r BRK_REL  BRK_SIZE  BRK_SHA  <<<"$(fabricate "$PKG_BROKEN" "$VER_BROKEN")"

echo "[test_apt_deps]   $PKG_BASE  : $BASE_REL ($BASE_SIZE bytes)"
echo "[test_apt_deps]   $PKG_MID   : $MID_REL ($MID_SIZE bytes)  Depends: $PKG_BASE"
echo "[test_apt_deps]   $PKG_APP   : $APP_REL ($APP_SIZE bytes)  Depends: $PKG_MID"
echo "[test_apt_deps]   $PKG_BROKEN: $BRK_REL ($BRK_SIZE bytes)  Depends: $DEP_MISSING (missing)"

# A hand-written Packages file: four stanzas. `app` Depends on `libmid`
# with a (parsed-past, V1-ignored) version constraint to exercise the
# constraint-stripping parser; `libmid` Depends on `libbase`.
PACKAGES_PLAIN="$REPO_DIR/Packages.plain"
cat > "$PACKAGES_PLAIN" <<EOF
Package: $PKG_BASE
Version: $VER_BASE
Architecture: $ARCH
Filename: $BASE_REL
Size: $BASE_SIZE
SHA256: $BASE_SHA
Description: APTDEPS base library (leaf of the dependency chain)

Package: $PKG_MID
Version: $VER_MID
Architecture: $ARCH
Filename: $MID_REL
Size: $MID_SIZE
SHA256: $MID_SHA
Depends: $PKG_BASE (>= 1.0.0)
Description: APTDEPS middle library, depends on $PKG_BASE

Package: $PKG_APP
Version: $VER_APP
Architecture: $ARCH
Filename: $APP_REL
Size: $APP_SIZE
SHA256: $APP_SHA
Depends: $PKG_MID (>= 2.0.0), $PKG_MID | libcfake
Description: APTDEPS top-level app, depends on $PKG_MID

Package: $PKG_BROKEN
Version: $VER_BROKEN
Architecture: $ARCH
Filename: $BRK_REL
Size: $BRK_SIZE
SHA256: $BRK_SHA
Depends: $DEP_MISSING
Description: APTDEPS package with a dependency absent from the index
EOF

gzip -9 -c "$PACKAGES_PLAIN" > "$BIN_DIR/Packages.gz"
echo "[test_apt_deps]   Packages.gz: $(stat -c%s "$BIN_DIR/Packages.gz") bytes"

echo "[test_apt_deps] (3/6) Swap /init = hamsh in cpio initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_apt_deps] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_apt_deps] (5/6) Start host http.server + boot QEMU"
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
    printf 'echo APT_APP_START\n'
    printf '/bin/apt install %s\n' "$PKG_APP"
    sleep 40
    printf 'echo APT_SKIP_START\n'
    printf '/bin/apt install %s\n' "$PKG_MID"
    sleep 15
    printf 'echo APT_DPKG_L_START\n'
    printf '/bin/dpkg -l\n'
    sleep 8
    printf 'echo APT_BROKEN_START\n'
    printf '/bin/apt install %s\n' "$PKG_BROKEN"
    sleep 20
    printf 'echo APT_BROKEN_DPKG_S_START\n'
    printf '/bin/dpkg -s %s\n' "$PKG_BROKEN"
    sleep 8
    printf 'exit\n'
    sleep 3
) | timeout 900s qemu-system-x86_64 \
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

echo "[test_apt_deps] --- captured (apt / dpkg / APT_) ---"
grep -E 'apt:|apt-get:|dpkg:|dpkg-query:|APT_|Package:|Status:|^ii ' "$LOG" || true
echo "[test_apt_deps] --- end ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_apt_deps] OK: '$1'"
    else
        echo "[test_apt_deps] MISS: '$1'"
        fail=1
    fi
}

# (a) `apt update` fetched the index (4 stanzas).
check "apt-get: fetched index, 4 packages"

# (b) `apt install app` on a clean DB printed the full dependency plan
#     naming all three packages in dependency order.
check "apt: installing $PKG_APP and 2 dependencies: $PKG_BASE, $PKG_MID, $PKG_APP"

# (c) the dependency install ORDER: within the `apt install app` run,
#     the per-package "apt: installed <pkg> <version>" lines must be in
#     dependency order libbase -> libmid -> app. The version starts
#     with a digit — this excludes the "apt: installed app (+N deps)"
#     summary line.
APP_WINDOW=$(sed -n '/APT_APP_START/,/APT_SKIP_START/p' "$LOG")
ORDER=$(echo "$APP_WINDOW" \
        | grep -E "apt: installed ($PKG_BASE|$PKG_MID|$PKG_APP) [0-9]" \
        | sed -E "s/.*apt: installed ($PKG_BASE|$PKG_MID|$PKG_APP) [0-9].*/\1/")
EXPECT_ORDER=$(printf '%s\n%s\n%s\n' "$PKG_BASE" "$PKG_MID" "$PKG_APP")
if [ "$ORDER" = "$EXPECT_ORDER" ]; then
    echo "[test_apt_deps] OK: install order $PKG_BASE -> $PKG_MID -> $PKG_APP"
else
    echo "[test_apt_deps] MISS: bad install order (got: $(echo $ORDER))"
    fail=1
fi

# (d) the final summary line of the `apt install app` run.
check "apt: installed $PKG_APP (+2 deps)"

# (e) the already-installed skip path: re-running `apt install libmid`
#     when libmid (and its dep libbase) are already in the dpkg DB must
#     print the skip line and download nothing.
SKIP_WINDOW=$(sed -n '/APT_SKIP_START/,/APT_DPKG_L_START/p' "$LOG")
if echo "$SKIP_WINDOW" | grep -F -q "apt: $PKG_MID already installed, skipping"; then
    echo "[test_apt_deps] OK: $PKG_MID skipped on re-install (already installed)"
else
    echo "[test_apt_deps] MISS: $PKG_MID not skipped on re-install"
    fail=1
fi
if echo "$SKIP_WINDOW" | grep -F -q "apt: fetching"; then
    echo "[test_apt_deps] MISS: skip run still downloaded a .deb"
    fail=1
else
    echo "[test_apt_deps] OK: skip run downloaded nothing"
fi

# (f) dpkg -l lists all three packages with the ii prefix.
L_WINDOW=$(sed -n '/APT_DPKG_L_START/,/APT_BROKEN_START/p' "$LOG")
for p in "$PKG_BASE" "$PKG_MID" "$PKG_APP"; do
    if echo "$L_WINDOW" | grep -E -q "(^|\] )ii  +$p "; then
        echo "[test_apt_deps] OK: dpkg -l lists $p"
    else
        echo "[test_apt_deps] MISS: dpkg -l did not list $p"
        fail=1
    fi
done

# (g) the missing-dependency abort: `apt install brokenpkg` must report
#     the missing dependency and abort.
check "apt: dependency '$DEP_MISSING' of '$PKG_BROKEN' not found in index"
check "apt: aborting"

# (h) brokenpkg must NOT have reached the dpkg DB (no partial install).
if grep -F -q "dpkg-query: package '$PKG_BROKEN' is not installed" "$LOG"; then
    echo "[test_apt_deps] OK: $PKG_BROKEN never registered (clean abort)"
else
    echo "[test_apt_deps] MISS: $PKG_BROKEN leaked into the dpkg DB"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_apt_deps] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_apt_deps] FAIL (qemu rc=$rc)"
    echo "[test_apt_deps] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    echo "[test_apt_deps] --- http.server log ---"
    cat "$SRVLOG" || true
    exit 1
fi

echo "[test_apt_deps] PASS — apt install resolved a transitive Depends:" \
     "chain, installed it in dependency order, skipped an" \
     "already-installed dep, and cleanly aborted on a missing dependency"
