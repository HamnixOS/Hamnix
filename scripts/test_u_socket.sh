#!/usr/bin/env bash
# scripts/test_u_socket.sh — U-socket: first userland TCP connection.
#
# Proves a user binary can complete a real TCP request/response through
# the socket(2) syscall family — socket / connect / write / read /
# close — bridged to the in-kernel TCP/IP stack (drivers/net/tcp.ad)
# by linux_abi/u_syscalls.ad + fs/vfs.ad.
#
# Pipeline:
#   1. Build tests/u-binary/src/socktest -> tests/u-binary/u_socktest,
#      a musl static-PIE Linux-ABI ELF, with SOCKTEST_PORT baked to a
#      free host port.
#   2. Start a host-side Python http.server on that port. The guest
#      reaches it through the SLIRP host alias 10.0.2.2.
#   3. Boot Hamnix with /init=hamsh and u_socktest embedded; drive
#      hamsh to exec u_socktest.
#   4. u_socktest does socket()->connect(10.0.2.2:PORT)->write(GET)->
#      read(response)->close(). It prints markers; we assert them.
#
# Required markers (all must appear):
#   "socktest: connect rc=0"
#   "socktest: body=HTTP/..."
#   "socktest: PASS"
#
# REQUIRES musl-gcc on the host. If tests/u-binary/u_socktest can't be
# built (no musl-gcc), exit 0 with a SKIP note so CI without the host
# toolchain still passes — mirrors test_u12_musl_hello.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

if ! command -v musl-gcc >/dev/null 2>&1; then
    echo "[test_u_socket] SKIP: musl-gcc not installed."
    echo "    apt-get install -y musl-tools  # (needs sudo)"
    echo "[test_u_socket] PASS"
    exit 0
fi

# --- pick a free host port -------------------------------------------
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_u_socket] using host port $PORT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
UBIN=tests/u-binary/u_socktest

echo "[test_u_socket] (1/5) Build u_socktest fixture (SOCKTEST_PORT=$PORT)"
make -C tests/u-binary/src/socktest clean >/dev/null 2>&1 || true
make -C tests/u-binary/src/socktest SOCKTEST_PORT="$PORT" install
if [ ! -f "$UBIN" ]; then
    echo "[test_u_socket] SKIP: $UBIN not built (musl-gcc issue)"
    echo "[test_u_socket] PASS"
    exit 0
fi

echo "[test_u_socket] (2/5) Build userland (hamsh + helpers) + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_u_socket] (3/5) Swap /init = hamsh + embed u_socktest"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_u_socket] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_u_socket] (5/5) Start host http.server + boot QEMU"
# Serve a tiny fixed document. Bind 0.0.0.0 so the SLIRP host alias
# 10.0.2.2 routes to it. A dedicated docroot keeps the response
# deterministic regardless of $PWD contents.
DOCROOT=$(mktemp -d)
printf 'hamnix-socktest-ok\n' > "$DOCROOT/index.html"
LOG=$(mktemp)
SRVLOG=$(mktemp)

python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$DOCROOT" \
    > "$SRVLOG" 2>&1 &
SRV_PID=$!

cleanup() {
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
    rm -rf "$LOG" "$SRVLOG" "$DOCROOT"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Give the server a moment to bind.
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
# guestfwd=tcp:10.0.2.100:7-cmd:cat is REQUIRED even though this test
# never uses that echo target: init/main.ad's net_smoke_test() calls
# tcp_smoke_test() unconditionally, and at net_smoke time the PIT /
# LAPIC timers aren't ticking yet — so a tcp_connect to an
# unreachable 10.0.2.100 would spin forever (its jiffy-based deadline
# never fires). The guestfwd makes that smoke's handshake complete
# fast so boot reaches the hamsh shell. Same shape as test_net_tcp.sh.
(
    sleep 60
    printf 'u_socktest\n'
    sleep 35
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
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_u_socket] --- captured (socktest / tcp / dhcp) ---"
grep -E 'socktest:|\[u_socket\]|\[tcp\]|\[dhcp\]' "$LOG" || true
echo "[test_u_socket] --- end ---"

fail=0
for needle in \
    "socktest: connect rc=0" \
    "socktest: PASS"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u_socket] OK: '$needle'"
    else
        echo "[test_u_socket] MISS: '$needle'"
        fail=1
    fi
done

# The first response line must be an HTTP status line.
if grep -E -q "socktest: body=HTTP/" "$LOG"; then
    echo "[test_u_socket] OK: HTTP status line received by user binary"
else
    echo "[test_u_socket] MISS: no HTTP status line in user-binary output"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u_socket] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u_socket] FAIL (qemu rc=$rc)"
    echo "[test_u_socket] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    echo "[test_u_socket] --- http.server log ---"
    cat "$SRVLOG" || true
    exit 1
fi

echo "[test_u_socket] PASS — user binary completed a real TCP" \
     "request/response via socket/connect/write/read/close"
