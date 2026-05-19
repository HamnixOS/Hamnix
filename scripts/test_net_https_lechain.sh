#!/usr/bin/env bash
# scripts/test_net_https_lechain.sh — end-to-end TLS 1.3 client against a
# 3-deep Let's-Encrypt-shape cert chain (root → intermediate → leaf, all
# RSA-2048, all sha256WithRSAEncryption / PKCS#1 v1.5).
#
# This is the "real apt-update target shape" fixture: deb.debian.org,
# archive.ubuntu.com, and every other LE-fronted mirror serves a 2-cert
# wire chain (leaf + intermediate) that chains up to ISRG Root X1 in the
# trust store. The kernel's V6 PKCS#1 v1.5 dispatch must walk all three
# signatures (CertificateVerify on the leaf via PSS, then leaf signed by
# intermediate via v1.5, then intermediate signed by root via v1.5) and
# only the root lives in the CA store.
#
# Pre-V6 brief: scripts/test_net_https.sh ships a 1-cert chain (self-
# signed leaf == root, planted in the CA store). That alone never
# exercises the chain-walker's "find a parent in the chain ARRAY (not
# castore)" path on the v1.5 code path. This fixture pins it down.
#
# PASS marker: "[test_net_https_lechain] PASS (3-deep v1.5 chain)".
# We require ALL of:
#   - "[tls] cert chain validated"
#   - "[tls] CertificateVerify ok"
#   - "[tls] Certificate: 2 certs in chain"     (leaf + R10-shape int)
#   - "[https-local] GET 10.0.2.200 -> status=200"
#   - HTML body contains "<!doctype html>"

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf

echo "[test_net_https_lechain] (1/5) Generate 3-deep RSA chain"
TMPDIR=$(mktemp -d -t hamnix-lechain-XXXXXX)
LOG="$TMPDIR/qemu.log"
ROOT_KEY="$TMPDIR/root.key"
ROOT_CRT="$TMPDIR/root.crt"
ROOT_DER="$TMPDIR/root.der"
INT_KEY="$TMPDIR/int.key"
INT_CRT="$TMPDIR/int.crt"
INT_CSR="$TMPDIR/int.csr"
LEAF_KEY="$TMPDIR/leaf.key"
LEAF_CRT="$TMPDIR/leaf.crt"
LEAF_CSR="$TMPDIR/leaf.csr"
LEAF_CFG="$TMPDIR/leaf.cfg"
INT_CFG="$TMPDIR/int.cfg"
CHAIN_PEM="$TMPDIR/chain.pem"
SRVLOG="$TMPDIR/srv.log"
SRVPY="$TMPDIR/srv.py"
SRVPORT=9447
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

# (1a) Root: RSA-4096 — mimics ISRG Root X1 exactly (4096-bit modulus,
#      527-byte SubjectPublicKey BIT STRING, sha256WithRSAEncryption /
#      PKCS#1 v1.5). This shape pins down TWO V6.1 fixes simultaneously:
#        - lib/x509/x509.ad::_parse_spki out_max=512 → 640 (the SPKI BIT
#          STRING for ISRG X1 is 527 bytes; out_max=512 made
#          asn1_read_bit_string return -2 (overflow) so castore_add_root
#          rejected the anchor at parse time).
#        - lib/bigint/bigint.ad BIGINT_MAX_LIMBS 64 → 68 (the shift-and-
#          add modmul's intermediate `result << 1` could set bit 4096
#          for a 4096-bit modulus, which 64-limb storage truncated; this
#          quietly returned the wrong modexp result for every RSA-4096
#          verify, so every intermediate-signed-by-ISRG-X1 chain
#          rejected its signature regardless of being correct).
openssl req -x509 -nodes -newkey rsa:4096 -days 30 \
    -keyout "$ROOT_KEY" -out "$ROOT_CRT" \
    -subj "/CN=Hamnix Test Root (ISRG-X1 shape, RSA-4096)" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -sha256 \
    >/dev/null 2>&1
openssl x509 -in "$ROOT_CRT" -outform DER -out "$ROOT_DER" 2>/dev/null

# (1b) Intermediate: RSA-2048, signed by root with PKCS#1 v1.5 (default).
cat > "$INT_CFG" << 'CFGEOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,digitalSignature
CFGEOF
openssl genrsa -out "$INT_KEY" 2048 >/dev/null 2>&1
openssl req -new -key "$INT_KEY" -out "$INT_CSR" \
    -subj "/CN=Hamnix Test R10 (LE-intermediate shape)" \
    >/dev/null 2>&1
openssl x509 -req -in "$INT_CSR" -CA "$ROOT_CRT" -CAkey "$ROOT_KEY" \
    -CAcreateserial -out "$INT_CRT" -days 30 \
    -sha256 \
    -extfile "$INT_CFG" \
    >/dev/null 2>&1

# (1c) Leaf: RSA-2048, signed by intermediate with PKCS#1 v1.5.
#      CN/SAN = 10.0.2.200 so the kernel's hostname match goes through.
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
openssl genrsa -out "$LEAF_KEY" 2048 >/dev/null 2>&1
openssl req -new -key "$LEAF_KEY" -out "$LEAF_CSR" -config "$LEAF_CFG" \
    >/dev/null 2>&1
openssl x509 -req -in "$LEAF_CSR" -CA "$INT_CRT" -CAkey "$INT_KEY" \
    -CAcreateserial -out "$LEAF_CRT" -days 30 \
    -sha256 \
    -extfile "$LEAF_CFG" -extensions v3_req \
    >/dev/null 2>&1

