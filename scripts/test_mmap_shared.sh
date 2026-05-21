#!/usr/bin/env bash
# scripts/test_mmap_shared.sh — §1 cross-process MAP_SHARED coherence.
#
# Boots Hamnix with /bin/u_mmap_shared embedded and drives hamsh to
# exec it. u_mmap_shared is a host-built, static, OSABI=Linux x86_64
# ELF that exercises genuine MAP_SHARED memory sharing across a fork
# boundary (mm/vma.ad::vma_fork_copy's is_shared path +
# fs/elf.ad::vm_share_range):
#
#   For each of 6 iterations: mmap a 2-page MAP_SHARED|ANON region,
#   write a parent handshake value, fork(). The child verifies it can
#   SEE the parent's pre-fork write through the shared frame, then
#   overwrites both pages with a child sentinel and exits. The parent
#   wait4()s, then reads both pages back — under MAP_SHARED they MUST
#   now hold the CHILD's sentinel (the child's write landed in the
#   SAME physical frame). If the parent still sees its own handshake
#   the region was silently treated as MAP_PRIVATE — the bug §1 fixes.
#
# PASS = the serial log shows "MS: start", a "MS: iter ok" per
# iteration, "MS: PASS", and NO "MS: FAIL" line / CPU trap.
#
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/mmap_shared.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_mmap_shared
ensure_ubin_or_skip test_mmap_shared u_mmap_shared mmap_shared

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_mmap_shared] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_mmap_shared] (2/4) Swap /init = $HAMSH_ELF + embed u_mmap_shared"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_mmap_shared] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_mmap_shared] (4/4) Boot QEMU + run /bin/u_mmap_shared via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "u_mmap_shared" 20 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_mmap_shared] --- captured output ---"
cat "$LOG"
echo "[test_mmap_shared] --- end output ---"

fail=0

if grep -F -q "MS: start" "$LOG"; then
    echo "[test_mmap_shared] OK: fixture ran"
else
    echo "[test_mmap_shared] MISS: fixture banner absent"
    fail=1
fi

iters=6
ok_count=$(grep -F -c "MS: iter ok" "$LOG" || true)
if [ "$ok_count" -ge "$iters" ]; then
    echo "[test_mmap_shared] OK: all $iters iterations completed (iter ok x$ok_count)"
else
    echo "[test_mmap_shared] MISS: only $ok_count/$iters iterations completed"
    fail=1
fi

# A FAIL line means the share was broken (parent did not see the
# child's write, or the child did not see the parent's), or an
# mmap / fork / munmap returned an error.
if grep -F -q "MS: FAIL" "$LOG"; then
    echo "[test_mmap_shared] FAIL: fixture reported a coherence/syscall failure"
    grep -F "MS: FAIL" "$LOG" || true
    fail=1
fi

if grep -F -q "MS: PASS" "$LOG"; then
    echo "[test_mmap_shared] OK: fixture reached PASS"
else
    echo "[test_mmap_shared] MISS: PASS banner absent"
    fail=1
fi

if grep -F -q "[trap-diag] vec=" "$LOG"; then
    echo "[test_mmap_shared] DIAG: kernel reported a CPU exception"
    grep -F "[trap-diag] vec=" "$LOG" | head -6 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_mmap_shared] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_mmap_shared] PASS -- MAP_SHARED memory is genuinely shared across fork"
