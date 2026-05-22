#!/usr/bin/env bash
# scripts/test_u_server.sh — U-socket V1: first userland TCP server.
#
# Proves a native-Adder user binary can run a TCP *server*: socket() /
# bind() / listen() / accept() one connection, read() the request,
# write() a response, close() — the server-side socket syscalls bridged
# to the in-kernel TCP stack (drivers/net/tcp.ad) by _u_bind / _u_listen
# / _u_accept in linux_abi/u_syscalls.ad.
#
# Pipeline:
#   1. Build user/u_server.ad -> build/user/u_server.elf (native Adder).
#   2. Embed it as /init so it runs straight after kernel bring-up.
#   3. Boot QEMU with SLIRP hostfwd=tcp::HOSTPORT-:7000 — an inbound
#      connection to the host's HOSTPORT becomes a SYN on the guest's
#      port 7000 where u_server listens.
#   4. After the guest prints "[u_server] listening", the host connects
#      to HOSTPORT, sends a request line, and reads the response. We
#      assert the server's markers AND that the host got the exact
#      reply ("hamnix-userserver-ok") back over TCP.
#
# Why hostfwd (host->guest) rather than a guest-loopback test: SLIRP's
# hostfwd is the standard way to drive an inbound connection to a guest
# listener, and it exercises the full server path (LISTEN -> SYN_RCVD ->
# ESTABLISHED -> accept) against a real external peer. The guestfwd
# below is unrelated — init/main.ad's boot-time net_smoke_test() opens
# an active connection to 10.0.2.100:7, and the guestfwd makes that
# smoke's handshake complete fast so boot reaches /init promptly (same
# rationale as test_u_socket.sh).
#
# Required markers (server side, all must appear):
#   "[u_server] listening"
#   "[u_server] accepted connection"
#   "[u_server] request received"
#   "[u_server] PASS"
# AND the host-side connector must read back "hamnix-userserver-ok".

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
SERVER_ELF=build/user/u_server.elf

# --- pick a free host port -------------------------------------------
HOST_PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_u_server] host port $HOST_PORT -> guest port 7000"

echo "[test_u_server] (1/3) Build userland (incl. u_server)"
bash scripts/build_user.sh >/dev/null
if [ ! -f "$SERVER_ELF" ]; then
    echo "[test_u_server] FAIL: $SERVER_ELF not built"
    exit 1
fi

echo "[test_u_server] (2/3) Embed u_server as /init + rebuild kernel"
INIT_ELF="$SERVER_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_u_server] (3/3) Boot QEMU with hostfwd tcp::${HOST_PORT}-:7000"
LOG=$(mktemp)
CLIENTLOG=$(mktemp)
trap 'rm -f "$LOG" "$CLIENTLOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# Background host-side connector. SLIRP's hostfwd accepts (and buffers)
# a host-side TCP connection immediately — long before the guest has
# even booted — so a naive "connect early, retry" loop would send its
# request + FIN into SLIRP's buffer and time out before u_server ever
# reaches accept(). To avoid that race the connector first waits for
# the guest to print "[u_server] listening" into the kernel log, THEN
# opens a single connection with a generous recv timeout and holds it
# open until the server sends its response + closes.
(
    python3 - "$HOST_PORT" "$CLIENTLOG" "$LOG" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
out_path = sys.argv[2]
log_path = sys.argv[3]

# Wait for the guest's listener marker (up to ~150 s of boot).
listen_deadline = time.time() + 150
while time.time() < listen_deadline:
    try:
        with open(log_path, "r", errors="replace") as f:
            if "[u_server] listening" in f.read():
                break
    except OSError:
        pass
    time.sleep(1)

reply = b""
status = "no-connect"
# u_server's accept() blocks ~5 s; connect promptly once it's listening.
attempt_deadline = time.time() + 20
while time.time() < attempt_deadline:
    try:
        c = socket.socket()
        c.settimeout(15)
        c.connect(("127.0.0.1", port))
        c.sendall(b"hello-from-host\n")
        # Hold the connection open and read until the server sends its
        # one-line response and close()s its end (recv returns b"").
        chunks = []
        while True:
            try:
                b = c.recv(256)
            except socket.timeout:
                break
            if not b:
                break
            chunks.append(b)
        c.close()
        reply = b"".join(chunks)
        status = "ok"
        break
    except (ConnectionRefusedError, OSError):
        time.sleep(1)
        continue
with open(out_path, "wb") as f:
    f.write(b"status=" + status.encode() + b"\n")
    f.write(b"reply=" + reply + b"\n")
PY
) &
CLIENT_PID=$!

set +e
# u_server is /init: it runs after kernel bring-up, listens, accepts one
# connection, then returns -> box halts (no-reboot). 150 s is generous
# headroom over the ~60 s boot + accept window.
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,hostfwd=tcp::${HOST_PORT}-:7000,guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 2 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

wait "$CLIENT_PID" 2>/dev/null || true

echo "[test_u_server] --- captured (u_server / u_socket / tcp / dhcp) ---"
grep -E '\[u_server\]|\[u_socket\]|\[tcp\]|\[dhcp\]' "$LOG" || true
echo "[test_u_server] --- host connector ---"
cat "$CLIENTLOG" 2>/dev/null || echo "(no connector output)"
echo "[test_u_server] --- end ---"

fail=0
for needle in \
    "[u_server] listening" \
    "[u_server] accepted connection" \
    "[u_server] request received" \
    "[u_server] PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u_server] OK: '$needle'"
    else
        echo "[test_u_server] MISS: '$needle'"
        fail=1
    fi
done

# The host connector must have received the server's exact reply line.
if grep -F -q "reply=hamnix-userserver-ok" "$CLIENTLOG" 2>/dev/null; then
    echo "[test_u_server] OK: host received server response over TCP"
else
    echo "[test_u_server] MISS: host did not receive the server response"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u_server] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u_server] FAIL (qemu rc=$rc)"
    echo "[test_u_server] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi

echo "[test_u_server] PASS — native user binary bound a port, listened," \
     "accepted a TCP connection, and did request/response I/O"
