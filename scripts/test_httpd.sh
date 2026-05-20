#!/usr/bin/env bash
# scripts/test_httpd.sh — userland static-file HTTP/1.0 server.
#
# Proves user/httpd.ad serves real HTTP over the in-kernel TCP stack: a
# host curl gets correct 200/404/400 responses with the right
# Content-Length / Content-Type from a docroot baked into the cpio
# initramfs.
#
# Pipeline:
#   1. Build user/httpd.ad -> build/user/httpd.elf (native Adder).
#   2. Embed httpd as /init, AND plant a static-file docroot at
#      /var/www in the cpio initramfs (HAMNIX_HTTPD_DOCROOT=1 — see the
#      gated block in scripts/build_initramfs.py: it stages
#      /var/www/index.html and /var/www/hello.txt).
#   3. Rebuild the kernel image so the embedded initramfs is current.
#   4. Boot QEMU with SLIRP hostfwd=tcp::HOSTPORT-:8080 — an inbound
#      connection to the host's HOSTPORT becomes a SYN on the guest's
#      port 8080 where httpd listens.
#   5. After the guest prints "httpd: listening", the host issues four
#      HTTP/1.0 GETs over fresh connections (Connection: close):
#        GET /            -> 200, body is the index.html
#        GET /index.html  -> 200, same body
#        GET /hello.txt   -> 200, text/plain body
#        GET /nope.txt    -> 404
#        GET /../etc/x    -> 400 (path-escape rejected)
#      and asserts status + body + Content-Type for each.
#
# Why hostfwd (host->guest): SLIRP's hostfwd is the standard way to
# drive an inbound connection to a guest listener; it exercises the
# full server path (LISTEN -> SYN_RCVD -> ESTABLISHED -> accept)
# against a real external peer. The guestfwd is unrelated — it just
# makes init/main.ad's boot-time net_smoke_test() handshake complete
# fast so boot reaches /init promptly (same rationale as
# test_u_server.sh).
#
# Required markers (server side):
#   "httpd: listening"
#   "httpd: GET / -> 200"
#   "httpd: GET /hello.txt -> 200"
#   "httpd: GET /nope.txt -> 404"
# AND the host-side driver must observe the four HTTP responses.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HTTPD_ELF=build/user/httpd.elf

# --- pick a free host port -------------------------------------------
HOST_PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_httpd] host port $HOST_PORT -> guest port 8080"

echo "[test_httpd] (1/3) Build userland (incl. httpd)"
bash scripts/build_user.sh >/dev/null
if [ ! -f "$HTTPD_ELF" ]; then
    echo "[test_httpd] FAIL: $HTTPD_ELF not built"
    exit 1
fi

