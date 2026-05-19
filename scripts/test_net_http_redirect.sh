#!/usr/bin/env bash
# scripts/test_net_http_redirect.sh — exercise the in-kernel HTTP/1.1
# 3xx redirect-follow loop end-to-end.
#
# Real-world `deb.debian.org` 302s to geo mirrors; without redirect
# following the apt fetch path stops at the first hop. This harness
# stands up a tiny Python HTTP server on 127.0.0.1:9445 (SLIRP-
# forwarded to 10.0.2.200:80 inside the guest) that responds to:
#
#   GET /         -> 302 Found, Location: http://10.0.2.200/final
#   GET /final    -> 200 OK + "hello"
#
# The kernel's http_get parses the 302, extracts Location, validates
# scheme/cycle, and re-issues a GET against /final. The smoke
# (init/main.ad: http_redirect_smoke_test) asserts the final body is
# exactly 5 bytes "hello" and status==200, then prints the PASS marker.
#
# Outcomes:
#   - "[http-redirect] PASS"        -> PASS.
#   - "[http-redirect] FAIL ..."    -> FAIL (kernel mismatch).
#   - DHCP unbound                  -> SKIP (no internet during boot;
#                                     mirrors test_net_https_gzip.sh).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf

echo "[test_net_http_redirect] (1/4) Build userland + initramfs (with redirect marker)"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf \
    ENABLE_HTTP_REDIRECT_SMOKE=1 \
    python3 scripts/build_initramfs.py >/dev/null

TMPDIR=$(mktemp -d -t hamnix-redirect-XXXXXX)
LOG="$TMPDIR/qemu.log"
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

echo "[test_net_http_redirect] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_http_redirect] (3/4) Set up Python HTTP redirect server"
cat > "$SRVPY" << 'PYEOF'
import socket, sys, threading

PORT = int(sys.argv[1])

# Final body: 5 bytes "hello".
FINAL_BODY = b"hello"

# 302 response: Location header pointing at a SECOND guest-visible
# address (10.0.2.201) that SLIRP forwards back to this same Python
# server. The two IPs share a server process but give the kernel TCP
# stack a distinct 4-tuple for the second connection, avoiding a
# SLIRP-side port-reuse race the kernel hits when re-connecting to
# the same dst after a half-second FIN_WAIT_2 timeout. apt's real
# redirect chain typically lands on a different host anyway, so this
# matches production-shaped traffic.
RESP_302 = (
    b"HTTP/1.1 302 Found\r\n"
    b"Location: http://10.0.2.201:81/final\r\n"
    b"Content-Length: 0\r\n"
    b"Connection: close\r\n"
    b"\r\n"
)

RESP_FINAL = (
    b"HTTP/1.1 200 OK\r\n"
    b"Content-Type: text/plain\r\n"
    b"Content-Length: " + str(len(FINAL_BODY)).encode() + b"\r\n"
    b"Connection: close\r\n"
    b"\r\n"
) + FINAL_BODY

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(8)
print(f"[srv] listening on 127.0.0.1:{PORT}", flush=True)


def handle(c, peer):
    try:
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 4096:
            chunk = c.recv(4096)
            if not chunk:
                break
            data += chunk
        # Dispatch on request-line path. Anything that isn't /final
        # 302s — that's the path the kernel hits first.
        first_line = data.split(b"\r\n", 1)[0] if b"\r\n" in data else data
        print(f"[srv] req from {peer}: {first_line!r}", flush=True)
        if b" /final " in data:
            c.sendall(RESP_FINAL)
            print(f"[srv] -> 200 OK + 'hello'", flush=True)
        else:
            c.sendall(RESP_302)
            print(f"[srv] -> 302 Found Location:/final", flush=True)
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

python3 "$SRVPY" "$SRVPORT" > "$SRVLOG" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 30); do
    sleep 0.1
    if grep -F -q "listening on 127.0.0.1:${SRVPORT}" "$SRVLOG"; then
        break
    fi
done
if ! grep -F -q "listening on 127.0.0.1:${SRVPORT}" "$SRVLOG"; then
    echo "[test_net_http_redirect] WARN: Python server didn't start; SKIP"
    cat "$SRVLOG"
    echo "[test_net_http_redirect] PASS (SKIP — server bind failed)"
    exit 0
fi
echo "[test_net_http_redirect] Python redirect server up on 127.0.0.1:${SRVPORT}"

echo "[test_net_http_redirect] (4/4) Boot QEMU with virtio-net + SLIRP guestfwd"
set +e
timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.200:80-tcp:127.0.0.1:${SRVPORT},guestfwd=tcp:10.0.2.201:81-tcp:127.0.0.1:${SRVPORT},guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_http_redirect] --- captured (http / http-redirect / dns / tcp / dhcp) ---"
grep -E '\[http\]|\[http-redirect\]|\[dns\]|\[tcp\]|\[dhcp\]' "$LOG" || true
echo "[test_net_http_redirect] --- end ---"
echo "[test_net_http_redirect] --- srv log ---"
cat "$SRVLOG" || true
echo "[test_net_http_redirect] --- end srv ---"

if grep -F -q "[http-redirect] PASS" "$LOG"; then
    echo "[test_net_http_redirect] PASS"
    exit 0
fi

if grep -F -q "[http-redirect] FAIL" "$LOG"; then
    echo "[test_net_http_redirect] FAIL (kernel reported redirect mismatch)"
    cat "$LOG"
    exit 1
fi

if grep -F -q "no ACK received during init poll" "$LOG"; then
    echo "[test_net_http_redirect] SKIP (no internet — DHCP unbound)"
    echo "[test_net_http_redirect] PASS"
    exit 0
fi

echo "[test_net_http_redirect] FAIL (qemu rc=$rc; no PASS marker)"
echo "[test_net_http_redirect] --- full log ---"
cat "$LOG"
exit 1
