#!/usr/bin/env bash
# scripts/test_net_tcp_throughput.sh — sustained bulk-download
# throughput regression for the TCP receive path.
#
# Background: a real `apt update` against a live Debian mirror got
# all the way through TLS 1.3 + InRelease verify + the real Release
# fetch, then collapsed to ~600 B/s on the bulk index download and
# timed out. ~600 B/s is far slower than SLIRP emulation overhead
# explains — it was a real defect in Hamnix's TCP receive path:
#   * the SYN carried NO MSS option, so the peer fell back to the
#     RFC-mandated 536-byte default MSS, AND
#   * with no window scaling the per-RTT ceiling was tiny.
#
# This test boots the kernel with a guestfwd to a Python "blob
# server" that, on "PULL\n", streams 512 KiB back as fast as the
# socket drains. The kernel's tcp_throughput_smoke_test drains the
# whole blob via tcp_recv, times it off the free-running PIT, and
# computes bytes/second — asserting the rate clears a 50 KB/s floor.
#
# A regression in the receive path (tiny window, ACK-per-RTO stall,
# RX-ring drop storm) drops the measured rate well under the floor
# and the kernel prints `[tcp_tput] FAIL ...`.
#
# Required marker: `[tcp_tput] PASS`
# SKIP (treated as PASS): `[tcp_tput] SKIP` — guestfwd unusable.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_tcp_throughput] (1/4) Build userland + initramfs (with marker)"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf ENABLE_TCP_THROUGHPUT_SMOKE=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_tcp_throughput] (2/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_tcp_throughput] (3/4) Spawn fixture blob server on 127.0.0.1:9200"
TMPDIR=$(mktemp -d -t hamnix-tcp-tput-XXXXXX)
LOG="$TMPDIR/qemu.log"
SRVLOG="$TMPDIR/srv.log"
SRVPY="$TMPDIR/srv.py"
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

cat > "$SRVPY" <<'PYEOF'
import socket, sys

PORT = 9200
HOST = "127.0.0.1"
TARGET = 1024 * 1024           # must match tcp_throughput_smoke_test

# Deterministic-but-not-zero payload.
BLOB = bytes((i & 0xFF) for i in range(TARGET))

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((HOST, PORT))
s.listen(4)
s.settimeout(180)
print(f"[srv] listening on {HOST}:{PORT}", flush=True)

for connno in range(8):
    try:
        conn, addr = s.accept()
    except (socket.timeout, OSError) as exc:
        print(f"[srv] accept gave up ({exc!r})", flush=True)
        sys.exit(0)
    print(f"[srv] conn#{connno} from {addr}", flush=True)
    try:
        conn.settimeout(60)
        buf = b""
        while len(buf) < 5:
            chunk = conn.recv(5 - len(buf))
            if not chunk:
                break
            buf += chunk
        print(f"[srv] got {buf!r}", flush=True)
        if buf.startswith(b"PULL"):
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            conn.sendall(BLOB)
            print(f"[srv] sent {TARGET} bytes", flush=True)
            # Give the kernel time to drain before we close.
            import time
            time.sleep(1.0)
            conn.close()
            print("[srv] PULL served, exiting", flush=True)
            sys.exit(0)
    except Exception as exc:
        print(f"[srv] error: {exc!r}", flush=True)
    finally:
        try: conn.close()
        except Exception: pass
sys.exit(0)
PYEOF

python3 "$SRVPY" >"$SRVLOG" 2>&1 &
SRV_PID=$!

for _ in $(seq 1 20); do
    if grep -F -q "listening on 127.0.0.1:9200" "$SRVLOG" 2>/dev/null; then
        break
    fi
    sleep 0.05
done
if ! grep -F -q "listening on 127.0.0.1:9200" "$SRVLOG"; then
    echo "[test_net_tcp_throughput] FAIL: fixture server failed to bind"
    cat "$SRVLOG"
    exit 1
fi

echo "[test_net_tcp_throughput] (4/4) Boot QEMU with virtio-net + SLIRP guestfwd"
# guestfwd 10.0.2.100:7 keeps the boot-path tcp_smoke_test happy so
# the boot doesn't burn a retransmit-storm budget before our smoke.
set +e
timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.100:7-cmd:cat,guestfwd=tcp:10.0.2.203:9200-tcp:127.0.0.1:9200" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:58 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_tcp_throughput] --- captured (tcp_tput / tcp / dhcp) ---"
grep -E '\[tcp_tput\]|\[tcp\]|\[dhcp\]' "$LOG" || true
echo "[test_net_tcp_throughput] --- server log ---"
cat "$SRVLOG" || true
echo "[test_net_tcp_throughput] --- end ---"

if grep -F -q "[tcp_tput] PASS" "$LOG"; then
    echo "[test_net_tcp_throughput] PASS (sustained throughput above floor)"
    exit 0
fi

if grep -F -q "[tcp_tput] SKIP" "$LOG"; then
    echo "[test_net_tcp_throughput] PASS (SKIP — guestfwd unusable on this QEMU)"
    exit 0
fi

if grep -F -q "[tcp_tput] FAIL" "$LOG"; then
    echo "[test_net_tcp_throughput] FAIL (throughput collapsed below floor)"
    grep -E '\[tcp_tput\]' "$LOG" || true
    exit 1
fi

echo "[test_net_tcp_throughput] FAIL (qemu rc=$rc; smoke never reached)"
tail -80 "$LOG"
exit 1
