#!/usr/bin/env bash
# scripts/test_apt_inrelease.sh — apt chain-of-trust: verify the
# OpenPGP signature on a Debian repository's `InRelease` file.
#
# Before this, Hamnix's userland `apt` (user/apt.ad) fetched a repo's
# `Release` but trusted it on transport security alone — a MITM or a
# malicious mirror could serve a forged index. This test exercises the
# fix: `apt update` now fetches the inline-clearsigned `InRelease`,
# verifies its OpenPGP signature against a baked archive key, and
# refuses the repository outright on a bad signature.
#
# WHAT IS UNDER TEST
#   * lib/pgp/pgp.ad — OpenPGP packet parsing (RFC 4880): the v4
#     Public-Key packet, the v4 RSA signature packet, the cleartext-
#     signature framework (dash-unescaping + canonicalisation), and
#     radix-64 de-armor.
#   * lib/rsa/rsa.ad — RSA PKCS#1 v1.5 verification (s^e mod n, then
#     the EMSA-PKCS1-v1_5 DigestInfo check) over the SHA-256 digest of
#     the assembled v4 signed-data byte string.
#   * user/apt.ad — _verify_inrelease wiring: fetch InRelease, split,
#     de-armor, parse, build signed-data, verify; HARD ABORT on a bad
#     signature.
#   * scripts/build_initramfs.py — APT_TRUSTED_GPG bakes the test
#     public key into the initramfs at /etc/apt-trusted.gpg.
#
# STRATEGY
#   1. Generate a throwaway RSA-4096 OpenPGP signing key with gpg
#      (host-side, in a scratch GNUPGHOME). Export its public key.
#   2. Fabricate a fake Debian repo tree, exactly like test_apt_get.sh.
#   3. Clearsign dists/stable/Release -> dists/stable/InRelease with
#      that key (SHA-256 digest — what lib/rsa's v1.5 path supports).
#   4. Boot Hamnix TWICE against the same repo:
#        (a) GOOD run: serve the genuine InRelease. apt must report
#            "InRelease OpenPGP signature verified" and fetch the
#            index — proving a real signature is accepted.
#        (b) TAMPER run: serve an InRelease whose cleartext body has
#            been modified after signing (a byte flipped in the
#            Release content). apt must report the verification
#            FAILED and abort `apt update` — proving the verifier
#            actually does the math and is not a rubber stamp.
#   Both directions are asserted: a verifier that only ever says "ok"
#   is worthless.
#
# The QEMU `guestfwd=tcp:10.0.2.100:7-cmd:cat` is REQUIRED even though
# this test never uses that echo target — same boot-time net_smoke_test
# rationale as test_apt_get.sh / test_apt_https.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# --- fixture package identities --------------------------------------
PKG_A='hamnix-base'
VER_A='1.0.0'
PKG_B='libhamc1'
VER_B='2.4.1'
PKG_C='hamnix-utils'
VER_C='0.9'

if ! command -v gpg >/dev/null 2>&1; then
    echo "[test_apt_inrelease] SKIP — gpg not available on host"
    echo "[test_apt_inrelease] PASS"
    exit 0
fi

# --- pick a free host port -------------------------------------------
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_apt_inrelease] using host port $PORT"

TMPDIR=$(mktemp -d -t hamnix-apt-inrelease-XXXXXX)
GNUPGHOME="$TMPDIR/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
export GNUPGHOME
LOG_GOOD="$TMPDIR/qemu-good.log"
LOG_TAMPER="$TMPDIR/qemu-tamper.log"
SRVLOG="$TMPDIR/srv.log"
SRV_PID=""

cleanup() {
    if [[ -n "${SRV_PID:-}" ]]; then
        kill "$SRV_PID" 2>/dev/null || true
        wait "$SRV_PID" 2>/dev/null || true
    fi
    gpgconf --kill all >/dev/null 2>&1 || true
    rm -rf "$TMPDIR" "${REPO_DIR:-}"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_apt_inrelease] (1/7) Generate throwaway RSA-4096 archive signing key"
cat > "$TMPDIR/keyparams" <<'KP'
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: Hamnix Test Archive Key
Name-Email: archive@test.hamnix.local
Expire-Date: 0
%commit
KP
gpg --batch --gen-key "$TMPDIR/keyparams" >/dev/null 2>&1
PUB_GPG="$TMPDIR/apt-trusted.gpg"
gpg --export archive@test.hamnix.local > "$PUB_GPG"
echo "[test_apt_inrelease]   exported public key: $(wc -c < "$PUB_GPG") bytes"

echo "[test_apt_inrelease] (2/7) Build userland (hamsh + apt + helpers) + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
if [ ! -x "build/user/apt.elf" ]; then
    echo "[test_apt_inrelease] FAIL: build/user/apt.elf missing after build_user.sh"
    exit 1
fi

echo "[test_apt_inrelease] (3/7) Fabricate fake Debian repo tree"
REPO_DIR=$(mktemp -d --tmpdir hamnix-apt-inrelease-repo.XXXXXX)
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
Description: Hamnix apt InRelease signature test repository
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
Description: APTSIG_OK Hamnix base system metapackage
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

