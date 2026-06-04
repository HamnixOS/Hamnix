#!/usr/bin/env bash
# scripts/test_keyring.sh — add_key(2)/request_key(2)/keyctl(2) round-trip
# verification.
#
# Proves the Linux-ABI kernel keyring syscalls (linux_abi/u_keyring.ad
# ukey_add_key / ukey_request_key / ukey_keyctl, dispatched from
# linux_abi/u_syscalls.ad at nr 248/249/250) are backed by a REAL per-process /
# per-user key store (ukey_serial / ukey_payload / ukey_link, keyed by key slot,
# special KEY_SPEC_PROCESS_KEYRING / KEY_SPEC_USER_KEYRING ids resolved to real
# keyring keys) instead of returning ENOSYS. The in-kernel keyring_selftest()
# (gated on the cpio marker /etc/keyring-test) runs the keyutils-shaped checks:
#   (1) add_key("user","test:key",P1) -> serial; KEYCTL_READ reads P1 byte-exact
#   (2) KEYCTL_UPDATE to P2, re-READ asserts P2 byte-exact
#   (3) request_key / KEYCTL_SEARCH find it; a bogus description -> ENOKEY
#   (4) KEYCTL_LINK to the user keyring + KEYCTL_UNLINK from the proc keyring
#   (5) KEYCTL_REVOKE then READ -> EKEYREVOKED; KEYCTL_CLEAR empties a keyring
# The selftest does all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_keyring] PASS   (kernel prints [keyring] PASS)
# Fail marker:  [test_keyring] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_KEYRING_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_keyring] (1/3) Build userland + plant /etc/keyring-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_KEYRING_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_keyring] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_keyring] (3/3) Boot QEMU (no extra disk needed)"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_keyring] --- keyring self-test output ---"
grep -a -E "\[KEYRING\]|\[keyring\]" "$LOG" || true
echo "[test_keyring] --- end ---"

fail=0

if grep -a -F -q "[KEYRING] FAIL" "$LOG"; then
    echo "[test_keyring] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[KEYRING] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[keyring] PASS" "$LOG"; then
    echo "[test_keyring] MISS: self-test PASS banner (expected '[keyring] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_keyring] --- full log ---"
    cat "$LOG"
    echo "[test_keyring] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_keyring] PASS — add_key/request_key/keyctl round-trip through the" \
     "per-process/per-user key store (qemu rc=$rc)"
