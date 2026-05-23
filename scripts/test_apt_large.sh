#!/usr/bin/env bash
# scripts/test_apt_large.sh — apt large-index regression: prove
# `apt update` handles a real-full-size-shaped Debian `main` index.
#
# This is the proof that the old fixed-RAM-buffer size limit is gone.
# The earlier apt buffered the whole compressed download AND the whole
# decompressed `Packages` index in 256 KiB BSS arenas — so it only ever
# worked against tiny fixture repos (a few stanzas, a few KiB) or a
# live mirror's small `contrib` component. A real Debian `main` index
# is multi-MB compressed and tens of MB decompressed; it did not fit.
#
# `apt update` now STREAMS the gz index: the compressed body is drained
# off the socket 64 KiB at a time, fed to the resumable gzip inflater
# 64 KiB at a time, and the decompressed bytes flow straight through an
# incremental RFC822-stanza counter + an incremental writer to
# /tmp/apt/Packages. Nothing holds the whole index — index size is
# bounded only by what apt keeps.
#
# This test fabricates a LARGE fixture: a `Packages` with several
# THOUSAND stanzas, multi-MB decompressed and well past the old caps
# both compressed and decompressed. A passing run proves:
#   * `apt update` streamed + inflated + counted the WHOLE index
#     (the stanza count matches the fixture's full stanza count —
#      far more than any 256 KiB buffer could ever have held);
#   * the persisted /tmp/apt/Packages cache holds the leading stanzas
#     and `apt show` resolves a package from that cache.
#
# Pipeline + NETWORKING NOTE are identical to scripts/test_apt_get.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# --- fixture sizing --------------------------------------------------
# N_STANZAS stanzas, each ~260 bytes of mostly-unique text. ~3 MB
# decompressed, several hundred KB gzipped — both far past the old
# 256 KiB caps, and the decompressed total is past the 512 KiB tmpfs
# /tmp/apt/Packages cache cap too, so the cache-truncation path is
# exercised as well.
N_STANZAS=12000
# Two packages we will `apt show`. The EARLY one is in the leading-
# mirror region (the first 512 KiB of decompressed index) and was the
# only thing the pre-sharding cache could resolve. The LATE one sits
# well past the leading-mirror cap and ONLY the sharded /tmp/apt/p/NNN
# cache can resolve it — that is the proof that the marquee
# `apt show <late-package>` works.
QUERY_IDX=7
QUERY_PKG="hampkg-0000${QUERY_IDX}"
QUERY_MARK="LARGEIDX_OK_MARKER"
QUERY_LATE_IDX=11500
QUERY_LATE_PKG="hampkg-${QUERY_LATE_IDX}"
QUERY_LATE_MARK="LARGEIDX_LATE_MARKER"

# --- pick a free host port -------------------------------------------
PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_apt_large] using host port $PORT"

echo "[test_apt_large] (1/6) Build userland (hamsh + apt + helpers) + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

if [ ! -x "build/user/apt.elf" ]; then
    echo "[test_apt_large] FAIL: build/user/apt.elf missing after build_user.sh"
    exit 1
fi

echo "[test_apt_large] (2/6) Fabricate LARGE fake Debian repo tree"
REPO_DIR=$(mktemp -d --tmpdir hamnix-apt-large-repo.XXXXXX)
DIST_DIR="$REPO_DIR/dists/stable"
BIN_DIR="$DIST_DIR/main/binary-amd64"
mkdir -p "$BIN_DIR"

cat > "$DIST_DIR/Release" <<EOF
Origin: Hamnix
Label: Hamnix
Suite: stable
Codename: stable
Architectures: amd64
Components: main
Description: Hamnix apt large-index test repository
EOF

# Generate a Packages file with N_STANZAS RFC822 stanzas. Each stanza
# carries a unique Package name + Description so the file does not
# compress away to nothing — a realistic shape for a real `main`.
PACKAGES_PLAIN="$REPO_DIR/Packages.plain"
python3 - "$PACKAGES_PLAIN" "$N_STANZAS" "$QUERY_IDX" "$QUERY_MARK" \
        "$QUERY_LATE_IDX" "$QUERY_LATE_MARK" <<'PY'
import sys
out_path = sys.argv[1]
n = int(sys.argv[2])
qidx = int(sys.argv[3])
qmark = sys.argv[4]
qlate_idx = int(sys.argv[5])
qlate_mark = sys.argv[6]
with open(out_path, "w") as f:
    for i in range(n):
        name = f"hampkg-{i:05d}"
        ver = f"{1 + i % 9}.{i % 100}.{i % 10}"
        desc = (f"Package number {i} in the Hamnix large-index fixture "
                f"with assorted unique filler text token-{i}-{i*7%100000}")
        if i == qidx:
            desc = f"{qmark} {desc}"
        if i == qlate_idx:
            desc = f"{qlate_mark} {desc}"
        f.write(f"Package: {name}\n")
        f.write(f"Version: {ver}\n")
        f.write("Architecture: amd64\n")
        f.write(f"Filename: pool/main/h/{name}/{name}_{ver}_amd64.deb\n")
        f.write(f"Size: {4096 + i}\n")
        f.write(f"SHA256: {i:064x}\n")
        f.write(f"Description: {desc}\n")
        f.write("\n")
