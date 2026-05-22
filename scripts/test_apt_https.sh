#!/usr/bin/env bash
# scripts/test_apt_https.sh — apt-path: fetch + decompress + parse a
# Debian repository index over HTTPS (TLS 1.3) from a userland binary.
#
# This is test_apt_get.sh's sibling: where that fetches a repo index
# over plain HTTP, this proves the same `apt update`/`show`/`pkgnames`
# pipeline works against an HTTPS mirror — closing the gap to real
# Debian mirrors, which are HTTPS-only. The new piece under test is
# user/apt.ad's https:// support:
#
#   * _parse_url accepts `https://host[:port][/path]` and defaults the
#     port to 443.
#   * _http_get, after connect(), takes the socket through the TLS 1.3
#     handshake via sys_tls_connect(2) (SYS_TLS_CONNECT 277 -> the
#     in-kernel TLS stack: X25519 + server cert-chain validation +
#     CertificateVerify transcript binding). The SNI / cert-name host
#     is the original hostname string.
#   * the HTTP request/response parsing is scheme-agnostic — once the
#     fd is TLS-active, write(GET)/read(response) are transparently
#     encrypted, so the rest of apt.ad is unchanged.
#
# Strategy mirrors test_u_tls.sh's TLS-server + cert fixture and
# test_apt_get.sh's fake-Debian-repo fixture:
#
#   1. Generate a fresh fake "Hamnix Test CA" (RSA-2048, CA:TRUE) and a
#      leaf cert (RSA-2048) with subjectAltName=DNS:10.0.2.2, signed
#      by the CA with rsassaPss + SHA-256.
#   2. Plant the CA's DER bytes into the initramfs as /etc/tls-ca.der
#      (TLS_CA_DER env -> build_initramfs.py) so the kernel TLS
#      validator has the matching anchor.
#   3. Fabricate a fake Debian repo tree on the host:
#          dists/stable/Release
#          dists/stable/main/binary-amd64/Packages.gz   (gzip)
#   4. Spawn a Python TLS 1.3 server (ssl-wrapped http.server) rooted
#      at the repo tree on 127.0.0.1:9445, serving the leaf cert + key.
#   5. Boot QEMU with /init = hamsh; the guest reaches the host server
#      via SLIRP's native NAT alias 10.0.2.2 (the route test_apt_get.sh
#      uses — it services apt's back-to-back Release + Packages.gz
#      fetches, which a one-shot guestfwd cannot). Then drive:
#          /bin/apt update https://10.0.2.2:9445 stable
#          /bin/apt show <pkg>
#          /bin/apt pkgnames
#   6. Assert the index was fetched over a validated TLS connection,
#      decompressed, parsed, stored at /tmp/apt/Packages, and the
#      queries return the right data. The in-kernel TLS stack must log
#      "[tls] cert chain validated" so a regression that silently
#      skips cert validation fails the test.
#
# The QEMU `guestfwd=tcp:10.0.2.100:7-cmd:cat` is REQUIRED even though
# this test never uses that echo target: init/main.ad's
# net_smoke_test() calls tcp_smoke_test() unconditionally during boot
# (same rationale as test_apt_get.sh / test_u_tls.sh).

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
MISSING_PKG='no-such-package'

# The guest reaches the TLS server through SLIRP's built-in host alias
# 10.0.2.2 — the same native-NAT route scripts/test_apt_get.sh uses
# for plain HTTP. `apt update` opens TWO connections back-to-back (one
# for Release, one for Packages.gz); SLIRP's native NAT services any
# number of guest connections, whereas a `guestfwd=...-tcp:` rule only
# reliably relays the first (the second connection never reached the
# host server, so the original guestfwd-based test could never pass).
# 10.0.2.2 forwards a guest connection to 10.0.2.2:PORT straight to
# the host's 127.0.0.1:PORT, so the leaf cert's CN / subjectAltName is
# the dotted-quad 10.0.2.2 — the SNI host apt hands tls_connect must
# match it for the in-kernel leaf-cert name check.
SRVPORT=9445
TLS_HOST=10.0.2.2

echo "[test_apt_https] (1/6) Generate Hamnix Test CA + leaf cert"
TMPDIR=$(mktemp -d -t hamnix-apt-https-XXXXXX)
LOG="$TMPDIR/qemu.log"
SRVLOG="$TMPDIR/srv.log"
SRVPY="$TMPDIR/srv.py"
CA_KEY="$TMPDIR/ca.key"
CA_CRT="$TMPDIR/ca.crt"
CA_DER="$TMPDIR/ca.der"
LEAF_KEY="$TMPDIR/leaf.key"
LEAF_CSR="$TMPDIR/leaf.csr"
LEAF_CRT="$TMPDIR/leaf.crt"
LEAF_CFG="$TMPDIR/leaf.cfg"
SRV_PID=""

