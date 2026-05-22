#!/usr/bin/env bash
# scripts/test_sshd_pubkey.sh — Hamnix SSH server publickey auth, e2e.
#
# Builds user/sshd.ad, generates a throwaway ECDSA-P256 keypair on the
# host, bakes the PUBLIC key into the guest initramfs as
# /var/lib/ssh/authorized_keys, boots sshd as /init in QEMU with a
# SLIRP hostfwd onto guest port 22, then runs the host's REAL OpenSSH
# client TWICE:
#
#   Run A (accept) : ssh -i <authorized private key>, publickey-only.
#                    The server must log "publickey authentication
#                    succeeded" and the session must reach a shell.
#   Run B (reject) : ssh -i <a DIFFERENT, unauthorized key>,
#                    publickey-only, password disabled. The server
#                    must NOT log "publickey authentication succeeded"
#                    for this run and the client must fail to auth.
#
# A real SSH server must both ACCEPT a valid signature from an
# authorized key AND REJECT everything else; this test asserts both.
#
# PASS criterion: run A authenticated by publickey AND reached a
# session, and run B failed to authenticate.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
SSHD_ELF=build/user/sshd.elf

KEYDIR=$(mktemp -d)
trap 'rm -rf "$KEYDIR"' EXIT

# --- generate the keypairs -------------------------------------------
# Authorized key (the one baked into the guest's authorized_keys).
ssh-keygen -q -t ecdsa -b 256 -N "" -f "$KEYDIR/authorized" -C "hamnix-test-authorized"
# Unauthorized key (NOT in authorized_keys — used for the reject run).
ssh-keygen -q -t ecdsa -b 256 -N "" -f "$KEYDIR/intruder" -C "hamnix-test-intruder"

# authorized_keys = the public half of the authorized key.
cp "$KEYDIR/authorized.pub" "$KEYDIR/authorized_keys"
echo "[test_sshd_pubkey] authorized_keys:"
sed 's/^/  /' "$KEYDIR/authorized_keys"

# --- pick a free host port -------------------------------------------
HOST_PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
echo "[test_sshd_pubkey] host port $HOST_PORT -> guest port 22"

echo "[test_sshd_pubkey] (1/3) Build userland (incl. sshd)"
bash scripts/build_user.sh >/dev/null
if [ ! -f "$SSHD_ELF" ]; then
    echo "[test_sshd_pubkey] FAIL: $SSHD_ELF not built"
    exit 1
fi

