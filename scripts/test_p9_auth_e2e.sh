#!/usr/bin/env bash
# scripts/test_p9_auth_e2e.sh — F10-4 (#457) end-to-end wire-Tauth.
#
# The structural test_p9_tauth.sh proves the kernel extracts the
# verified principal name from /dev/auth's AuthSlot, but stops at the
# `[mount] uname=...` printk because there's no 9P responder. THIS
# test closes the loop: a real userland 9P server (p9srv_demo in
# `post-auth` mode) that REQUIRES the wire-Tauth handshake before
# honoring Tattach, mounted from the kernel client via
# p9c_attach_authed_run (negotiate -> Tauth -> Twrite(afid, cred) ->
# Tattach(afid)). Mount succeeds iff every wire leg succeeds.
#
# Boot pipeline mirrors scripts/test_p9_tauth.sh: build userland,
# plant /init = hamsh, build the test fixture, rebuild the kernel
# image, boot under qemu_drive (boot-marker-gated input), grep the
# log for the structural markers.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_p9_auth_e2e.elf

echo "[test_p9_auth_e2e] (1/5) Build userland (hamsh + coreutils + p9srv_demo)"
bash scripts/build_user.sh >/dev/null

echo "[test_p9_auth_e2e] (2/5) Build tests/test_p9_auth_e2e.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_p9_auth_e2e.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_p9_auth_e2e] (3/5) Plant /init = hamsh + /bin/test_p9_auth_e2e in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_p9_auth_e2e] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_p9_auth_e2e] (5/5) Boot QEMU under qemu_drive"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# `bind '#c' /dev` exposes /dev/auth; then the fixture runs the full
# auth + spawn + mount + read flow.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 90 \
    -- "bind '#c' /dev" 2 \
       "/bin/test_p9_auth_e2e" 10 \
       "exit" 2
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_p9_auth_e2e] --- captured output ---"
cat "$LOG"
echo "[test_p9_auth_e2e] --- end output ---"

fail=0

check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_p9_auth_e2e] OK: $label"
    else
        echo "[test_p9_auth_e2e] MISS: $label ($marker)"
        fail=1
    fi
}

# Fixture-side acceptance.
check "[p9authE2E] start"                          "fixture ran"
check "[p9authE2E] auth-as-live OK"                "verified afd via /dev/auth"
check "[p9authE2E] spawn p9srv_demo post-auth OK"  "spawned auth-required server"
check "[p9authE2E] mount with afd OK"              "kernel mount drove Tauth+Twrite+Tattach"
check "[p9authE2E] read /hello OK"                 "read through mounted afd"
check "[p9authE2E] payload match OK"               "payload matched expected"
check "[p9authE2E] PASS"                           "fixture reached PASS"

# Server-side acceptance: prove the auth-required policy actually
# fired (not the legacy path).
check "[p9demo-auth] mode=auth-required"           "server in auth-required mode"
check "[p9demo-auth] Rauth issued"                 "server emitted Rauth"
check "[p9demo-auth] afid marked authed"           "server accepted credential Twrite"
check "[p9demo-auth] Tattach with authed afid OK"  "server honored authed Tattach"

# Kernel-side acceptance: the do_mount [mount] uname= printk fires
# from the authed path too.
check "[mount] uname=live" \
      "kernel: verified principal 'live' plumbed into Tattach uname"

if [ "$fail" -ne 0 ]; then
    echo "[test_p9_auth_e2e] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_p9_auth_e2e] PASS — full Plan 9 wire Tauth/Twrite/Tattach handshake works end-to-end"
