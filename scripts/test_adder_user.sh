#!/usr/bin/env bash
# scripts/test_hamnix_user.sh - end-to-end verification that the
# `x86_64-adder-user` compiler target produces a userspace ELF the
# kernel actually loads, runs, and gets useful output from.
#
# Pipeline (each step is independent and re-runs cheaply):
#   1. Compile user/hello.ad -> build/user/hello.elf via the new target.
#   2. Regenerate fs/initramfs_blob.S with INIT_ELF pointing at hello.elf
#      so the cpio archive's /init is the Hamnix-compiled binary.
#   3. Rebuild the kernel image (init/main.ad -> build/hamnix-kernel.elf).
#   4. Boot it under QEMU and capture the serial output.
#   5. Grep the serial log for the hello.ad banner.
#
# Exits non-zero if the banner doesn't appear within the QEMU window.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

mkdir -p build/user
ELF=build/hamnix-kernel.elf
# Use a distinct stem (`pyhello.elf`) so we don't collide with the
# hand-written user/hello.S that scripts/build_user.sh ships as the
# hello cpio entry (referenced by /init's SYS_EXECVE path).
HELLO_ELF=build/user/pyhello.elf
BANNER="[hello.ad] Hamnix user-mode banner from"

echo "[test_hamnix_user] (1/5) Compile user/hello.ad -> $HELLO_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    user/hello.ad \
    -o "$HELLO_ELF"

echo "[test_hamnix_user] (2/5) Regenerate initramfs with /init = hello.elf"
INIT_ELF="$HELLO_ELF" python3 scripts/build_initramfs.py

echo "[test_hamnix_user] (3/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_hamnix_user] (4/5) Boot in QEMU and capture serial (10s)"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
set +e
timeout 10s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

# timeout(1) returns 124 if it killed QEMU after the time window. For
# this test that's still a successful run — the user binary should
# have printed its banner well before the 10 s mark and then either
# exited cleanly (kernel halts) or wedged in HLT.
echo "[test_hamnix_user] (raw output) ----"
cat "$LOG"
echo "[test_hamnix_user] (raw output end) ----"

echo "[test_hamnix_user] (5/5) Grep for banner: '$BANNER'"
if grep -F -q "$BANNER" "$LOG"; then
    echo "[test_hamnix_user] PASS: hello.ad banner found in serial output."
    # Restore the default /init (user/init.S) so a follow-up
    # `bash scripts/run_x86_bare.sh` works without surprises.
    INIT_ELF="build/user/init.elf" python3 scripts/build_initramfs.py >/dev/null
    exit 0
fi

echo "[test_hamnix_user] FAIL: banner not found in serial log."
echo "[test_hamnix_user] QEMU rc=$rc"
INIT_ELF="build/user/init.elf" python3 scripts/build_initramfs.py >/dev/null
exit 1