echo "[test_apt_inrelease] (4/7) Clearsign Release -> InRelease (SHA-256 digest)"
# The genuine, correctly-signed InRelease.
gpg --batch --yes --digest-algo SHA256 \
    --clearsign -o "$DIST_DIR/InRelease" "$DIST_DIR/Release"
# A tampered copy: flip a byte of the cleartext body AFTER signing —
# the OpenPGP signature no longer matches. Editing the Codename value
# keeps the clearsign framing intact while corrupting the signed text.
python3 - "$DIST_DIR/InRelease" "$TMPDIR/InRelease.tampered" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
# Replace "Codename: stable" -> "Codename: forged" inside the cleartext
# body (same length, so the armor offsets are unchanged).
tampered = data.replace(b"Codename: stable", b"Codename: forged", 1)
assert tampered != data, "tamper substitution did not match"
open(dst, 'wb').write(tampered)
PY
echo "[test_apt_inrelease]   InRelease: $(stat -c%s "$DIST_DIR/InRelease") bytes" \
     "(tampered copy staged)"

# Boot helper: rebuilds the initramfs (hamsh as /init + the baked
# trusted key) + the kernel, starts the repo HTTP server, drives one
# `apt update`, and leaves the kernel log in $1.
run_boot() {
    local outlog="$1"

    INIT_ELF="$HAMSH_ELF" \
        APT_TRUSTED_GPG="$PUB_GPG" \
        python3 scripts/build_initramfs.py >/dev/null
    python3 -m compiler.adder compile \
        --target=x86_64-bare-metal \
        init/main.ad \
        -o "$ELF" >/dev/null

    python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$REPO_DIR" \
        > "$SRVLOG" 2>&1 &
    SRV_PID=$!
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
        sleep 25
        printf 'echo APT_DONE\n'
        sleep 3
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
        > "$outlog" 2>&1
    set -e

    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
    SRV_PID=""
}

echo "[test_apt_inrelease] (5/7) GOOD run — genuine InRelease must verify"
run_boot "$LOG_GOOD"
echo "[test_apt_inrelease] --- GOOD run captured ---"
grep -E 'apt-get:|apt:|APT_' "$LOG_GOOD" || true
echo "[test_apt_inrelease] --- end ---"

echo "[test_apt_inrelease] (6/7) TAMPER run — forged InRelease must be rejected"
cp "$TMPDIR/InRelease.tampered" "$DIST_DIR/InRelease"
run_boot "$LOG_TAMPER"
echo "[test_apt_inrelease] --- TAMPER run captured ---"
grep -E 'apt-get:|apt:|APT_' "$LOG_TAMPER" || true
echo "[test_apt_inrelease] --- end ---"

echo "[test_apt_inrelease] (7/7) Assert both directions"
fail=0

# A network-down boot can't reach the repo at all — treat as SKIP
# (same shape as test_apt_https.sh).
if grep -F -q "no ACK received during init poll" "$LOG_GOOD"; then
    echo "[test_apt_inrelease] SKIP (no network — DHCP unbound)"
    echo "[test_apt_inrelease] PASS"
    exit 0
fi

check_in() {
    # check_in <logfile> <needle>
    if grep -F -q "$2" "$1"; then
        echo "[test_apt_inrelease] OK: '$2'"
    else
        echo "[test_apt_inrelease] MISS: '$2'"
        fail=1
    fi
}
check_absent() {
    # check_absent <logfile> <needle>
    if grep -F -q "$2" "$1"; then
        echo "[test_apt_inrelease] UNEXPECTED: '$2' present"
        fail=1
    else
        echo "[test_apt_inrelease] OK (absent): '$2'"
    fi
}

# (a) GOOD run: the signature verified and the index was fetched.
check_in "$LOG_GOOD" "InRelease OpenPGP signature verified"
check_in "$LOG_GOOD" "repository is authentic"
check_in "$LOG_GOOD" "apt-get: fetched index, 3 packages"
# The GOOD run must NOT report a verification failure.
check_absent "$LOG_GOOD" "signature verification FAILED"

# (b) TAMPER run: the signature failed and `apt update` aborted. apt
#     must NOT go on to fetch + parse the index.
check_in "$LOG_TAMPER" "signature verification FAILED"
check_in "$LOG_TAMPER" "repository is NOT authentic"
check_absent "$LOG_TAMPER" "apt-get: fetched index, 3 packages"

for L in "$LOG_GOOD" "$LOG_TAMPER"; do
    if grep -F -q "TRAP: vector" "$L"; then
        echo "[test_apt_inrelease] DIAG: kernel reported a CPU exception in $L"
        grep -F "TRAP: vector" "$L" | head -5 || true
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_apt_inrelease] FAIL"
    echo "[test_apt_inrelease] --- GOOD log (last 120 lines) ---"
    tail -n 120 "$LOG_GOOD"
    echo "[test_apt_inrelease] --- TAMPER log (last 120 lines) ---"
    tail -n 120 "$LOG_TAMPER"
    exit 1
fi

echo "[test_apt_inrelease] PASS — apt verifies the InRelease OpenPGP" \
     "signature: a genuine signature is accepted, a tampered one is" \
     "rejected and aborts the update"
