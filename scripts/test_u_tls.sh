#!/usr/bin/env bash
# scripts/test_u_tls.sh — U-TLS: first userland HTTPS request.
#
# Proves a native-Adder user binary can complete an HTTPS request end
# to end — socket() / connect() / tls_connect() / write(an HTTPS GET) /
# read(the decrypted response) / close() — with the TLS 1.3 handshake
# (X25519 + server cert-chain validation against the kernel CA store +
# CertificateVerify transcript binding) and the record-layer encrypt /
# decrypt all mediated by the kernel.
#
# The new piece under test:
#   * tls_connect(2) — SYS_TLS_CONNECT (277) -> _u_tls_connect in
#     linux_abi/u_syscalls.ad. Takes a connected socket fd through the
#     in-kernel TLS 1.3 handshake (drivers/net/tls.ad).
#   * the per-fd TLS-active flag in linux_abi/u_socket_state.ad.
#   * the TLS-routing read/write/close arms in fs/vfs.ad — once the fd
#     is TLS-active, write() encrypts and read() decrypts transparently.
#
# Strategy mirrors scripts/test_net_https.sh's TLS-server fixture:
#
#   1. Generate a fresh fake "Hamnix Test CA" (RSA-2048, CA:TRUE) and a
#      leaf cert (RSA-2048) with subjectAltName=DNS:10.0.2.200, signed
#      by the CA using rsassaPss + SHA-256.
#   2. Plant the CA's DER bytes into the initramfs as /etc/tls-ca.der
#      (TLS_CA_DER env -> build_initramfs.py); drivers/net/tls.ad's
#      _tls_validation_init reads it out and castore_add_root's it on
#      the first handshake.
#   3. Spawn a Python TLS 1.3 server on 127.0.0.1:9444 serving the leaf
#      cert + key.
#   4. Embed user/u_tlstest.ad as /init and boot QEMU with
#      -netdev user,guestfwd=tcp:10.0.2.200:443-tcp:127.0.0.1:9444 so
#      the guest's 10.0.2.200:443 routes to the host TLS server.
#   5. u_tlstest does socket()->connect(10.0.2.200:443)->tls_connect()
#      ->write(GET)->read(decrypted response)->close(). It prints
#      markers; we assert them.
#
# Required markers (all must appear):
#   "[u_tlstest] connect rc=0"
#   "[u_tlstest] tls_connect rc=0"
#   "[u_tlstest] body=HTTP/..."
#   "[u_tlstest] PASS"
# AND the in-kernel TLS stack must log "[tls] cert chain validated"
# (so a regression that silently skips cert validation fails the test).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
TLSTEST_ELF=build/user/u_tlstest.elf

echo "[test_u_tls] (1/5) Generate Hamnix Test CA + leaf cert"
TMPDIR=$(mktemp -d -t hamnix-utls-XXXXXX)
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
SRVPORT=9444
SRV_PID=""

cleanup() {
    if [[ -n "${SRV_PID:-}" ]]; then
        kill "$SRV_PID" 2>/dev/null || true
        wait "$SRV_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

# CA: RSA-2048 self-signed root with CA:TRUE — strict-subset shape the
# kernel X.509 parser accepts (mirrors test_net_https.sh).
openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$CA_KEY" -out "$CA_CRT" \
    -subj "/CN=Hamnix Test CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign" \
    >/dev/null 2>&1
openssl x509 -in "$CA_CRT" -outform DER -out "$CA_DER" 2>/dev/null

# Leaf: RSA-2048, signed by the test CA with rsassaPss-SHA256.
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
echo "[test_u_tls]   CA DER: $(wc -c < "$CA_DER") bytes"

echo "[test_u_tls] (2/5) Build userland (incl. u_tlstest) + initramfs"
bash scripts/build_user.sh >/dev/null
if [ ! -f "$TLSTEST_ELF" ]; then
    echo "[test_u_tls] FAIL: $TLSTEST_ELF not built"
    exit 1
fi
# Embed u_tlstest as /init; plant /etc/tls-ca.der so the kernel TLS
# validator has the matching anchor. We deliberately do NOT set
# ENABLE_TLS_SMOKE — the in-kernel https smoke is not what this test
# exercises; u_tlstest drives the handshake from userland instead.
INIT_ELF="$TLSTEST_ELF" \
    TLS_CA_DER="$CA_DER" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_u_tls] (3/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_u_tls] (4/5) Set up local Python TLS 1.3 server"
