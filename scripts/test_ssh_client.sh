#!/usr/bin/env bash
# scripts/test_ssh_client.sh — Hamnix native SSH-2.0 OUTBOUND client,
# end to end, entirely inside one booted guest (loopback to self).
#
# Unlike scripts/test_sshd.sh (which drives the guest's SERVER from the
# host's real OpenSSH client), this test exercises the guest's CLIENT —
# user/ssh.ad — against the guest's own SERVER over loopback. Nothing
# on the host talks SSH; both ends are Hamnix.
#
# How it works:
#   * user/ssh.ad, run with NO host argument, enters its self-test mode:
#       1. sys_spawn /bin/sshd  (concurrent task; brings up its ECDSA
#          host key + net_announce(22) on the /net file tree).
#       2. cooperatively yields until sshd has announced.
#       3. net_dial 127.0.0.1:22 and run a full client handshake:
#          curve25519-sha256 KEX, chacha20-poly1305, password auth
#          (root/hamnix), open a session channel, exec a command.
#       4. asserts the command's output round-trips back over the
#          channel.
#   * We embed ssh.elf as the guest's /init (INIT_ELF override) so the
#     self-test runs as PID 1 with sshd as its child.
#   * The guest needs the in-kernel TCP/IP stack online for loopback,
#     which init/main.ad brings up inside virtio_net_init(); so we boot
#     with a virtio-net device (DHCP may or may not bind — loopback
#     127.0.0.1 works regardless, per drivers/net/ip.ad).
#
# PASS gates (the guest console carries both [ssh*] and [sshd] logs):
#   Required (full PASS):
#     "[ssh] key exchange complete"            — client finished KEX
#     "[ssh] authentication succeeded"         — password auth worked
#     "SSH_CLIENT_RTT_OK"                      — the remote `echo`
#                                                output round-tripped
#     "[ssh-selftest] PASS"                    — the self-test verdict
#
# This boots the kernel image directly under QEMU (the fast dev-loop
# path, same as scripts/test_sshd.sh) rather than the full UEFI .img;
# the SSH client/transport code is identical on either boot path, so
# the faster path is used for the regression loop.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
SSH_ELF=build/user/ssh.elf
SSHD_ELF=build/user/sshd.elf

echo "[test_ssh_client] (1/3) Build userland (incl. ssh + sshd)"
bash scripts/build_user.sh >/dev/null
if [ ! -f "$SSH_ELF" ]; then
    echo "[test_ssh_client] FAIL: $SSH_ELF not built"
    exit 1
fi
if [ ! -f "$SSHD_ELF" ]; then
    echo "[test_ssh_client] FAIL: $SSHD_ELF not built"
    exit 1
fi

echo "[test_ssh_client] (2/3) Embed ssh as /init + rebuild kernel"
INIT_ELF="$SSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ssh_client] (3/3) Boot QEMU (ssh self-test loops back to local sshd)"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
timeout 280s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 2 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_ssh_client] --- guest log (ssh / sshd / tcp) ---"
grep -E '\[ssh\]|\[ssh-selftest\]|\[sshd\]|SSH_CLIENT_RTT_OK' "$LOG" || true
echo "[test_ssh_client] --- end ---"

# --- evaluate the PASS gates -----------------------------------------
have_kex=0
if grep -F -q "[ssh] key exchange complete" "$LOG"; then
    echo "[test_ssh_client] OK: client completed KEX + NEWKEYS"
    have_kex=1
else
    echo "[test_ssh_client] MISS: client did not complete KEX"
fi

have_auth=0
if grep -F -q "[ssh] authentication succeeded" "$LOG"; then
    echo "[test_ssh_client] OK: client authenticated (password)"
    have_auth=1
else
    echo "[test_ssh_client] MISS: client did not authenticate"
fi

have_rtt=0
if grep -F -q "SSH_CLIENT_RTT_OK" "$LOG"; then
    echo "[test_ssh_client] OK: remote command output round-tripped"
    have_rtt=1
else
    echo "[test_ssh_client] MISS: remote command output did not round-trip"
fi

have_pass=0
if grep -F -q "[ssh-selftest] PASS" "$LOG"; then
    echo "[test_ssh_client] OK: self-test reported PASS"
    have_pass=1
fi

if [ "$have_kex" -eq 1 ] && [ "$have_auth" -eq 1 ] \
   && [ "$have_rtt" -eq 1 ] && [ "$have_pass" -eq 1 ]; then
    echo "[test_ssh_client] PASS (loopback ssh: KEX + auth + command round-trip)"
    exit 0
fi

echo "[test_ssh_client] FAIL (qemu rc=$rc)"
echo "[test_ssh_client] --- full log tail ---"
tail -n 120 "$LOG"
exit 1