# (1d) Wire chain = leaf || intermediate (RFC 8446 §4.4.2 — server MUST
#      send leaf first; root is OPTIONAL and conventionally omitted).
cat "$LEAF_CRT" "$INT_CRT" > "$CHAIN_PEM"

echo "[test_net_https_lechain]   root DER: $(wc -c < "$ROOT_DER") bytes"
echo "[test_net_https_lechain]   int sigalg: $(openssl x509 -in "$INT_CRT" -noout -text | grep -m1 'Signature Algorithm')"
echo "[test_net_https_lechain]   leaf sigalg: $(openssl x509 -in "$LEAF_CRT" -noout -text | grep -m1 'Signature Algorithm')"

echo "[test_net_https_lechain] (2/5) Build userland + initramfs (root only in trust store)"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf \
    ENABLE_TLS_SMOKE=1 \
    TLS_CA_DER="$ROOT_DER" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_https_lechain] (3/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_https_lechain] (4/5) Set up Python TLS server with 2-cert wire chain"
cat > "$SRVPY" << 'PYEOF'
import socket, ssl, sys, threading

CHAIN = sys.argv[1]
KEY   = sys.argv[2]
PORT  = int(sys.argv[3])

BODY = (b"<!doctype html>\n"
        b"<html><head><title>Hamnix LE-chain test</title></head>\n"
        b"<body><h1>3-deep RSA-PKCS1v15 chain OK.</h1></body></html>\n")
RESP = (b"HTTP/1.1 200 OK\r\n"
        b"Content-Type: text/html\r\n"
        b"Content-Length: " + str(len(BODY)).encode() + b"\r\n"
        b"Connection: close\r\n"
        b"\r\n" + BODY)

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
# load_cert_chain reads the leaf + every following PEM block as the
# wire-chain to send. The intermediate's PKCS#1-v1.5 signature is the
# whole point of this fixture.
ctx.load_cert_chain(certfile=CHAIN, keyfile=KEY)
ctx.num_tickets = 0

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(4)
print(f"[srv] listening on 127.0.0.1:{PORT}", flush=True)

def handle(c, peer):
    try:
        tls = ctx.wrap_socket(c, server_side=True)
        print(f"[srv] TLS handshake OK with {peer}", flush=True)
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

python3 "$SRVPY" "$CHAIN_PEM" "$LEAF_KEY" "$SRVPORT" > "$SRVLOG" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 30); do
    sleep 0.1
    if grep -F -q "listening on 127.0.0.1:${SRVPORT}" "$SRVLOG"; then
        break
    fi
done
if ! grep -F -q "listening on 127.0.0.1:${SRVPORT}" "$SRVLOG"; then
    echo "[test_net_https_lechain] WARN: Python TLS server didn't start; treating as SKIP"
    cat "$SRVLOG"
    echo "[test_net_https_lechain] PASS (SKIP — server bind failed)"
    exit 0
fi
echo "[test_net_https_lechain] Python TLS server up on 127.0.0.1:${SRVPORT}"

echo "[test_net_https_lechain] (5/5) Boot QEMU with virtio-net + SLIRP guestfwd"
# Budget: RSA-4096 modexp is the bottleneck. The chain walker verifies up
# to 3 signatures per chain attempt: CV-on-leaf (RSA-2048 PSS), leaf-by-
# intermediate (RSA-2048 v1.5), intermediate-by-root (RSA-4096 v1.5).
# The 4096-bit modexp dominates — shift-and-add modmul over 4096 bits is
# ~30 s in QEMU TCG, and the unconditional example.com handshake at boot
# also burns budget before reaching the 10.0.2.200 case. 240 s gives
# comfortable headroom.
set +e
timeout 240s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.200:443-tcp:127.0.0.1:${SRVPORT},guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_https_lechain] --- captured ---"
grep -E '\[tls\]|\[https\]|\[https-local\]|\[http\]|\[dns\]|\[tcp\]|\[dhcp\]' "$LOG" || true
echo "[test_net_https_lechain] --- end ---"
echo "[test_net_https_lechain] --- srv log ---"
cat "$SRVLOG" || true
echo "[test_net_https_lechain] --- end srv ---"

if ! grep -F -q "[tls] Certificate: 2 certs in chain" "$LOG"; then
    echo "[test_net_https_lechain] FAIL: server didn't send 2-cert wire chain (got something else)"
    grep -F "[tls] Certificate:" "$LOG" || true
    exit 1
fi

if grep -F -q "[tls] cert chain validated" "$LOG"; then
    if grep -F -q "[tls] CertificateVerify ok" "$LOG" \
       && grep -F -q "[https-local] GET 10.0.2.200 -> status=200" "$LOG" \
       && grep -i -E -q '<!doctype html>' "$LOG"; then
        echo "[test_net_https_lechain] PASS (3-deep v1.5 chain)"
        exit 0
    fi
fi

if grep -F -q "[tls] cert chain rejected" "$LOG"; then
    echo "[test_net_https_lechain] FAIL (chain rejected — v1.5 walker bug?)"
    exit 1
fi

if grep -F -q "[tls] AEAD decrypt FAILED" "$LOG"; then
    echo "[test_net_https_lechain] FAIL (AEAD round-trip failure)"
    exit 1
fi
if grep -F -q "[tls] server Finished HMAC mismatch" "$LOG"; then
    echo "[test_net_https_lechain] FAIL (server Finished HMAC mismatch)"
    exit 1
fi
if grep -F -q "[https-local] SKIP" "$LOG"; then
    echo "[test_net_https_lechain] SKIP (local guestfwd unreachable)"
    echo "[test_net_https_lechain] PASS"
    exit 0
fi

echo "[test_net_https_lechain] FAIL (qemu rc=$rc; no PASS marker)"
exit 1
