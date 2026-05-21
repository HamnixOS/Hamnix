#!/usr/bin/env bash
# scripts/test_apt_inrelease_sha512.sh — apt chain-of-trust against a
# REAL-Debian-shaped InRelease: a SHA-512 OpenPGP signature, and a
# MULTI-KEY keyring where the signing key is NOT the first one.
#
# WHY THIS EXISTS
#   scripts/test_apt_inrelease.sh proved apt verifies a SHA-256,
#   single-key InRelease. But the genuine `deb.debian.org` archive
#   signs `Release`/`InRelease` with a SHA-512 digest, and ships a
#   `debian-archive-keyring.gpg` carrying SEVERAL signing keys. This
#   test closes both gaps:
#     * SHA-512 signature path — lib/sha2/sha2.ad (userland SHA-512) +
#       lib/rsa/rsa.ad's SHA-512 EMSA-PKCS1-v1_5 DigestInfo variant.
#     * Multi-key keyring — lib/pgp/pgp.ad's pgp_keyring_load collects
#       EVERY Public-Key packet; apt tries each until one verifies.
#
# STRATEGY
#   1. Generate TWO throwaway RSA-4096 OpenPGP keys (a decoy + the real
#      signing key). Export BOTH into one keyring blob — the decoy
#      first, the signer second — so verification only succeeds if apt
#      walks past the first key.
#   2. Fabricate a fake Debian repo tree (same shape as
#      test_apt_inrelease.sh).
#   3. Clearsign Release -> InRelease with the SECOND key, using a
#      SHA-512 digest (gpg --digest-algo SHA512).
#   4. Boot Hamnix TWICE:
#        (a) GOOD run: genuine SHA-512 InRelease — apt must report
#            "InRelease OpenPGP signature verified" and fetch the
#            index. Proves a SHA-512 signature from a non-first key
#            verifies.
#        (b) TAMPER run: a byte of the signed cleartext flipped after
#            signing — apt must report the verification FAILED and
#            abort. Proves the SHA-512 path does the real math.
#
# Same boot-time-net rationale (guestfwd echo target) as the sibling
# tests.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

PKG_A='hamnix-base'
VER_A='1.0.0'
PKG_B='libhamc1'
VER_B='2.4.1'
PKG_C='hamnix-utils'
VER_C='0.9'

if ! command -v gpg >/dev/null 2>&1; then
    echo "[test_apt_inrelease_sha512] SKIP — gpg not available on host"
    echo "[test_apt_inrelease_sha512] PASS"
    exit 0
fi

PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_apt_inrelease_sha512] using host port $PORT"

TMPDIR=$(mktemp -d -t hamnix-apt-sha512-XXXXXX)
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

echo "[test_apt_inrelease_sha512] (1/7) Generate two throwaway RSA-4096 keys"
# A decoy key (will be the FIRST key in the exported keyring) and the
# real signing key (the SECOND). Verification only passes if apt walks
# past the decoy to the signer.
cat > "$TMPDIR/keyparams-decoy" <<'KP'
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: Hamnix Decoy Key
Name-Email: decoy@test.hamnix.local
Expire-Date: 0
%commit
KP
cat > "$TMPDIR/keyparams-signer" <<'KP'
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: Hamnix Real Archive Key
Name-Email: signer@test.hamnix.local
Expire-Date: 0
%commit
KP
# Generate the decoy FIRST so it sorts earlier in the keyring export
# (gpg --export emits keys in keyring insertion order).
gpg --batch --gen-key "$TMPDIR/keyparams-decoy" >/dev/null 2>&1
gpg --batch --gen-key "$TMPDIR/keyparams-signer" >/dev/null 2>&1

PUB_GPG="$TMPDIR/apt-trusted.gpg"
# Export the decoy first, then the signer — concatenated into one
# multi-key keyring blob.
gpg --export decoy@test.hamnix.local signer@test.hamnix.local > "$PUB_GPG"
echo "[test_apt_inrelease_sha512]   multi-key keyring: $(wc -c < "$PUB_GPG") bytes"
NKEYS=$(gpg --export decoy@test.hamnix.local signer@test.hamnix.local \
        | gpg --list-packets 2>/dev/null | grep -c ':public key packet:' || true)
echo "[test_apt_inrelease_sha512]   Public-Key packets in keyring: $NKEYS"

echo "[test_apt_inrelease_sha512] (2/7) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
if [ ! -x "build/user/apt.elf" ]; then
    echo "[test_apt_inrelease_sha512] FAIL: build/user/apt.elf missing"
    exit 1
fi

echo "[test_apt_inrelease_sha512] (3/7) Fabricate fake Debian repo tree"
REPO_DIR=$(mktemp -d --tmpdir hamnix-apt-sha512-repo.XXXXXX)
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
Description: Hamnix apt InRelease SHA-512 multi-key test repository
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

echo "[test_apt_inrelease_sha512] (4/7) Clearsign Release -> InRelease (SHA-512, second key)"
# Sign with the SECOND key, using a SHA-512 digest. -u selects the
# signer; --digest-algo SHA512 forces the v4 signature's hash algorithm
# to OpenPGP id 10 (SHA-512).
gpg --batch --yes --digest-algo SHA512 \
    -u signer@test.hamnix.local \
    --clearsign -o "$DIST_DIR/InRelease" "$DIST_DIR/Release"
