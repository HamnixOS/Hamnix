#!/usr/bin/env bash
# scripts/test_srvtest.sh — server-socket triple (bind/listen/accept +
# getsockname/getpeername) end-to-end over the Linux ABI.
#
# Proves the SERVER side of the Linux-ABI socket family — the headline
# "boots to a shell" -> "runs sshd/nginx" gap — works end to end and
# ENTIRELY in-guest over the 127.0.0.1 loopback (no SLIRP guestfwd for
# the test traffic itself, no host driver). A single fixture
# (tests/u-binary/src/srvtest) forks into a server
# (socket/bind(127.0.0.1:0)/listen/accept) and a client
# (socket/connect), exchanges "ping"/"pong", and checks that
# getsockname() on the listener + getpeername() on the accepted fd
# report the right 127.0.0.1:<port>.
#
# Pipeline (mirrors test_u_socket.sh — the fixture is exec'd FROM hamsh,
# not loaded as raw /init, so musl's _start gets a proper argv/auxv
# stack):
#   1. Build tests/u-binary/src/srvtest -> tests/u-binary/u_srvtest
#      (musl static-PIE, ELFOSABI_LINUX), embedded at /bin/u_srvtest.
#   2. Boot Hamnix with /init=hamsh; drive hamsh to exec u_srvtest.
#   3. Grep the markers off the serial log.
#
# Required markers (all must appear, no FAIL line):
#   "srvtest: listen port="
#   "srvtest: accept connfd="
#   "srvtest: peer=127.0.0.1:"
#   "srvtest: server got=ping"
#   "srvtest: client got=pong"
#   "srvtest: PASS"
#
# REQUIRES musl-gcc on the host. Skips quietly (exit 0) if it isn't
# installed so CI without the toolchain still passes.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

if ! command -v musl-gcc >/dev/null 2>&1; then
    echo "[test_srvtest] SKIP: musl-gcc not installed."
    echo "    apt-get install -y musl-tools  # (needs sudo)"
    echo "[test_srvtest] PASS"
    exit 0
fi

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
UBIN=tests/u-binary/u_srvtest

echo "[test_srvtest] (1/4) Build srvtest fixture (musl static-PIE)"
make -C tests/u-binary/src/srvtest install >/dev/null
if [ ! -f "$UBIN" ]; then
    echo "[test_srvtest] FAIL: $UBIN not built"
    exit 1
fi

echo "[test_srvtest] (2/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null

echo "[test_srvtest] (3/4) Swap /init = hamsh + embed u_srvtest; rebuild kernel"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_srvtest] (4/4) Boot QEMU; exec u_srvtest from hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
# The guestfwd echo target is REQUIRED so init/main.ad's net_smoke_test
# completes fast and boot reaches the hamsh prompt (same as
# test_u_socket.sh / test_net_tcp.sh). The srvtest traffic itself never
# touches it — it's pure 127.0.0.1 loopback inside the guest.
(
    sleep 60
    printf 'u_srvtest\n'
    sleep 30
    printf 'exit\n'
    sleep 2
) | timeout 240s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 2 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_srvtest] --- captured (srvtest) ---"
grep -E 'srvtest:' "$LOG" || true
echo "[test_srvtest] --- end ---"

if grep -F -q "srvtest: FAIL" "$LOG"; then
    echo "[test_srvtest] FAIL: fixture emitted a FAIL line"
    tail -n 80 "$LOG"
    exit 1
fi

need=(
    "srvtest: listen port="
    "srvtest: accept connfd="
    "srvtest: peer=127.0.0.1:"
    "srvtest: server got=ping"
    "srvtest: client got=pong"
    "srvtest: PASS"
)
missing=0
for m in "${need[@]}"; do
    if grep -F -q "$m" "$LOG"; then
        echo "[test_srvtest] OK: $m"
    else
        echo "[test_srvtest] MISS: $m"
        missing=1
    fi
done

if [ "$missing" -eq 0 ]; then
    echo "[test_srvtest] PASS (bind/listen/accept + getsockname/getpeername e2e)"
    exit 0
fi

echo "[test_srvtest] FAIL (qemu rc=$rc)"
echo "[test_srvtest] --- full log tail ---"
tail -n 120 "$LOG"
exit 1