echo "[test_httpd] (2/3) Embed httpd as /init + stage /var/www docroot"
INIT_ELF="$HTTPD_ELF" HAMNIX_HTTPD_DOCROOT=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_httpd] (3/3) Boot QEMU with hostfwd tcp::${HOST_PORT}-:8080"
LOG=$(mktemp)
CLIENTLOG=$(mktemp)
trap 'rm -f "$LOG" "$CLIENTLOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# Background host-side HTTP driver. SLIRP's hostfwd accepts (and
# buffers) a host-side TCP connection immediately — long before the
# guest has booted — so the driver first waits for the guest's
# "httpd: listening" marker in the kernel log, THEN issues its GETs.
# httpd serves one connection at a time (Connection: close), so each
# request gets its own fresh socket.
(
    python3 - "$HOST_PORT" "$CLIENTLOG" "$LOG" <<'PY'
import socket, sys, time

port = int(sys.argv[1])
out_path = sys.argv[2]
log_path = sys.argv[3]

# Wait for the guest's listener marker (up to ~150 s of boot).
listen_deadline = time.time() + 150
listening = False
while time.time() < listen_deadline:
    try:
        with open(log_path, "r", errors="replace") as f:
            if "httpd: listening" in f.read():
                listening = True
                break
    except OSError:
        pass
    time.sleep(1)

results = []

def http_get(path):
    """One HTTP/1.0 GET over a fresh connection; returns (status, headers, body)."""
    c = socket.socket()
    c.settimeout(15)
    c.connect(("127.0.0.1", port))
    req = ("GET " + path + " HTTP/1.0\r\nHost: localhost\r\n"
           "Connection: close\r\n\r\n")
    c.sendall(req.encode())
    chunks = []
    while True:
        try:
            b = c.recv(4096)
        except socket.timeout:
            break
        if not b:
            break
        chunks.append(b)
    c.close()
    raw = b"".join(chunks)
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    status = lines[0].decode("latin-1") if lines else ""
    headers = {}
    for ln in lines[1:]:
        k, _, v = ln.partition(b":")
        headers[k.decode("latin-1").strip().lower()] = v.decode("latin-1").strip()
    return status, headers, body

def attempt(path, retries=8):
    """GET with a few retries — httpd's accept() may not be re-armed
    between the back-to-back requests yet."""
    last = None
    for _ in range(retries):
        try:
            return http_get(path)
        except (ConnectionRefusedError, OSError) as e:
            last = e
            time.sleep(1)
    raise last if last else RuntimeError("no attempt")

with open(out_path, "w") as f:
    if not listening:
        f.write("status=no-listen\n")
        sys.exit(0)
    try:
        for label, path in (("root", "/"),
                            ("index", "/index.html"),
                            ("txt", "/hello.txt"),
                            ("missing", "/nope.txt"),
                            ("escape", "/../etc/hostname")):
            st, hd, body = attempt(path)
            f.write("=== %s GET %s\n" % (label, path))
            f.write("status=%s\n" % st)
            f.write("content-type=%s\n" % hd.get("content-type", ""))
            f.write("content-length=%s\n" % hd.get("content-length", ""))
            f.write("bodylen=%d\n" % len(body))
            f.write("body=%s\n" % body.decode("latin-1").replace("\n", "\\n"))
        f.write("status=ok\n")
    except Exception as e:  # noqa: BLE001
        f.write("status=error\n")
        f.write("error=%r\n" % (e,))
PY
) &
CLIENT_PID=$!

set +e
# httpd is /init: it runs after kernel bring-up, listens, and serves
# connections forever. The host driver issues its GETs then exits; the
# guest keeps looping (accept blocks ~5 s per idle iteration) until the
# QEMU timeout fires. 220 s covers ~60 s boot + the request window.
timeout 240s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,hostfwd=tcp::${HOST_PORT}-:8080,guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 2 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

wait "$CLIENT_PID" 2>/dev/null || true

echo "[test_httpd] --- captured (httpd / u_socket / tcp / dhcp) ---"
grep -E 'httpd:|\[u_socket\]|\[tcp\]|\[dhcp\]' "$LOG" || true
echo "[test_httpd] --- host HTTP driver ---"
cat "$CLIENTLOG" 2>/dev/null || echo "(no driver output)"
echo "[test_httpd] --- end ---"

fail=0

# --- server-side markers ---------------------------------------------
for needle in \
    "httpd: listening" \
    "httpd: GET / -> 200" \
    "httpd: GET /hello.txt -> 200" \
    "httpd: GET /nope.txt -> 404"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_httpd] OK: server log '$needle'"
    else
        echo "[test_httpd] MISS: server log '$needle'"
        fail=1
    fi
done

# --- host-side HTTP assertions ---------------------------------------
assert_client() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$CLIENTLOG" 2>/dev/null; then
        echo "[test_httpd] OK: $label"
    else
        echo "[test_httpd] MISS: $label ('$needle')"
        fail=1
    fi
}

# A 200 for "/" with the index.html body + text/html content type.
assert_client "GET / returned 200"        "status=HTTP/1.0 200 OK"
assert_client "GET / body is index.html"  "Hamnix httpd"
assert_client "index.html is text/html"   "content-type=text/html"
# The .txt file: text/plain + the expected body.
assert_client ".txt is text/plain"        "content-type=text/plain"
assert_client ".txt body served"          "hello from hamnix httpd"
# Missing path -> 404.
assert_client "missing path -> 404"       "status=HTTP/1.0 404 Not Found"
# Path-escape attempt -> 400 (must NOT leak /etc/hostname).
assert_client ".. path -> 400"            "status=HTTP/1.0 400 Bad Request"

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_httpd] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_httpd] FAIL (qemu rc=$rc)"
    echo "[test_httpd] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi

echo "[test_httpd] PASS — userland httpd served static files over real" \
     "HTTP: correct 200/404/400 with right Content-Length/Content-Type"
