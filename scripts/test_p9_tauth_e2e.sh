#!/usr/bin/env bash
# scripts/test_p9_tauth_e2e.sh — F10-4 / audit §11.2 regression.
#
# Audit docs/audit_arch_shortcuts_2026-06-13.md §11.2 flagged that no
# end-to-end test gated the Plan 9 wire authentication handshake:
# `test_p9_tauth.sh` only proved the kernel extracts the principal
# name, and `test_p9_auth_e2e.sh` only exercised the success path. A
# regression making p9c_attach_authed_run silently accept a server-
# rejected Twrite would slip through both. THIS test closes that gap
# by driving BOTH the success leg AND the failure leg of the wire
# handshake against a single fixture and asserting:
#
#   * Leg A: server expects cred=="live", kernel writes "live"
#     → Tauth + Twrite + Tattach all R-success
#     → mount returns 0, /n/eauth-ok/hello reads "p9demo says hi\n".
#
#   * Leg B: server expects cred=="alice", kernel writes "live"
#     → Tauth R-success, Twrite Rerrors "cred mismatch",
#       Tattach is never sent (p9c_attach_authed_run bails)
#     → mount returns -1; userland sees `[mount rejected (expected)]`.
#
# The mutation test in the brief: temporarily relax the Twrite
# rejection in p9c_attach_authed_run (e.g., make `if wn < cred_len:`
# unreachable) and this script's `[p9tauthE2E] leg-B mount rejected`
# marker is replaced by `leg-B mount unexpectedly succeeded` — the
# script FAILs. Reverted before commit.
#
# Pipeline mirrors scripts/test_p9_auth_e2e.sh.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_p9_tauth_e2e.elf

echo "[test_p9_tauth_e2e] (1/5) Build userland (hamsh + coreutils + p9srv_demo)"
bash scripts/build_user.sh >/dev/null

echo "[test_p9_tauth_e2e] (2/5) Build tests/test_p9_tauth_e2e.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_p9_tauth_e2e.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_p9_tauth_e2e] (3/5) Plant /init = hamsh + /bin/test_p9_tauth_e2e in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_p9_tauth_e2e] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_p9_tauth_e2e] (5/5) Boot QEMU under qemu_drive"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 120 \
    -- "bind '#c' /dev" 2 \
       "/bin/test_p9_tauth_e2e" 15 \
       "exit" 2
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_p9_tauth_e2e] --- captured output ---"
cat "$LOG"
echo "[test_p9_tauth_e2e] --- end output ---"

fail=0

check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_p9_tauth_e2e] OK: $label"
    else
        echo "[test_p9_tauth_e2e] MISS: $label ($marker)"
        fail=1
    fi
}

# Userland fixture acceptance.
check "[p9tauthE2E] start"                          "fixture ran"
check "[p9tauthE2E] auth-as-live OK"                "verified afd via /dev/auth"
check "[p9tauthE2E] leg-A spawn OK"                 "leg A server spawned"
check "[p9tauthE2E] leg-A mount OK"                 "leg A: full Tauth+Twrite+Tattach succeeded"
check "[p9tauthE2E] leg-A read OK"                  "leg A: read through authed mount"
check "[p9tauthE2E] leg-B spawn OK"                 "leg B server spawned"
check "[p9tauthE2E] leg-B mount rejected (expected)" \
                                                    "leg B: Twrite Rerror propagated to mount = -1"
check "[p9tauthE2E] PASS"                           "fixture reached PASS"

# Server-side acceptance: prove the strict policy actually fired on
# both legs.
check "[p9demo-strict] cred matched, afid authed"   "leg A: server accepted matching cred"
check "[p9demo-strict] cred mismatch rejected"      "leg B: server rejected mismatched cred"

# Kernel-side acceptance: the do_mount [mount] uname= printk fires
# for both legs (do_mount runs before p9c_attach_authed_run).
check "[mount] uname=live" \
      "kernel: verified principal 'live' plumbed into Tauth/Tattach uname"

if [ "$fail" -ne 0 ]; then
    echo "[test_p9_tauth_e2e] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_p9_tauth_e2e] PASS — Plan 9 wire Tauth/Twrite/Tattach success AND failure legs both gated"
