#!/usr/bin/env bash
# scripts/test_virtio9p.sh — virtio-9p (9P-over-virtio-PCI) end-to-end test.
#
# Boots the kernel once with /etc/v9p-test planted (ENABLE_V9P_TEST=1)
# and a QEMU virtio-9p-pci device attached, exporting a host directory
# (mount_tag=hamshare) that holds a known file hello.txt. init/main.ad at
# boot:37.v9p calls v9p_e2e_selftest() (init/main.ad), which drives the
# real virtio-9p client (drivers/virtio/virtio_9p.ad):
#
#   * finds the virtio-9p-pci device (1AF4:1009 transitional / 1AF4:1049
#     modern), runs the modern virtio-1.0 init handshake
#     (drivers/virtio/virtio_modern.ad), and sets up the request virtqueue
#     (reusing the same drivers/virtio/virtio_ring.ad split-virtqueue that
#     backs virtio-blk),
#   * runs the 9P2000 handshake over that virtqueue —
#     Tversion/Tattach/Twalk/Topen/Tread/Tclunk — using the existing
#     lib/9p/9p.ad wire codec,
#   * enumerates the export root (Tread of the packed Stat stream),
#   * walks to hello.txt, opens it read-only, reads it, and byte-compares
#     the 11 marker bytes "v9p_marker\n" exactly.
#
# A PASS proves a real virtio-9p transport can mount a QEMU host-shared
# directory and read files byte-exact — a native Plan 9 9P transport.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [v9p] PASS
# Fail marker:  [v9p] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_virtio9p] (1/4) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_virtio9p] (2/4) Build kernel with /etc/v9p-test marker"
INIT_ELF=build/user/init.elf ENABLE_V9P_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_virtio9p] (3/4) Mint the host 9P export with a known hello.txt"
SHARE=$(mktemp -d --suffix=.v9p-share)
# 11 bytes: "v9p_marker\n" — the self-test asserts this byte-exact.
printf 'v9p_marker\n' > "$SHARE/hello.txt"
# A second file so the root enumeration sees >=1 entry even if QEMU's
# 9pfs orders hello.txt unexpectedly; harmless extra dirent.
printf 'second\n' > "$SHARE/note.txt"

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up share/log.
trap 'rm -rf "$LOG" "$SHARE"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_virtio9p] (4/4) Boot QEMU with -device virtio-9p-pci (mount_tag=hamshare)"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -fsdev local,id=fsdev0,path="$SHARE",security_model=none \
    -device virtio-9p-pci,fsdev=fsdev0,mount_tag=hamshare \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_virtio9p] --- captured (v9p lines) ---"
grep -E '\[v9p\]' "$LOG" || true
echo "[test_virtio9p] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_virtio9p] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[v9p] FAIL" "$LOG"; then
    echo "[test_virtio9p] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[v9p] self-test reported FAIL" "$LOG"; then
    echo "[test_virtio9p] FAIL: self-test returned non-zero" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_virtio9p] PASS: $label"
    else
        echo "[test_virtio9p] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"               "[v9p] self-test start"
check "device attached + 9P up"     "[v9p] device attached + 9P session up"
check "root enumerated"             "[v9p] root entries="
check "hello.txt verified"          "[v9p] hello.txt content verified byte-exact"
check "v9p self-test PASS"          "[v9p] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_virtio9p] FAIL"
    exit 1
fi

echo "[test_virtio9p] PASS — virtio-9p mounted a QEMU host export, ran the 9P2000 attach/walk/open/read handshake over the request virtqueue, enumerated the root, and read hello.txt byte-exact"
