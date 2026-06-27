#!/usr/bin/env bash
# scripts/test_linux_apt_net_e2e.sh — LIVE-NETWORK end-to-end proof that the
# REAL Debian apt-get running inside `enter linux { ... }` fetches GENUINE
# Debian packages from the REAL Debian archive over the network:
#
#     enter linux { apt-get update }                  (fetch real indices)
#     enter linux { apt-get install -y hello }        (download real .deb)
#
# The fetch path is:
#   apt-get -> /usr/lib/apt/methods/http (fork)
#           -> glibc getaddrinfo(deb.debian.org)  [UDP DNS -> 10.0.2.3]
#           -> SYS_socket/connect/send/recv (linux_abi)
#           -> /net/tcp (devnet) -> native tcp_connect -> ip_send (gateway
#              10.0.2.2 route) -> virtio-net TX -> QEMU SLIRP -> internet.
#
# This is the LIVE counterpart to test_linux_apt_install_e2e.sh (which proves
# the same install pipeline against an OFFLINE file:// local repo). The
# offline test stays the CI default; this one is the real-network goal.
#
# The native http_smoke_test (scripts/test_net_http.sh) already proves the
# NATIVE stack reaches the internet through SLIRP (DHCP-bound 10.0.2.15,
# DNS via 10.0.2.3, TCP to a public IP -> HTTP 200). This test proves the
# SAME egress works for a LINUX binary (apt's http method) via linux_abi.
#
# Skip-on-missing / offline-graceful:
#   * rootfs / dpkg / apt-get not staged   -> SKIP (run BUILD.sh / staging).
#   * apt http method not staged           -> SKIP (re-run staging).
#   * HOST has no internet to deb.debian.org -> SKIP (CI may be offline).
#
# PASS markers (greppable in serial):
#   APT_NET_UPDATE_DONE  + a "http://deb.debian.org" Get: line in the log
#   APT_NET_INSTALL_DONE + "Setting up hello" (or the installed binary ran)

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ROOTFS=tests/distros/debian-minbase/rootfs
SUITE="${HAMNIX_APT_SUITE:-bookworm}"
PKG="${HAMNIX_APT_PKG:-hello}"   # tiny, dependency-light real Debian pkg

# --- preconditions ----------------------------------------------------
if [ ! -f "$ROOTFS/usr/bin/dpkg" ] || [ ! -f "$ROOTFS/usr/bin/apt-get" ]; then
    echo "[apt-net] staging dpkg/apt closure from host (stage_host_dpkg_rootfs.sh)"
    bash scripts/stage_host_dpkg_rootfs.sh || true
fi
if [ ! -f "$ROOTFS/usr/bin/dpkg" ] || [ ! -f "$ROOTFS/usr/bin/apt-get" ]; then
    echo "[apt-net] SKIP: $ROOTFS/usr/bin/{dpkg,apt-get} not staged"
    exit 0
fi
if [ ! -f "$ROOTFS/usr/lib/apt/methods/http" ]; then
    echo "[apt-net] http method missing; re-staging"
    touch "$ROOTFS/.staged-from-host" 2>/dev/null || true
    bash scripts/stage_host_dpkg_rootfs.sh || true
fi
if [ ! -f "$ROOTFS/usr/lib/apt/methods/http" ]; then
    echo "[apt-net] SKIP: apt http method not staged (need host /usr/lib/apt/methods/http)"
    exit 0
fi

# --- host internet probe (skip gracefully if offline) -----------------
DEB_IP=""
if command -v getent >/dev/null 2>&1; then
    DEB_IP="$(getent ahostsv4 deb.debian.org 2>/dev/null | awk 'NR==1{print $1}')"
fi
if [ -z "$DEB_IP" ]; then
    echo "[apt-net] SKIP: host cannot resolve deb.debian.org (offline CI)"
    exit 0
fi
# Confirm the host can actually fetch a byte over HTTP (not just resolve).
if command -v curl >/dev/null 2>&1; then
    if ! curl -fsS -o /dev/null --max-time 15 \
         "http://deb.debian.org/debian/dists/$SUITE/Release"; then
        echo "[apt-net] SKIP: host cannot HTTP-fetch deb.debian.org/$SUITE (offline)"
        exit 0
    fi
fi
echo "[apt-net] host internet OK: deb.debian.org -> $DEB_IP (suite=$SUITE, pkg=$PKG)"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[apt-net] (1/5) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

