#!/usr/bin/env bash
# scripts/test_apt_xz.sh — apt xz-index regression: fetch + xz-decompress
# + parse a Debian repository index whose binary-amd64 index is shipped
# as `Packages.xz` (LZMA2), not `Packages.gz`.
#
# This is the deterministic counterpart to scripts/test_apt_get.sh (which
# serves `Packages.gz`): modern Debian ships `Packages.xz` as the primary
# binary-amd64 index, and `apt update` now probes for `.xz` FIRST and
# routes the body through lib/xz/xz.ad's xz_decompress() — falling back
# to the gzip inflater only when `.xz` is absent. This test exercises the
# `.xz`-present branch end to end, against a host `xz`-compressed index.
#
# Pipeline (mirrors test_apt_get.sh):
#   1. Build user/apt.ad -> build/user/apt.elf -> /bin/apt.
#   2. Fabricate a fake Debian repo tree on the host:
#          dists/stable/Release
#          dists/stable/main/binary-amd64/Packages.xz   (xz / LZMA2)
#      NOTE: NO Packages.gz is written — so if apt did not use the `.xz`
#      decoder, `apt update` would fail outright. A passing run proves
#      the xz path is the one that ran.
#   3. Start a host-side Python http.server rooted at the repo tree.
#   4. Boot Hamnix with /init = hamsh and drive `apt update` + queries.
#   5. Assert the index was fetched, xz-decompressed, parsed, stored at
#      /tmp/apt/Packages, and the queries return the right data.
#
# The NETWORKING NOTE / guestfwd rationale is identical to
# scripts/test_apt_get.sh — see that file's header.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

if ! command -v xz >/dev/null 2>&1; then
    echo "[test_apt_xz] FAIL: host 'xz' binary not found (needed to build the index)"
    exit 1
fi

# --- fixture package identities --------------------------------------
PKG_A='hamnix-base'
VER_A='1.0.0'
PKG_B='libhamc1'
VER_B='2.4.1'
PKG_C='hamnix-utils'
VER_C='0.9'
MISSING_PKG='no-such-package'

# --- pick a free host port -------------------------------------------
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_apt_xz] using host port $PORT"

echo "[test_apt_xz] (1/6) Build userland (hamsh + apt + helpers) + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

if [ ! -x "build/user/apt.elf" ]; then
    echo "[test_apt_xz] FAIL: build/user/apt.elf missing after build_user.sh"
    exit 1
fi

echo "[test_apt_xz] (2/6) Fabricate fake Debian repo tree (xz index)"
REPO_DIR=$(mktemp -d --tmpdir hamnix-apt-xz-repo.XXXXXX)
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
Description: Hamnix apt xz-index test repository
EOF

# A hand-written Packages file: 3 blank-line-separated RFC822 stanzas.
PACKAGES_PLAIN="$REPO_DIR/Packages.plain"
cat > "$PACKAGES_PLAIN" <<EOF
Package: $PKG_A
Version: $VER_A
Architecture: amd64
Filename: pool/main/h/hamnix-base/${PKG_A}_${VER_A}_amd64.deb
Size: 4096
SHA256: 0000000000000000000000000000000000000000000000000000000000000001
Depends: libhamc1
Description: APTXZ_OK Hamnix base system metapackage
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

# Compress to dists/stable/main/binary-amd64/Packages.xz — LZMA2, the
# format lib/xz/xz.ad decodes. Crucially we do NOT also write a
# Packages.gz: a passing run proves apt used the `.xz` codepath.
xz -9 -c --format=xz "$PACKAGES_PLAIN" > "$BIN_DIR/Packages.xz"
echo "[test_apt_xz]   repo: $REPO_DIR"
echo "[test_apt_xz]   Release: $(stat -c%s "$DIST_DIR/Release") bytes"
echo "[test_apt_xz]   Packages.xz: $(stat -c%s "$BIN_DIR/Packages.xz") bytes" \
     "(plain $(stat -c%s "$PACKAGES_PLAIN") bytes)"
if [ -e "$BIN_DIR/Packages.gz" ]; then
    echo "[test_apt_xz] FAIL: a Packages.gz exists — this test must serve xz only"
    exit 1
fi

echo "[test_apt_xz] (3/6) Swap /init = hamsh in cpio initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_apt_xz] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_apt_xz] (5/6) Start host http.server + boot QEMU"
LOG=$(mktemp)
SRVLOG=$(mktemp)

# Bind 0.0.0.0 so the SLIRP host alias 10.0.2.2 routes to it.
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
    printf 'echo APT_SHOW_START\n'
    printf '/bin/apt show %s\n' "$PKG_B"
    sleep 5
    printf 'echo APT_PKGNAMES_START\n'
    printf '/bin/apt pkgnames\n'
    sleep 5
    printf 'echo APT_CAT_START\n'
    printf 'cat /tmp/apt/Packages\n'
    sleep 5
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

echo "[test_apt_xz] --- captured (apt / u_socket / tcp / dhcp) ---"
grep -E 'apt-get:|apt-cache:|apt:|APT_|\[u_socket\]|\[tcp\]|\[dhcp\]|Package:' "$LOG" || true
echo "[test_apt_xz] --- end ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_apt_xz] OK: '$1'"
    else
        echo "[test_apt_xz] MISS: '$1'"
        fail=1
    fi
}

# (a) apt announced it took the xz codepath.
check "apt-get: using xz-compressed index (Packages.xz)"

# (b) `apt update` fetched + xz-decompressed + parsed the index.
check "apt-get: fetched Release ("
check "apt-get: fetched index, 3 packages"

# (c) `apt show libhamc1` printed that package's stanza.
check "Package: $PKG_B"
check "Version: $VER_B"
check "Hamnix C runtime shared library"

# (d) `apt pkgnames` listed every package name.
for needle in "$PKG_A" "$PKG_B" "$PKG_C"; do
    check "$needle"
done

# (e) the xz-decompressed index really landed at /tmp/apt/Packages — the
#     APTXZ_OK marker is in the first stanza's Description.
check "APTXZ_OK"

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_apt_xz] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_apt_xz] FAIL (qemu rc=$rc)"
    echo "[test_apt_xz] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    echo "[test_apt_xz] --- http.server log ---"
    cat "$SRVLOG" || true
    exit 1
fi

echo "[test_apt_xz] PASS — userland apt fetched a Debian repo index whose" \
     "binary-amd64 index is xz-compressed, decompressed it via lib/xz/xz.ad," \
     "parsed it, and queries return correct data"
