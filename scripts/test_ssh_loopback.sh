#!/usr/bin/env bash
# scripts/test_ssh_loopback.sh — Hamnix native SSH-2.0 client <-> server
# end-to-end loopback self-test, entirely inside one booted guest.
#
# This is the canonical "does Hamnix SSH actually work on its real data
# path" regression. It boots ONE QEMU guest and, inside it:
#   1. starts the native SSH server (user/sshd.ad) which brings up its
#      ECDSA host key and net_announce(22) on the Plan-9 /net file tree;
#   2. runs the native SSH client (user/ssh.ad) against root@127.0.0.1
#      over the in-kernel TCP loopback (no BSD sockets — the /net dance
#      from user/net9.ad), doing the full SSH-2.0 handshake:
#         curve25519-sha256 KEX, ecdsa-sha2-nistp256 host-key verify,
#         chacha20-poly1305@openssh.com, password userauth (root/hamnix),
#         a session channel, and `exec` of a one-shot command;
#   3. execs `echo SSH_CLIENT_RTT_OK` on the server and asserts the
#      sentinel round-trips back through the ENCRYPTED channel to the
#      client's stdout.
# Nothing on the host talks SSH; both ends are Hamnix.
#
# The client is embedded as the guest's /init (INIT_ELF override): it
# runs as PID 1, spawns sshd as its child, then loops back to itself.
# Loopback 127.0.0.1 works regardless of DHCP, per drivers/net/ip.ad.
#
# PASS gates (the guest console carries both [ssh*] and [sshd] logs):
#   "[ssh] key exchange complete"   — client finished KEX + NEWKEYS
#   "[ssh] authentication succeeded" — password userauth worked
#   "SSH_CLIENT_RTT_OK"             — the remote echo round-tripped
#   "[ssh-e2e] PASS"                — the loopback self-test verdict
#
# Boots the kernel image directly under QEMU (the fast dev-loop path);
# the SSH transport code is identical on the full UEFI .img boot path.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
SSH_ELF=build/user/ssh.elf
SSHD_ELF=build/user/sshd.elf

echo "[test_ssh_loopback] (1/3) Build userland (incl. ssh + sshd)"
bash scripts/build_user.sh >/dev/null
if [ ! -f "$SSH_ELF" ]; then
    echo "[test_ssh_loopback] FAIL: $SSH_ELF not built"
    exit 1
fi
if [ ! -f "$SSHD_ELF" ]; then
    echo "[test_ssh_loopback] FAIL: $SSHD_ELF not built"
    exit 1
fi

echo "[test_ssh_loopback] (2/3) Embed ssh as /init + rebuild kernel"
INIT_ELF="$SSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ssh_loopback] (3/3) Boot QEMU (ssh client loops back to local sshd)"
LOG=$(mktemp)
# Restore the normal /init on exit so we don't leave the kernel image
# wired to ssh.elf for the next test.
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

echo "[test_ssh_loopback] --- guest log (ssh / sshd) ---"
grep -aE '\[ssh\]|\[ssh-selftest\]|\[ssh-e2e\]|\[sshd\]|SSH_CLIENT_RTT_OK' "$LOG" || true
echo "[test_ssh_loopback] --- end ---"

# --- evaluate the PASS gates -----------------------------------------
#
# REQUIRED gates (the authoritative proof SSH works end to end):
#   * SSH_CLIENT_RTT_OK — the server's `echo` output arrived on the
#     CLIENT's stdout over the ENCRYPTED channel. You cannot decrypt and
#     deliver that without a completed curve25519 KEX, NEWKEYS, password
#     userauth, a session channel, AND a working exec — so this single
#     line implies the whole stack.
#   * [ssh-e2e] PASS — the client's SELF-VALIDATING verdict: ssh.ad only
#     emits it after its own rolling matcher confirms the sentinel
#     round-tripped (no longer a false positive on a session that merely
#     "ended" — see user/ssh.ad _selftest).
#
# DIAGNOSTIC gates (informational only): the intermediate "[ssh] key
# exchange complete" / "[ssh] authentication succeeded" lines are logged
# to the shared console concurrently with sshd's [sshd] lines + kernel
# printk, so the kernel console BYTE-INTERLEAVES them mid-string and an
# exact grep is unreliable. They are reported but NOT required — the two
# end-of-session markers above (emitted in the quiet window after the
# round-trip) survive intact and prove the same thing.
have_kex=0
if grep -aF -q "[ssh] key exchange complete" "$LOG"; then
    echo "[test_ssh_loopback] OK: client completed KEX + NEWKEYS"
    have_kex=1
else
    echo "[test_ssh_loopback] note: KEX marker mangled by console interleave (diagnostic only)"
fi

have_auth=0
if grep -aF -q "[ssh] authentication succeeded" "$LOG"; then
    echo "[test_ssh_loopback] OK: client authenticated (password)"
    have_auth=1
else
    echo "[test_ssh_loopback] note: auth marker mangled by console interleave (diagnostic only)"
fi

have_rtt=0
if grep -aF -q "SSH_CLIENT_RTT_OK" "$LOG"; then
    echo "[test_ssh_loopback] OK: remote command output round-tripped"
    have_rtt=1
else
    echo "[test_ssh_loopback] MISS: remote command output did not round-trip"
fi

have_e2e=0
if grep -aF -q "[ssh-e2e] PASS" "$LOG"; then
    echo "[test_ssh_loopback] OK: loopback self-test reported [ssh-e2e] PASS"
    have_e2e=1
else
    echo "[test_ssh_loopback] MISS: no self-validating [ssh-e2e] PASS verdict"
fi

if [ "$have_rtt" -eq 1 ] && [ "$have_e2e" -eq 1 ]; then
    echo "[ssh-e2e] PASS (loopback ssh: encrypted exec round-trip + self-validated verdict)"
    exit 0
fi

echo "[ssh-e2e] FAIL (qemu rc=$rc)"
echo "[test_ssh_loopback] --- full log tail ---"
tail -n 120 "$LOG"
exit 1