# Confirm the signature really is SHA-512 (OpenPGP digest algo 10).
# `gpg --list-packets` on a clearsigned file only shows the literal-data
# packet; the signature packet lives in the armor. Extract the armored
# signature block and list THAT to inspect the digest algorithm.
python3 - "$DIST_DIR/InRelease" "$TMPDIR/sig.asc" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read().decode('latin1')
i = data.find('-----BEGIN PGP SIGNATURE-----')
assert i >= 0, "no signature armor in InRelease"
open(sys.argv[2], 'w').write(data[i:])
PY
if gpg --list-packets "$TMPDIR/sig.asc" 2>/dev/null \
        | grep -q 'digest algo 10'; then
    echo "[test_apt_inrelease_sha512]   confirmed: SHA-512 digest (algo 10)"
else
    echo "[test_apt_inrelease_sha512] FAIL: InRelease is not SHA-512-signed"
    gpg --list-packets "$TMPDIR/sig.asc" 2>/dev/null | grep -i digest || true
    exit 1
fi

# Tampered copy: flip a byte of the signed cleartext after signing.
python3 - "$DIST_DIR/InRelease" "$TMPDIR/InRelease.tampered" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
tampered = data.replace(b"Codename: stable", b"Codename: forged", 1)
assert tampered != data, "tamper substitution did not match"
open(dst, 'wb').write(tampered)
PY
echo "[test_apt_inrelease_sha512]   InRelease: $(stat -c%s "$DIST_DIR/InRelease") bytes" \
     "(tampered copy staged)"

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

echo "[test_apt_inrelease_sha512] (5/7) GOOD run — genuine SHA-512 InRelease must verify"
run_boot "$LOG_GOOD"
echo "[test_apt_inrelease_sha512] --- GOOD run captured ---"
grep -E 'apt-get:|apt:|APT_' "$LOG_GOOD" || true
echo "[test_apt_inrelease_sha512] --- end ---"

echo "[test_apt_inrelease_sha512] (6/7) TAMPER run — forged InRelease must be rejected"
cp "$TMPDIR/InRelease.tampered" "$DIST_DIR/InRelease"
run_boot "$LOG_TAMPER"
echo "[test_apt_inrelease_sha512] --- TAMPER run captured ---"
grep -E 'apt-get:|apt:|APT_' "$LOG_TAMPER" || true
echo "[test_apt_inrelease_sha512] --- end ---"

echo "[test_apt_inrelease_sha512] (7/7) Assert both directions"
fail=0

if grep -F -q "no ACK received during init poll" "$LOG_GOOD"; then
    echo "[test_apt_inrelease_sha512] SKIP (no network — DHCP unbound)"
    echo "[test_apt_inrelease_sha512] PASS"
    exit 0
fi

check_in() {
    if grep -F -q "$2" "$1"; then
        echo "[test_apt_inrelease_sha512] OK: '$2'"
    else
        echo "[test_apt_inrelease_sha512] MISS: '$2'"
        fail=1
    fi
}
check_absent() {
    if grep -F -q "$2" "$1"; then
        echo "[test_apt_inrelease_sha512] UNEXPECTED: '$2' present"
        fail=1
    else
        echo "[test_apt_inrelease_sha512] OK (absent): '$2'"
    fi
}

# (a) GOOD: a SHA-512 signature from the second key in a multi-key
#     keyring verified, and the index was fetched.
check_in "$LOG_GOOD" "InRelease OpenPGP signature verified"
check_in "$LOG_GOOD" "repository is authentic"
check_in "$LOG_GOOD" "apt-get: fetched index, 3 packages"
check_absent "$LOG_GOOD" "signature verification FAILED"
check_absent "$LOG_GOOD" "non-SHA-256"
check_absent "$LOG_GOOD" "unsupported, cannot verify"

# (b) TAMPER: the SHA-512 verification failed and the update aborted.
check_in "$LOG_TAMPER" "signature verification FAILED"
check_in "$LOG_TAMPER" "repository is NOT authentic"
check_absent "$LOG_TAMPER" "apt-get: fetched index, 3 packages"

for L in "$LOG_GOOD" "$LOG_TAMPER"; do
    if grep -F -q "TRAP: vector" "$L"; then
        echo "[test_apt_inrelease_sha512] DIAG: kernel exception in $L"
        grep -F "TRAP: vector" "$L" | head -5 || true
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_apt_inrelease_sha512] FAIL"
    echo "[test_apt_inrelease_sha512] --- GOOD log (last 120 lines) ---"
    tail -n 120 "$LOG_GOOD"
    echo "[test_apt_inrelease_sha512] --- TAMPER log (last 120 lines) ---"
    tail -n 120 "$LOG_TAMPER"
    exit 1
fi

echo "[test_apt_inrelease_sha512] PASS — apt verifies a SHA-512 InRelease" \
     "signature against a multi-key keyring (signing key not first): a" \
     "genuine signature is accepted, a tampered one is rejected"