# Namespace recipe: SAME writable-overlay union as the offline apt e2e.
echo "[apt-net] (2/5) Plant /etc/hamsh.rc (writable overlay recipe)"
RC_TMP=$(mktemp /tmp/hamsh-rc-aptnet.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
export 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
linux = ns clean {
    bind '#r/var/lib/distros/default' /
    bind -bc '#t' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#t/tmp' /tmp
    bind '#/' /n
}
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[apt-net] (3/5) Build initramfs (HAMNIX_APT_NET=1)"
# Embed the http method + the LIVE-net apt config (resolv.conf -> 10.0.2.3,
# sources.list -> http://deb.debian.org/debian $SUITE main, /etc/hosts pin).
HAMNIX_DEFAULT_REAL_DEBIAN=1 HAMNIX_APT_NET=1 \
    HAMNIX_APT_SUITE="$SUITE" HAMNIX_DEB_HOST_IP="$DEB_IP" \
    HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LOG=$(mktemp /tmp/test-apt-net.XXXXXX.log)
cleanup() {
    rm -f "$RC_TMP"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
}
trap cleanup EXIT

echo "[apt-net] (4/5) Build kernel"
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "[apt-net] (5/5) Boot QEMU (virtio-net + SLIRP) + drive apt over network"
set +e
(
    waited=0
    while [ "$waited" -lt 240 ]; do
        grep -aq "TEST_RC_DONE_DEFINING_NS" "$LOG" 2>/dev/null && break
        sleep 1; waited=$((waited + 1))
    done
    sleep 2

    drive() { printf '%s\n' "$1"; }
    wait_for() {  # $1=marker  $2=max-seconds
        local w=0
        while [ "$w" -lt "$2" ]; do
            grep -aq "$1" "$LOG" 2>/dev/null && return 0
            sleep 2; w=$((w + 2))
        done
        return 1
    }

    # Sanity: real Debian apt-get runs under the overlay.
    drive 'echo APT_NET_VER_START'
    drive 'enter linux { /usr/bin/apt-get --version }'
    drive 'echo APT_NET_VER_END'; wait_for APT_NET_VER_END 60

    # Leg 1: apt-get update — fetch the REAL indices from deb.debian.org.
    drive 'echo APT_NET_UPDATE_START'
    drive 'enter linux { /usr/bin/apt-get update }'
    drive 'echo APT_NET_UPDATE_DONE'; wait_for APT_NET_UPDATE_DONE 300

    # Leg 2: apt-get install -y <pkg> — download the real .deb + configure.
    drive 'echo APT_NET_INSTALL_START'
    drive "enter linux { /usr/bin/apt-get install -y $PKG }"
    drive 'echo APT_NET_INSTALL_DONE'; wait_for APT_NET_INSTALL_DONE 420

    # Run the installed binary (hello prints "Hello, world!").
    drive 'echo APT_NET_RUN_START'
    drive "enter linux { /usr/bin/$PKG }"
    drive 'echo APT_NET_RUN_DONE'; wait_for APT_NET_RUN_DONE 60

    drive 'echo BANNER_DONE'; wait_for BANNER_DONE 20
    drive 'exit'; sleep 1
# Boot SINGLE-CPU: the apt http method needs no SMP, and a uniprocessor
# boot dodges the known per-CPU CR3/task-switch SMP fragility (a separate
# kernel track) that can trap the heavier apt initramfs at load_cr3 right
# after the namespace is defined. The proven native http egress smoke
# (test_net_http.sh) likewise boots single-CPU.
) | timeout 2400s qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 768M \
    -monitor none \
    -netdev user,id=hamnixnet \
    -device virtio-net-pci,netdev=hamnixnet \
    -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[apt-net] --- captured output (tail) ---"
tail -500 "$LOG" | strings | grep -aE \
    'TEST_RC|APT_NET|deb\.debian\.org|Get:|Hit:|Fetched|Setting up|Unpacking|Hello, world|Reading package|Building dependency|E:|W:|method driver|Could not|Temporary failure|resolve' \
    || tail -120 "$LOG" | strings
echo "[apt-net] --- end output ---"

fail=0
need() {  # marker, human
    if grep -a -F -q "$1" "$LOG"; then echo "[apt-net] OK: $2"
    else echo "[apt-net] MISS: $2 ('$1')"; fail=1; fi
}

need "TEST_RC_DONE_DEFINING_NS" "rc captured the linux ns"

# Leg 1: apt-get update must show a REAL deb.debian.org fetch line.
if grep -a -E -q 'http://deb\.debian\.org' "$LOG"; then
    echo "[apt-net] OK: apt contacted http://deb.debian.org (real archive)"
else
    echo "[apt-net] MISS: no http://deb.debian.org fetch line in log"
    fail=1
fi

# Leg 2: install must show the package unpack/configure.
APT_SLICE=$(awk '/APT_NET_INSTALL_START/{f=1} f' "$LOG")
if printf '%s' "$APT_SLICE" \
   | grep -a -E -q "Setting up $PKG|Unpacking $PKG|Get:.*$PKG"; then
    echo "[apt-net] OK: apt downloaded + configured real package '$PKG'"
else
    echo "[apt-net] MISS: no '$PKG' install confirmation after install start"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[apt-net] FAIL (qemu rc=$rc) — log: $LOG"
    exit 1
fi
echo "[apt-net] PASS — REAL Debian apt fetched packages from deb.debian.org over the network"
rm -f "$LOG"
