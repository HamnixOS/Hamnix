#!/usr/bin/env bash
# scripts/test_apt_inrelease_real.sh — OFFLINE repro for apt's OpenPGP
# `InRelease` verification against the GENUINE deb.debian.org archive.
#
# WHY THIS EXISTS
#
#   scripts/test_apt_inrelease.sh and test_apt_inrelease_sha512.sh
#   prove apt's OpenPGP verification against *synthetic*
#   gpg-clearsigned fixtures — and those pass. But verification of the
#   REAL Debian `InRelease` failed: a genuine Debian `InRelease` is not
#   signed by the primary archive keys, it is signed by the dedicated
#   `[S]` signing SUBKEYS (Tag 14 Public-Subkey packets) those primary
#   keys carry. lib/pgp's pgp_keyring_load used to skip Tag 14 packets,
#   so apt held NONE of the keys that actually signed the index, and
#   every real-Debian `InRelease` verification failed even though the
#   crypto was correct.
#
#   This is the same defect shape as the gzip cross-chunk bug: the
#   synthetic fixtures pass, the real-world data fails. This test is
#   the deterministic, offline reproduction of that real-world case.
#
# DESIGN — deterministic, no network per run:
#   1. scripts/build_realinrelease_img.py fetches the genuine
#      `InRelease` (deb.debian.org/debian/dists/bookworm/InRelease) and
#      the genuine `debian-archive-keyring.gpg` ONCE (cached under
#      build/cache/) and bakes both onto a virtio-blk ext4 disk image
#      build/realinrelease.img.
#   2. The kernel auto-mounts the ext4 disk at /ext.
#   3. tests/test_apt_inrelease_real.ad reads /ext/InRelease +
#      /ext/keyring.gpg and runs the SAME lib/pgp + lib/rsa
#      verification path apt's _verify_inrelease drives — asserting the
#      genuine InRelease verifies and a tampered copy is rejected.
#
# PASS criterion: "[inrel-real] PASS" in the serial log.
#
# If the real files cannot be fetched and are not cached, the test
# SKIPs (exit 0) — an offline box must not spuriously break CI. A
# genuine verification regression always FAILs.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_apt_inrelease_real.elf

echo "[test_apt_inrelease_real] (1/6) Fetch real InRelease + keyring, build ext4 disk image"
if ! python3 scripts/build_realinrelease_img.py; then
    echo "[test_apt_inrelease_real] SKIP: real InRelease/keyring unavailable (offline?)"
    exit 0
fi

echo "[test_apt_inrelease_real] (2/6) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_apt_inrelease_real] (3/6) Build tests/test_apt_inrelease_real.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_apt_inrelease_real.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_apt_inrelease_real] (4/6) Plant /init = hamsh + /bin/test_apt_inrelease_real"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_apt_inrelease_real] (5/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_apt_inrelease_real] (6/6) Boot QEMU with realinrelease.img as virtio-blk"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_apt_inrelease_real\n'
    # RSA-4096 modexp x several keys x several signature packets — give
    # the bit-by-bit bigint kernel room to run in the emulator.
    sleep 45
    printf 'exit\n'
    sleep 1
) | timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file=build/realinrelease.img,if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_apt_inrelease_real] --- captured output ---"
grep -E '\[inrel-real\]|TRAP:' "$LOG" || cat "$LOG"
echo "[test_apt_inrelease_real] --- end output ---"

fail=0

if grep -F -q "[inrel-real] start" "$LOG"; then
    echo "[test_apt_inrelease_real] OK: test binary ran"
else
    echo "[test_apt_inrelease_real] MISS: [inrel-real] start banner absent"
    fail=1
fi

if grep -F -q "[inrel-real] OK: genuine real-Debian InRelease verified" "$LOG"; then
    echo "[test_apt_inrelease_real] OK: genuine InRelease verified"
else
    echo "[test_apt_inrelease_real] MISS: genuine InRelease did not verify"
    fail=1
fi

if grep -F -q "[inrel-real] OK: tampered InRelease correctly rejected" "$LOG"; then
    echo "[test_apt_inrelease_real] OK: tampered InRelease rejected"
else
    echo "[test_apt_inrelease_real] MISS: tampered InRelease not rejected"
    fail=1
fi

if grep -F -q "[inrel-real] PASS" "$LOG"; then
    echo "[test_apt_inrelease_real] OK: reached PASS"
else
    echo "[test_apt_inrelease_real] MISS: PASS line absent"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_apt_inrelease_real] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_apt_inrelease_real] FAIL (qemu rc=$rc)"
    echo "[test_apt_inrelease_real] --- full kernel log (last 120 lines) ---"
    tail -n 120 "$LOG"
    exit 1
fi

echo "[test_apt_inrelease_real] PASS — apt's lib/pgp + lib/rsa verify the" \
     "GENUINE deb.debian.org InRelease (signed by archive signing" \
     "subkeys) and reject a tampered copy"