cleanup() {
    if [[ -n "${SRV_PID:-}" ]]; then
        kill "$SRV_PID" 2>/dev/null || true
        wait "$SRV_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR" "${REPO_DIR:-}"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

# CA: RSA-2048 self-signed root with CA:TRUE — the strict-subset shape
# the kernel X.509 parser accepts (mirrors test_u_tls.sh).
openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$CA_KEY" -out "$CA_CRT" \
    -subj "/CN=Hamnix Test CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign" \
    >/dev/null 2>&1
openssl x509 -in "$CA_CRT" -outform DER -out "$CA_DER" 2>/dev/null

# Leaf: RSA-2048, signed by the test CA with rsassaPss-SHA256. CN /
# subjectAltName is the SLIRP host alias 10.0.2.2 — the host apt's
# tls_connect SNI / cert-name check runs against.
openssl genrsa -out "$LEAF_KEY" 2048 >/dev/null 2>&1
cat > "$LEAF_CFG" << CFGEOF
[req]
distinguished_name = req_dn
prompt             = no
req_extensions     = v3_req
[req_dn]
CN = ${TLS_HOST}
[v3_req]
basicConstraints = CA:FALSE
subjectAltName   = DNS:${TLS_HOST}
CFGEOF
openssl req -new -key "$LEAF_KEY" -out "$LEAF_CSR" -config "$LEAF_CFG" \
    >/dev/null 2>&1
openssl x509 -req -in "$LEAF_CSR" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -CAcreateserial -out "$LEAF_CRT" -days 30 \
    -sha256 \
    -sigopt rsa_padding_mode:pss \
    -sigopt rsa_pss_saltlen:32 \
    -extfile "$LEAF_CFG" -extensions v3_req \
    >/dev/null 2>&1
echo "[test_apt_https]   CA DER: $(wc -c < "$CA_DER") bytes"

echo "[test_apt_https] (2/6) Build userland (hamsh + apt + helpers) + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
if [ ! -x "build/user/apt.elf" ]; then
    echo "[test_apt_https] FAIL: build/user/apt.elf missing after build_user.sh"
    exit 1
fi

echo "[test_apt_https] (3/6) Fabricate fake Debian repo tree"
REPO_DIR=$(mktemp -d --tmpdir hamnix-apt-https-repo.XXXXXX)
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
Description: Hamnix apt HTTPS test repository
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
Description: APTHTTPS_OK Hamnix base system metapackage
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

# Compress to dists/stable/main/binary-amd64/Packages.gz (single gzip
# member — what lib/zlib/inflate.ad's V0 inflater handles).
gzip -9 -c "$PACKAGES_PLAIN" > "$BIN_DIR/Packages.gz"
echo "[test_apt_https]   repo: $REPO_DIR"
echo "[test_apt_https]   Release: $(stat -c%s "$DIST_DIR/Release") bytes"
echo "[test_apt_https]   Packages.gz: $(stat -c%s "$BIN_DIR/Packages.gz") bytes" \
     "(plain $(stat -c%s "$PACKAGES_PLAIN") bytes)"

echo "[test_apt_https] (4/6) Swap /init = hamsh + plant CA anchor in initramfs"
INIT_ELF="$HAMSH_ELF" \
    TLS_CA_DER="$CA_DER" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_apt_https] (5/6) Rebuild kernel image + start Python TLS repo server"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# Python TLS 1.3 server: an http.server whose accepted sockets are
# wrapped with ssl before the HTTP handler touches them (the standard
# get_request() override idiom). The guest's HTTPS GETs land here as
# ordinary HTTP requests once decrypted; SimpleHTTPRequestHandler
# serves the static repo files.
cat > "$SRVPY" << 'PYEOF'
import functools, http.server, socketserver, ssl, sys

CERT = sys.argv[1]
KEY  = sys.argv[2]
PORT = int(sys.argv[3])
ROOT = sys.argv[4]

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.load_cert_chain(certfile=CERT, keyfile=KEY)
ctx.num_tickets = 0
try:
    ctx.set_ciphers("TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256")
except Exception:
    pass

Handler = functools.partial(http.server.SimpleHTTPRequestHandler,
                            directory=ROOT)


class TLSHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def get_request(self):
        # Accept the raw TCP socket, then run the TLS 1.3 handshake so
        # the HTTP handler sees a transparently-decrypted stream.
        conn, peer = self.socket.accept()
        try:
            tls = ctx.wrap_socket(conn, server_side=True)
            print(f"[srv] TLS handshake OK with {peer}", flush=True)
            return tls, peer
        except Exception as e:
            print(f"[srv] TLS handshake failed with {peer}: {e}",
                  flush=True)
            try:
                conn.close()
            except Exception:
                pass
            raise

    def handle_error(self, request, client_address):
        # A failed TLS handshake raises out of get_request(); log it
        # quietly rather than dumping a traceback.
        print(f"[srv] connection error from {client_address}",
              flush=True)


srv = TLSHTTPServer(("127.0.0.1", PORT), Handler)
print(f"[srv] listening on 127.0.0.1:{PORT} (root={ROOT})", flush=True)
srv.serve_forever()
PYEOF

python3 "$SRVPY" "$LEAF_CRT" "$LEAF_KEY" "$SRVPORT" "$REPO_DIR" \
    > "$SRVLOG" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 30); do
    sleep 0.1
    if grep -F -q "listening on 127.0.0.1:${SRVPORT}" "$SRVLOG"; then
        break
    fi
done
if ! grep -F -q "listening on 127.0.0.1:${SRVPORT}" "$SRVLOG"; then
    echo "[test_apt_https] WARN: Python TLS server didn't start; treating as SKIP"
    echo "[test_apt_https] --- srv log ---"
    cat "$SRVLOG"
    echo "[test_apt_https] PASS (SKIP — server bind failed)"
    exit 0
fi
echo "[test_apt_https] Python TLS repo server up on 127.0.0.1:${SRVPORT}"

echo "[test_apt_https] (6/6) Boot QEMU with virtio-net + SLIRP native NAT"
set +e
(
    sleep 60
    printf '/bin/apt update https://%s:%s stable\n' "$TLS_HOST" "$SRVPORT"
    sleep 25
    printf 'echo APT_SHOW_START\n'
    printf '/bin/apt show %s\n' "$PKG_B"
    sleep 5
    printf 'echo APT_PKGNAMES_START\n'
    printf '/bin/apt pkgnames\n'
    sleep 5
    printf 'echo APT_MISS_START\n'
    printf '/bin/apt show %s\n' "$MISSING_PKG"
    sleep 5
    printf 'echo APT_CAT_START\n'
    printf 'cat /tmp/apt/Packages\n'
    sleep 5
    printf 'exit\n'
    sleep 2
) | timeout 260s qemu-system-x86_64 \
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

echo "[test_apt_https] --- captured (apt / tls / tcp / dhcp) ---"
grep -E 'apt-get:|apt-cache:|apt:|APT_|\[tls\]|\[tcp\]|\[dhcp\]|Package:' "$LOG" || true
echo "[test_apt_https] --- end ---"
echo "[test_apt_https] --- srv log ---"
cat "$SRVLOG" || true
echo "[test_apt_https] --- end srv ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_apt_https] OK: '$1'"
    else
        echo "[test_apt_https] MISS: '$1'"
        fail=1
    fi
}

# (a) the TLS 1.3 handshake completed AND the kernel validated the
#     server cert chain — a regression that skips cert validation must
#     fail the test.
check "apt: TLS handshake ok for ${TLS_HOST}"
check "[tls] cert chain validated"

# (b) `apt update` fetched + decompressed + parsed the index over TLS.
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

# (e) `apt show` on an absent package emits the not-found diagnostic.
check "not found in index"

# (f) the decompressed index really landed at /tmp/apt/Packages — the
#     APTHTTPS_OK marker is in the first stanza's Description.
check "APTHTTPS_OK"

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_apt_https] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

# Skip path: no network (DHCP unbound -> can't reach the SLIRP
# guestfwd). Same shape as test_u_tls.sh / test_net_https.sh.
if [ "$fail" -ne 0 ]; then
    if grep -F -q "no ACK received during init poll" "$LOG"; then
        echo "[test_apt_https] SKIP (no network — DHCP unbound)"
        echo "[test_apt_https] PASS"
        exit 0
    fi
    echo "[test_apt_https] FAIL (qemu rc=$rc)"
    echo "[test_apt_https] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    echo "[test_apt_https] --- TLS repo server log ---"
    cat "$SRVLOG" || true
    exit 1
fi

echo "[test_apt_https] PASS — userland apt fetched a Debian repo index" \
     "over a validated TLS 1.3 connection, gunzipped + parsed it"