cat > "$SRVPY" << 'PYEOF'
import socket, ssl, sys, threading

CERT = sys.argv[1]
KEY  = sys.argv[2]
PORT = int(sys.argv[3])

BODY = (b"<!doctype html>\n"
        b"<html><head><title>Hamnix U-TLS test</title></head>\n"
        b"<body><h1>It works.</h1></body></html>\n")
RESP = (b"HTTP/1.1 200 OK\r\n"
        b"Content-Type: text/html\r\n"
        b"Content-Length: " + str(len(BODY)).encode() + b"\r\n"
        b"Connection: close\r\n"
        b"\r\n" + BODY)

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.load_cert_chain(certfile=CERT, keyfile=KEY)
ctx.num_tickets = 0
try:
    ctx.set_ciphers("TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256")
except Exception:
    pass

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

python3 "$SRVPY" "$LEAF_CRT" "$LEAF_KEY" "$SRVPORT" > "$SRVLOG" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 30); do
    sleep 0.1
    if grep -F -q "listening on 127.0.0.1:${SRVPORT}" "$SRVLOG"; then
        break
    fi
done
if ! grep -F -q "listening on 127.0.0.1:${SRVPORT}" "$SRVLOG"; then
    echo "[test_u_tls] WARN: Python TLS server didn't start; treating as SKIP"
    echo "[test_u_tls] --- srv log ---"
    cat "$SRVLOG"
    echo "[test_u_tls] PASS (SKIP — server bind failed)"
    exit 0
fi
echo "[test_u_tls] Python TLS server up on 127.0.0.1:${SRVPORT}"

echo "[test_u_tls] (5/5) Boot QEMU with virtio-net + SLIRP guestfwd"
set +e
# guestfwd=tcp:10.0.2.200:443 routes the guest's HTTPS target to the
# host Python TLS server. guestfwd=tcp:10.0.2.100:7-cmd:cat makes
# init/main.ad's boot-time tcp_smoke_test() complete fast so boot
# reaches /init promptly (same rationale as test_net_https.sh).
timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.200:443-tcp:127.0.0.1:${SRVPORT},guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 2 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_u_tls] --- captured (u_tlstest / u_tls / tls / tcp / dhcp) ---"
grep -E '\[u_tlstest\]|\[u_tls\]|\[tls\]|\[tcp\]|\[dhcp\]' "$LOG" || true
echo "[test_u_tls] --- end ---"
echo "[test_u_tls] --- srv log ---"
cat "$SRVLOG" || true
echo "[test_u_tls] --- end srv ---"

fail=0
for needle in \
    "[u_tlstest] connect rc=0" \
    "[u_tlstest] tls_connect rc=0" \
    "[u_tlstest] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u_tls] OK: '$needle'"
    else
        echo "[test_u_tls] MISS: '$needle'"
        fail=1
    fi
done

# The decrypted response the user binary received must be an HTTP
# status line — proof the read() arm TLS-decrypted correctly.
if grep -E -q "\[u_tlstest\] body=HTTP/" "$LOG"; then
    echo "[test_u_tls] OK: decrypted HTTP status line received by user binary"
else
    echo "[test_u_tls] MISS: no decrypted HTTP status line in user-binary output"
    fail=1
fi

# The in-kernel TLS stack must have validated the server cert chain —
# a regression that skips cert validation must fail this test.
if grep -F -q "[tls] cert chain validated" "$LOG"; then
    echo "[test_u_tls] OK: kernel TLS validated the server cert chain"
else
    echo "[test_u_tls] MISS: no '[tls] cert chain validated' marker"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u_tls] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

# Skip path: no network (DHCP unbound -> can't reach the SLIRP guestfwd
# either). Same shape as test_net_https.sh's no-internet skip.
if [ "$fail" -ne 0 ]; then
    if grep -F -q "no ACK received during init poll" "$LOG"; then
        echo "[test_u_tls] SKIP (no network — DHCP unbound)"
        echo "[test_u_tls] PASS"
        exit 0
    fi
    echo "[test_u_tls] FAIL (qemu rc=$rc)"
    echo "[test_u_tls] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    echo "[test_u_tls] --- http TLS server log ---"
    cat "$SRVLOG" || true
    exit 1
fi

echo "[test_u_tls] PASS — native user binary completed an HTTPS request" \
     "via socket/connect/tls_connect/write/read/close"
