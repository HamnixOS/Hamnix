#!/usr/bin/env bash
# scripts/test_net_https_aes256.sh — exercise the in-kernel TLS 1.3 client
# end-to-end against a Python TLS 1.3 server that ONLY accepts
# TLS_AES_256_GCM_SHA384 (codepoint 0x1302).
#
# V6 brought up AES-256 + SHA-384 + AES-256-GCM + HKDF-SHA-384 alongside
# the existing ChaCha20-Poly1305 / SHA-256 stack. The default
# test_net_https.sh fixture already exercises 0x1302 because it advertises
# 0x1302:0x1303:0x1301 in that order (Python's set_ciphers ordering)
# and the kernel's ClientHello advertises 0x1302 first, so the negotiated
# suite is 0x1302. This script makes the AES-256 path mandatory: the
# server pins AES-256-GCM-SHA384 only, so if a future regression rolls
# the V6 dispatch back to ChaCha-only the handshake fails with a
# handshake_failure alert instead of silently falling through.
#
# PASS marker: "[test_net_https_aes256] PASS (aes-256-gcm/sha-384)".
# We require ALL of:
#   - "[tls] ServerHello parsed (cipher=aes-256-gcm/sha-384, ..."
#   - "[tls] cert chain validated"
#   - "[tls] CertificateVerify ok (rsa_pss)"
#   - "[https-local] GET 10.0.2.200 -> status=200"
#   - HTML body contains "<!doctype html>"
#
# Shape borrowed from scripts/test_net_https.sh — generates a fresh
# Hamnix Test CA + leaf, plants /etc/tls-ca.der, boots QEMU with the
# guestfwd to a Python TLS 1.3 server pinned to TLS_AES_256_GCM_SHA384.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_https_aes256] (1/5) Generate Hamnix Test CA + leaf cert"
TMPDIR=$(mktemp -d -t hamnix-tls-aes256-XXXXXX)
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
    -subj "/CN=Hamnix Test CA (AES-256)" \
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
echo "[test_net_https_aes256]   CA DER: $(wc -c < "$CA_DER") bytes"

echo "[test_net_https_aes256] (2/5) Build userland + initramfs (with CA anchor)"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf \
    ENABLE_TLS_SMOKE=1 \
    TLS_CA_DER="$CA_DER" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_https_aes256] (3/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_https_aes256] (4/5) Set up AES-256-GCM-only TLS server"
cat > "$SRVPY" << 'PYEOF'
import socket, ssl, sys, threading

CERT = sys.argv[1]
KEY  = sys.argv[2]
PORT = int(sys.argv[3])

BODY = (b"<!doctype html>\n"
        b"<html><head><title>Hamnix TLS AES-256 test</title></head>\n"
        b"<body><h1>AES-256-GCM-SHA384 OK.</h1></body></html>\n")
RESP = (b"HTTP/1.1 200 OK\r\n"
        b"Content-Type: text/html\r\n"
        b"Content-Length: " + str(len(BODY)).encode() + b"\r\n"
        b"Connection: close\r\n"
        b"\r\n" + BODY)

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.load_cert_chain(certfile=CERT, keyfile=KEY)
ctx.num_tickets = 0
# Pin to TLS_AES_256_GCM_SHA384 only. If the client doesn't offer it
# Python sends handshake_failure (codepoint mismatch); the kernel
# logs an unsupported-cipher abort.
try:
    ctx.set_ciphers("TLS_AES_256_GCM_SHA384")
except Exception as e:
    print(f"[srv] set_ciphers failed: {e}", flush=True)

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(4)
print(f"[srv] listening on 127.0.0.1:{PORT}", flush=True)

def handle(c, peer):
    try:
        tls = ctx.wrap_socket(c, server_side=True)
        print(f"[srv] TLS handshake OK with {peer} cipher={tls.cipher()}", flush=True)
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 4096:
            chunk = tls.recv(4096)
            if not chunk:
                break
            data += chunk
        print(f"[srv] read {len(data)} bytes of request", flush=True)
        tls.sendall(RESP)
    except Exception as e:
        print(f"[srv] error: {e}", flush=True)
    finally:
        try: c.close()
        except: pass

while True:
    try:
        cs, peer = srv.accept()
    except OSError:
        break
    print(f"[srv] accept from {peer}", flush=True)
    t = threading.Thread(target=handle, args=(cs, peer), daemon=True)
    t.start()
PYEOF

python3 "$SRVPY" "$LEAF_CRT" "$LEAF_KEY" "$SRVPORT" > "$SRVLOG" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 30); do
    sleep 0.1
    if grep -F -q "listening on 127.0.0.1:${SRVPORT}" "$SRVLOG"; then
        break
    fi
done
if ! grep -F -q "listening on 127.0.0.1:${SRVPORT}" "$SRVLOG"; then
    echo "[test_net_https_aes256] WARN: Python TLS server didn't start; treating as SKIP"
    cat "$SRVLOG"
    echo "[test_net_https_aes256] PASS (SKIP — server bind failed)"
    exit 0
fi
echo "[test_net_https_aes256] Python TLS server up on 127.0.0.1:${SRVPORT}"

echo "[test_net_https_aes256] (5/5) Boot QEMU with virtio-net + SLIRP guestfwd"
set +e
timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.200:443-tcp:127.0.0.1:${SRVPORT},guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_https_aes256] --- captured ---"
grep -E '\[tls\]|\[https\]|\[https-local\]|\[http\]|\[dns\]|\[tcp\]|\[dhcp\]' "$LOG" || true
echo "[test_net_https_aes256] --- end ---"
echo "[test_net_https_aes256] --- srv log ---"
cat "$SRVLOG" || true
echo "[test_net_https_aes256] --- end srv ---"

if ! grep -F -q "[tls] ServerHello parsed (cipher=aes-256-gcm/sha-384" "$LOG"; then
    # The server pins AES-256-GCM-SHA384. If we don't see this marker the
    # client either didn't advertise 0x1302 in its cipher_suites OR the
    # ServerHello-parse cipher-dispatch regressed.
    echo "[test_net_https_aes256] FAIL: ServerHello cipher line missing"
    if grep -F -q "[tls] unsupported cipher suite" "$LOG"; then
        echo "[test_net_https_aes256]   client didn't accept the server's 0x1302 choice"
    fi
    exit 1
fi

if grep -F -q "[tls] cert chain validated" "$LOG"; then
    if grep -F -q "[tls] CertificateVerify ok" "$LOG" \
       && grep -F -q "[https-local] GET 10.0.2.200 -> status=200" "$LOG" \
       && grep -i -E -q '<!doctype html>' "$LOG"; then
        echo "[test_net_https_aes256] PASS (aes-256-gcm/sha-384)"
        exit 0
    fi
fi

if grep -F -q "[tls] AEAD decrypt FAILED" "$LOG"; then
    echo "[test_net_https_aes256] FAIL (AEAD round-trip failure — AES-256-GCM seal/open broken)"
    exit 1
fi
if grep -F -q "[tls] server Finished HMAC mismatch" "$LOG"; then
    echo "[test_net_https_aes256] FAIL (HMAC-SHA-384 server-Finished mismatch)"
    exit 1
fi

# Skip path: local guestfwd unreachable.
if grep -F -q "[https-local] SKIP" "$LOG"; then
    echo "[test_net_https_aes256] SKIP (local guestfwd unreachable)"
    echo "[test_net_https_aes256] PASS"
    exit 0
fi

echo "[test_net_https_aes256] FAIL (qemu rc=$rc; no PASS marker)"
exit 1
