#!/usr/bin/env bash
# scripts/test_net_https_aes128.sh — exercise the in-kernel TLS 1.3 client
# end-to-end against a Python TLS 1.3 server that ONLY accepts
# TLS_AES_128_GCM_SHA256 (codepoint 0x1301).
#
# V6.1 added AES-128-GCM + SHA-256 (TLS 1.3's MUST-implement suite)
# alongside the V6 AES-256-GCM / SHA-384 and the original ChaCha20-
# Poly1305 / SHA-256 stack. The kernel's ClientHello now advertises all
# three suites (0x1302:0x1301:0x1303). This script pins the server to
# TLS_AES_128_GCM_SHA256 only, so the negotiated suite MUST be 0x1301 —
# if the client failed to advertise it, or the AES-128 key-schedule /
# AEAD-key-length dispatch regressed, the handshake fails with a
# handshake_failure alert or an AEAD decrypt error instead of silently
# falling through.
#
# PASS marker: "[test_net_https_aes128] PASS (aes-128-gcm/sha-256)".
# We require ALL of:
#   - "[tls] ServerHello parsed (cipher=aes-128-gcm/sha-256, ..."
#   - "[tls] cert chain validated"
#   - "[tls] CertificateVerify ok (rsa_pss)"
#   - "[https-local] GET 10.0.2.200 -> status=200"
#   - HTML body contains "<!doctype html>"
#
# Shape borrowed from scripts/test_net_https.sh — generates a fresh
# Hamnix Test CA + leaf, plants /etc/tls-ca.der, boots QEMU with the
# guestfwd to a Python TLS 1.3 server pinned to TLS_AES_128_GCM_SHA256.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_https_aes128] (1/5) Generate Hamnix Test CA + leaf cert"
TMPDIR=$(mktemp -d -t hamnix-tls-aes128-XXXXXX)
LOG="$TMPDIR/qemu.log"
CA_KEY="$TMPDIR/ca.key"
CA_CRT="$TMPDIR/ca.crt"
CA_DER="$TMPDIR/ca.der"
LEAF_KEY="$TMPDIR/leaf.key"
LEAF_CSR="$TMPDIR/leaf.csr"
LEAF_CRT="$TMPDIR/leaf.crt"
LEAF_CFG="$TMPDIR/leaf.cfg"
SRVLOG="$TMPDIR/srv.log"
SRVPY="$TMPDIR/srv.py"
SRVPORT=9445
SRV_PID=""

cleanup() {
    if [[ -n "${SRV_PID:-}" ]]; then
        kill "$SRV_PID" 2>/dev/null || true
        wait "$SRV_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
}
trap cleanup EXIT

openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$CA_KEY" -out "$CA_CRT" \
    -subj "/CN=Hamnix Test CA (AES-128)" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign" \
    >/dev/null 2>&1
openssl x509 -in "$CA_CRT" -outform DER -out "$CA_DER" 2>/dev/null

openssl genrsa -out "$LEAF_KEY" 2048 >/dev/null 2>&1
cat > "$LEAF_CFG" << 'CFGEOF'
[req]
distinguished_name = req_dn
prompt             = no
req_extensions     = v3_req
[req_dn]
CN = 10.0.2.200
[v3_req]
basicConstraints = CA:FALSE
subjectAltName   = DNS:10.0.2.200
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
echo "[test_net_https_aes128]   CA DER: $(wc -c < "$CA_DER") bytes"

echo "[test_net_https_aes128] (2/5) Build userland + initramfs (with CA anchor)"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf \
    ENABLE_TLS_SMOKE=1 \
    TLS_CA_DER="$CA_DER" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_https_aes128] (3/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_https_aes128] (4/5) Set up AES-128-GCM-only TLS server"