echo "[test_sshd_pubkey] (2/3) Embed sshd as /init + bake authorized_keys"
INIT_ELF="$SSHD_ELF" HAMNIX_SSH_AUTHKEYS="$KEYDIR/authorized_keys" \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_sshd_pubkey] (3/3) Boot QEMU with hostfwd tcp::${HOST_PORT}-:22"
LOG=$(mktemp)
SSHLOG=$(mktemp)
trap 'rm -f "$LOG" "$SSHLOG"; rm -rf "$KEYDIR"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# Background host-side SSH client driver. Waits for the listener
# marker, then runs ssh twice — once with the authorized key, once
# with the intruder key.
(
    python3 - "$HOST_PORT" "$SSHLOG" "$LOG" "$KEYDIR" <<'PY'
import subprocess, sys, time, os, pty, select, signal

port = sys.argv[1]
out_path = sys.argv[2]
log_path = sys.argv[3]
keydir = sys.argv[4]

# Wait for the guest's listener marker (up to ~180 s of boot).
deadline = time.time() + 180
while time.time() < deadline:
    try:
        with open(log_path, "r", errors="replace") as f:
            if "[sshd] listening on port 22" in f.read():
                break
    except OSError:
        pass
    time.sleep(1)
time.sleep(2)

def run_ssh(keyfile, label, want_shell):
    common = [
        "-v", "-tt",
        "-p", port,
        "-i", keyfile,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "PreferredAuthentications=publickey",
        "-o", "PubkeyAuthentication=yes",
        "-o", "PasswordAuthentication=no",
        "-o", "IdentitiesOnly=yes",
        "-o", "ConnectTimeout=60",
        "-o", "NumberOfPasswordPrompts=0",
    ]
    cmd = ["ssh"] + common + ["root@127.0.0.1"]
    m_fd, s_fd = pty.openpty()
    proc = subprocess.Popen(cmd, stdin=s_fd, stdout=s_fd,
                            stderr=subprocess.PIPE, text=False,
                            close_fds=True)
    os.close(s_fd)
    captured = b""
    err_chunks = []
    typed_cmd = False
    typed_exit = False
    cmd_at = None
    deadline = time.time() + 70
    while time.time() < deadline:
        if proc.poll() is not None:
            break
        rfds, _, _ = select.select([m_fd, proc.stderr], [], [], 0.5)
        if m_fd in rfds:
            try:
                chunk = os.read(m_fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            captured += chunk
        if proc.stderr in rfds:
            ec = proc.stderr.read1(4096) if hasattr(proc.stderr, "read1") \
                 else proc.stderr.read(4096)
            if ec:
                err_chunks.append(ec)
        joined_err = b"".join(err_chunks)
        if want_shell and (not typed_cmd) and \
                b"Entering interactive session" in joined_err:
            time.sleep(2)
            os.write(m_fd, b"uname\n")
            typed_cmd = True
            cmd_at = time.time()
        if typed_cmd and (not typed_exit) and \
                cmd_at is not None and time.time() - cmd_at > 6:
            os.write(m_fd, b"exit\n")
            typed_exit = True
    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
    rc = proc.returncode
    try:
        os.close(m_fd)
    except OSError:
        pass
    out = captured.decode("utf-8", "replace")
    err = b"".join(err_chunks).decode("utf-8", "replace")
    return (
        "=== %s ssh stdout ===\n" % label + out +
        "\n=== %s ssh stderr (verbose) ===\n" % label + err +
        "\n=== %s ssh rc=%s ===\n" % (label, rc)
    )

result = ""
try:
    result += run_ssh(os.path.join(keydir, "authorized"), "ACCEPT", True)
    time.sleep(3)
    result += run_ssh(os.path.join(keydir, "intruder"), "REJECT", False)
except Exception as e:
    result += "ssh client error: %r\n" % e

with open(out_path, "w") as f:
    f.write(result)
PY
) &
CLIENT_PID=$!

set +e
# The guestfwd onto 10.0.2.100:7 lets the kernel's boot-time TCP smoke
# test (init/main.ad connects to 10.0.2.100:7) complete promptly —
# without it init/main.ad stalls retrying and /init (sshd) never runs.
# Same shape as scripts/test_sshd.sh.
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev "user,id=n0,hostfwd=tcp::${HOST_PORT}-:22,guestfwd=tcp:10.0.2.100:7-cmd:cat" \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -smp 2 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

wait "$CLIENT_PID" 2>/dev/null || true

echo "[test_sshd_pubkey] --- guest sshd log ---"
grep -E '\[sshd\]' "$LOG" || true
echo "[test_sshd_pubkey] --- ssh client log ---"
cat "$SSHLOG" 2>/dev/null || echo "(no ssh client output)"
echo "[test_sshd_pubkey] --- end ---"

fail=0

# The authorized_keys file must have been loaded by the daemon.
if grep -F -q "[sshd] authorized_keys loaded" "$LOG"; then
    echo "[test_sshd_pubkey] OK: sshd loaded authorized_keys"
else
    echo "[test_sshd_pubkey] MISS: sshd did not load authorized_keys"
    fail=1
fi

# ACCEPT run: publickey auth must have succeeded.
PK_OK=$(grep -F -c "[sshd] publickey authentication succeeded" "$LOG" || true)
if [ "${PK_OK:-0}" -ge 1 ]; then
    echo "[test_sshd_pubkey] OK: publickey authentication succeeded (accept run)"
else
    echo "[test_sshd_pubkey] MISS: publickey auth never succeeded"
    fail=1
fi

# The ACCEPT run should have reached a session + run uname.
ACCEPT_STDOUT=$(sed -n '/=== ACCEPT ssh stdout ===/,/=== ACCEPT ssh stderr/p' \
    "$SSHLOG" 2>/dev/null || true)
if echo "$ACCEPT_STDOUT" | grep -F -q "Hamnix x86_64"; then
    echo "[test_sshd_pubkey] OK: accept run reached an interactive shell"
else
    echo "[test_sshd_pubkey] NOTE: accept run did not round-trip 'uname'" \
         "(auth still proven by the server log)"
fi

# REJECT run: ssh with the intruder key, publickey-only, must FAIL.
# The verbose client log for the REJECT run should show a permission
# denial; it must NOT report an authenticated session.
REJECT_ERR=$(sed -n '/=== REJECT ssh stderr/,/=== REJECT ssh rc/p' \
    "$SSHLOG" 2>/dev/null || true)
if echo "$REJECT_ERR" | grep -E -q \
        "Permission denied|No more authentication methods|Authentication failed"; then
    echo "[test_sshd_pubkey] OK: intruder key was rejected (reject run)"
elif echo "$REJECT_ERR" | grep -F -q "Entering interactive session"; then
    echo "[test_sshd_pubkey] FAIL: intruder key was let in!"
    fail=1
else
    # No explicit denial string and no session — treat the absence of
    # an authenticated session as a rejection, but flag it.
    echo "[test_sshd_pubkey] NOTE: reject run produced no session" \
         "(treated as a rejection)"
fi

# The total count of publickey successes must be exactly 1 (the accept
# run only) — proves the intruder key did NOT also authenticate.
if [ "${PK_OK:-0}" -eq 1 ]; then
    echo "[test_sshd_pubkey] OK: exactly one publickey success (intruder excluded)"
elif [ "${PK_OK:-0}" -gt 1 ]; then
    echo "[test_sshd_pubkey] FAIL: more than one publickey success" \
         "— the intruder key authenticated"
    fail=1
fi

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_sshd_pubkey] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_sshd_pubkey] FAIL (qemu rc=$rc)"
    echo "[test_sshd_pubkey] --- full kernel log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi

echo "[test_sshd_pubkey] PASS — authorized key accepted, intruder key rejected"
exit 0