PY

gzip -9 -c "$PACKAGES_PLAIN" > "$BIN_DIR/Packages.gz"
PLAIN_SZ=$(stat -c%s "$PACKAGES_PLAIN")
GZ_SZ=$(stat -c%s "$BIN_DIR/Packages.gz")
echo "[test_apt_large]   repo: $REPO_DIR"
echo "[test_apt_large]   Packages: $PLAIN_SZ bytes plain, $GZ_SZ bytes gz" \
     "($N_STANZAS stanzas)"
if [ "$PLAIN_SZ" -lt 262144 ]; then
    echo "[test_apt_large] FAIL: fixture decompressed size $PLAIN_SZ < old 256 KiB cap"
    echo "[test_apt_large]       — not a meaningful large-index test"
    exit 1
fi
if [ "$GZ_SZ" -lt 65536 ]; then
    echo "[test_apt_large] FAIL: fixture gz size $GZ_SZ < 64 KiB streaming chunk"
    echo "[test_apt_large]       — not a meaningful streaming test"
    exit 1
fi

echo "[test_apt_large] (3/6) Swap /init = hamsh in cpio initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_apt_large] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_apt_large] (5/6) Start host http.server + boot QEMU"
LOG=$(mktemp)
SRVLOG=$(mktemp)

python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$REPO_DIR" \
    > "$SRVLOG" 2>&1 &
SRV_PID=$!

cleanup() {
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
    rm -rf "$LOG" "$SRVLOG" "$REPO_DIR"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

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
(
    sleep 60
    printf '/bin/apt update http://10.0.2.2:%s stable\n' "$PORT"
    sleep 45
    printf 'echo APT_SHOW_START\n'
    printf '/bin/apt show %s\n' "$QUERY_PKG"
    sleep 8
    printf 'echo APT_SHOW_LATE_START\n'
    printf '/bin/apt show %s\n' "$QUERY_LATE_PKG"
    sleep 8
    printf 'echo APT_DONE\n'
    printf 'exit\n'
    sleep 2
) | timeout 400s qemu-system-x86_64 \
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

echo "[test_apt_large] --- captured (apt / APT_) ---"
grep -E 'apt-get:|apt-cache:|apt:|APT_|Package:|Version:' "$LOG" || true
echo "[test_apt_large] --- end ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_apt_large] OK: '$1'"
    else
        echo "[test_apt_large] MISS: '$1'"
        fail=1
    fi
}

# (a) `apt update` streamed the gz index — the streaming-path banner.
check "apt-get: streamed gz index ("

# (b) the streaming stanza counter counted ALL N_STANZAS stanzas. This
#     is the core proof: the count is far larger than any 256 KiB
#     buffer could have held, so the size limit is genuinely gone.
check "apt-get: fetched index, $N_STANZAS packages"

# (c) the decompressed index is bigger than the leading-mirror file
#     cap, so apt sharded the WHOLE index across /tmp/apt/p/NNN.
check "apt-get: cached "
check " shards across /tmp/apt/p/NNN — show/install resolve"
check "apt-get: note: leading /tmp/apt/Packages mirror capped at"

# (d) `apt show` resolved an EARLY package — sits inside the leading
#     mirror, the only case the pre-sharded cache could handle.
check "Package: $QUERY_PKG"
check "$QUERY_MARK"

# (e) `apt show` resolved a LATE package — sits well past the
#     leading mirror cap, ONLY the sharded cache can find it. This is
#     the marquee bit: a real Debian main has ~68k packages spanning
#     ~56 MiB; without the sharded cache the show/install paths could
#     not resolve anything past the first ~512 KiB of the index.
check "Package: $QUERY_LATE_PKG"
check "$QUERY_LATE_MARK"

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_apt_large] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_apt_large] FAIL (qemu rc=$rc)"
    echo "[test_apt_large] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    echo "[test_apt_large] --- http.server log ---"
    cat "$SRVLOG" || true
    exit 1
fi

echo "[test_apt_large] PASS — userland apt streamed a multi-MB Debian-main-" \
     "shaped index ($N_STANZAS stanzas), inflated + counted it incrementally" \
     "with no fixed-buffer size limit, and queries resolve from the cache"