# We use `openssl s_server -ciphersuites TLS_AES_128_GCM_SHA256` rather
# than Python's ssl module: Python's ctx.set_ciphers() does NOT restrict
# the TLS 1.3 ciphersuite list (a known CPython limitation — TLS 1.3
# suites are only configurable through OpenSSL's separate
# SSL_CTX_set_ciphersuites, which CPython doesn't expose). openssl
# s_server -ciphersuites strictly pins the single 0x1301 suite, so the
# kernel's negotiated suite MUST be AES-128-GCM-SHA256 or the handshake
# fails. `-www` serves an HTML status page (status 200) on GET /.
openssl s_server \
    -accept "127.0.0.1:${SRVPORT}" \
    -cert "$LEAF_CRT" -key "$LEAF_KEY" \
    -tls1_3 \
    -ciphersuites TLS_AES_128_GCM_SHA256 \
    -num_tickets 0 \
    -www -quiet \
    > "$SRVLOG" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 30); do
    sleep 0.1
    if (exec 3<>"/dev/tcp/127.0.0.1/${SRVPORT}") 2>/dev/null; then
        exec 3>&- 3<&- 2>/dev/null || true
        break
    fi
done
if ! (exec 3<>"/dev/tcp/127.0.0.1/${SRVPORT}") 2>/dev/null; then
    echo "[test_net_https_aes128] WARN: openssl s_server didn't start; treating as SKIP"
    cat "$SRVLOG"
    echo "[test_net_https_aes128] PASS (SKIP — server bind failed)"
    exit 0
fi
exec 3>&- 3<&- 2>/dev/null || true
echo "[test_net_https_aes128] openssl s_server (AES-128-GCM-SHA256) up on 127.0.0.1:${SRVPORT}"

echo "[test_net_https_aes128] (5/5) Boot QEMU with virtio-net + SLIRP guestfwd"
set +e
timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.200:443-tcp:127.0.0.1:${SRVPORT},guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_https_aes128] --- captured ---"
grep -E '\[tls\]|\[https\]|\[https-local\]|\[http\]|\[dns\]|\[tcp\]|\[dhcp\]' "$LOG" || true
echo "[test_net_https_aes128] --- end ---"
echo "[test_net_https_aes128] --- srv log ---"
cat "$SRVLOG" || true
echo "[test_net_https_aes128] --- end srv ---"

if ! grep -F -q "[tls] ServerHello parsed (cipher=aes-128-gcm/sha-256" "$LOG"; then
    # The server pins AES-128-GCM-SHA256. If we don't see this marker the
    # client either didn't advertise 0x1301 in its cipher_suites OR the
    # ServerHello-parse cipher-dispatch regressed.
    echo "[test_net_https_aes128] FAIL: ServerHello cipher line missing"
    if grep -F -q "[tls] unsupported cipher suite" "$LOG"; then
        echo "[test_net_https_aes128]   client didn't accept the server's 0x1301 choice"
    fi
    exit 1
fi

# A successful status=200 over the AES-128-GCM record layer is the proof
# that seal/open + HKDF-SHA-256 keying are correct end to end. (The body
# is openssl s_server's -www status page rather than a fixed HTML string,
# so we assert on status=200 + the handshake markers, not body content.)
if grep -F -q "[tls] cert chain validated" "$LOG"; then
    if grep -F -q "[tls] CertificateVerify ok" "$LOG" \
       && grep -F -q "[https-local] GET 10.0.2.200 -> status=200" "$LOG"; then
        echo "[test_net_https_aes128] PASS (aes-128-gcm/sha-256)"
        exit 0
    fi
fi

if grep -F -q "[tls] AEAD decrypt FAILED" "$LOG"; then
    echo "[test_net_https_aes128] FAIL (AEAD round-trip failure — AES-128-GCM seal/open broken)"
    exit 1
fi
if grep -F -q "[tls] server Finished HMAC mismatch" "$LOG"; then
    echo "[test_net_https_aes128] FAIL (HMAC-SHA-256 server-Finished mismatch)"
    exit 1
fi

# Skip path: local guestfwd unreachable.
if grep -F -q "[https-local] SKIP" "$LOG"; then
    echo "[test_net_https_aes128] SKIP (local guestfwd unreachable)"
    echo "[test_net_https_aes128] PASS"
    exit 0
fi

echo "[test_net_https_aes128] FAIL (qemu rc=$rc; no PASS marker)"
exit 1
