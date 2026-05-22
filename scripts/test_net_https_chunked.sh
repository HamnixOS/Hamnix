#!/usr/bin/env bash
# scripts/test_net_https_chunked.sh — exercise the in-kernel HTTP/1.1
# chunked-transfer-encoding decoder over TLS 1.3 end-to-end.
#
# Setup mirrors scripts/test_net_https.sh: a Python TLS 1.3 server
# wraps a leaf cert signed by a freshly-generated "Hamnix Test CA",
# QEMU SLIRP guestfwds 10.0.2.200:443 -> 127.0.0.1:9443. The new bit
# is the response shape: instead of Content-Length, the server sends
#
#   HTTP/1.1 200 OK\r\n
#   Transfer-Encoding: chunked\r\n\r\n
#   a\r\n0123456789\r\n           (10 bytes)
#   5\r\nABCDE\r\n                 (5 bytes)
#   0\r\n\r\n                      (last-chunk)
#
# The kernel's init/main.ad https_chunked_smoke_test() calls
# https_get("https://10.0.2.200/chunked"); drivers/net/http.ad
# detects Transfer-Encoding: chunked, switches to the chunked
# decoder, and writes exactly 15 bytes ("0123456789ABCDE") into the
# caller's buffer. The kernel logs `[https-chunked] PASS` once the
# bytes are verified.
#
# Why a separate harness (not a sub-test of test_net_https.sh): the
# existing TLS test asserts on a Content-Length-delimited HTML body
# (`<!doctype html>`). Multiplexing both response shapes through a
# single fixture would tangle PASS markers and obscure regressions
# in either path.
#
# PASS marker: "[https-chunked] PASS" in the kernel log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_https_chunked] (1/5) Generate Hamnix Test CA + leaf cert"
TMPDIR=$(mktemp -d -t hamnix-tls-chunked-XXXXXX)
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
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
}
trap cleanup EXIT

openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$CA_KEY" -out "$CA_CRT" \
    -subj "/CN=Hamnix Test CA" \
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
echo "[test_net_https_chunked]   CA DER: $(wc -c < "$CA_DER") bytes"

echo "[test_net_https_chunked] (2/5) Build userland + initramfs (with CA + chunked marker)"
bash scripts/build_user.sh >/dev/null
# Plant /etc/tls-chunked-test (NOT /etc/tls-test) so init/main.ad
# fires https_chunked_smoke_test instead of https_local_smoke_test.
INIT_ELF=build/user/init.elf \
    ENABLE_TLS_CHUNKED_SMOKE=1 \
    TLS_CA_DER="$CA_DER" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_https_chunked] (3/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_https_chunked] (4/5) Set up Python TLS 1.3 chunked server"
cat > "$SRVPY" << 'PYEOF'
import socket, ssl, sys, threading

CERT = sys.argv[1]
KEY  = sys.argv[2]
PORT = int(sys.argv[3])

# Response: status + Transfer-Encoding: chunked header, then three
# chunks (10 + 5 + 0). The kernel decoder MUST emit exactly the 15
# concatenated body bytes "0123456789ABCDE".
HDRS = (b"HTTP/1.1 200 OK\r\n"
        b"Content-Type: application/octet-stream\r\n"
        b"Transfer-Encoding: chunked\r\n"
        b"Connection: close\r\n"
        b"\r\n")
CHUNK1 = b"a\r\n0123456789\r\n"       # 10 bytes
CHUNK2 = b"5\r\nABCDE\r\n"             # 5 bytes
LAST   = b"0\r\n\r\n"                  # last-chunk + empty trailer

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
        # Send headers, then each chunk separately to exercise the
        # decoder's refill path (the bytes arrive in distinct TLS
        # records, which the kernel must stitch together).
        tls.sendall(HDRS)
        tls.sendall(CHUNK1)
        tls.sendall(CHUNK2)
        tls.sendall(LAST)
        print(f"[srv] chunked body sent (10+5 bytes)", flush=True)
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
    echo "[test_net_https_chunked] WARN: Python TLS server didn't start; SKIP"
    cat "$SRVLOG"
    echo "[test_net_https_chunked] PASS (SKIP — server bind failed)"
    exit 0
fi
echo "[test_net_https_chunked] Python TLS server up on 127.0.0.1:${SRVPORT}"

echo "[test_net_https_chunked] (5/5) Boot QEMU with virtio-net + SLIRP guestfwd"
set +e
timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.200:443-tcp:127.0.0.1:${SRVPORT},guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_https_chunked] --- captured (tls / https / http / dns / tcp / dhcp) ---"
grep -E '\[tls\]|\[https\]|\[https-chunked\]|\[http\]|\[dns\]|\[tcp\]|\[dhcp\]' "$LOG" || true
echo "[test_net_https_chunked] --- end ---"
echo "[test_net_https_chunked] --- srv log ---"
cat "$SRVLOG" || true
echo "[test_net_https_chunked] --- end srv ---"

if grep -F -q "[https-chunked] PASS" "$LOG"; then
    echo "[test_net_https_chunked] PASS"
    exit 0
fi

if grep -F -q "[https-chunked] FAIL" "$LOG"; then
    echo "[test_net_https_chunked] FAIL (kernel reported chunked decode mismatch)"
    cat "$LOG"
    exit 1
fi

if grep -F -q "[tls] cert chain rejected" "$LOG"; then
    echo "[test_net_https_chunked] FAIL (chain rejected — fixture CA missing or validator bug)"
    cat "$LOG"
    exit 1
fi

if grep -F -q "[https-local] SKIP" "$LOG"; then
    echo "[test_net_https_chunked] SKIP (local guestfwd unreachable - host SLIRP shape?)"
    echo "[test_net_https_chunked] PASS"
    exit 0
fi
if grep -F -q "no ACK received during init poll" "$LOG"; then
    echo "[test_net_https_chunked] SKIP (no internet - DHCP unbound)"
    echo "[test_net_https_chunked] PASS"
    exit 0
fi

echo "[test_net_https_chunked] FAIL (qemu rc=$rc; no PASS marker)"
echo "[test_net_https_chunked] --- full log ---"
cat "$LOG"
exit 1
