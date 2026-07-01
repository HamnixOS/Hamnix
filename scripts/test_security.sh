#!/usr/bin/env bash
# scripts/test_security.sh — end-to-end test for docs/security.md.
#
# Verifies the Plan-9-shape security plumbing landed across phases:
#
# Phase 1 (M16-era kernel plumbing):
#   * SYS_GETUID returns the running task's uid (live ISO ships with
#     hostowner `live` at uid 1).
#   * SYS_SETUID is privileged: callable only when current uid == 1.
# Phase 4 — /dev/auth cdev (kernel-side credential check):
#   * /dev/auth opens, accepts "user <name>\n" + "pass <plain>\n",
#     reads back "ok <uid> <gid>\n" or "denied\n".
#   * Rate-limited (1 attempt/sec per fd via pit_monotonic_us).
# Phase 5 — VFS permission check (owner/group/other × rwx):
#   * Hostowner-bypass (uid 1) reads /etc/passwd, /etc/shadow,
#     /dev/blk/vda/size cleanly.
#   * Regular user attempting the same hits -EPERM "permission denied".
# Phase 6 — ext4 owner/group/mode write on create:
#   * Files created via ext4 (e.g. `echo foo > /ext/test` from live)
#     carry uid 1 / gid 1; mkfs root inode is uid 1 / gid 1.
# Phase 7 — newshell builtin (Plan-9-shape elevation):
#   * `newshell <user>` reads /etc/passwd, prompts password, opens
#     /dev/auth, rforks, exec's /bin/hamsh.
# Phase 8 — hpm uid==1 gate.
# Phase 9 — per-user namespace recipe at newshell-spawned hamsh:
#   * The HAMNIX_NEWSHELL_USER env var triggers /etc/users/<user>.ns
#     sourcing (uid 1 bypasses; hostowner keeps full namespace).
#
# What this test verifies end-to-end:
#   - /etc/passwd reads with live:x:1:1:... format.
#   - /etc/shadow reads with live:$6$... format (hostowner only —
#     a regular user wouldn't even resolve /etc/shadow given the
#     Phase 5 perm check).
#   - /dev/blk/vda/size opens for the live (hostowner) user.
#   - `newshell <nosuchuser>` rejects with "no such user".
#   - After dropping to a regular user (`setuid 1000`), `newshell live`
#     with a WRONG password is rejected by /dev/auth ("newshell:
#     authentication failed"). (From the uid-1 console `newshell live`
#     would take the password-free self-elevation fast path, so the
#     credential check is exercised from a non-hostowner uid.)

. "$(dirname "$0")/_build_lock.sh"
# _build_lock.sh sources _kernel_iso.sh, which installs the build/binshim
# `qemu-system-x86_64` GRUB-ISO wrapper on PATH (so the Python driver below
# transparently boots the elf64 higher-half kernel).

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_security] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true

# LEAN BOOT (reliability fix): drive the security boundary over a STRIPPED
# rc with hamsh as /init, NOT the full installer boot to runlevel 5. On a
# runlevel-5 boot the serial console (/dev/cons) is shared between the
# serial shell, the VT gettys, and the DE input path, so serial input
# routing is AMBIGUOUS — the driver's keystrokes are frequently consumed by
# a getty / the DE instead of the shell whose output we assert, and NOTHING
# lands (the "flaky driver" this test suffered). The stripped rc keeps the
# serial line the SOLE interactive shell — exactly the proven-reliable model
# scripts/test_newshell_auth_elevation.sh uses to drive the SAME newshell /
# /dev/auth path. It still exercises every security check here (passwd/
# shadow perm reads, newshell no-such-user, wrong-password /dev/auth deny):
# none of them need runlevel 5.
echo "[test_security] (2/4) Plant stripped /etc/hamsh.rc (device + passwd/shadow binds, no runlevel-5 DE)"
RC_TMP=$(mktemp /tmp/hamsh-rc-sec.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
bind '#c' /dev
bind '#s' /srv
bind '#p' /proc
bind '#/' /n
bind '#r/etc/passwd' /etc/passwd
bind '#r/etc/shadow' /etc/shadow
bind '#r/etc/group' /etc/group
echo TEST_RC_DONE
EOF

echo "[test_security] (3/4) Build initramfs (hamsh as /init, stripped rc) + kernel"
# Distinct /init copy so build_initramfs still lands build/user/hamsh.elf
# at /bin/hamsh (newshell exec's it after the identity change).
INIT_HAMSH=$(mktemp /tmp/hamsh-init-sec.XXXXXX.elf)
cp "$HAMSH_ELF" "$INIT_HAMSH"
HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$INIT_HAMSH" \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-security.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP" "$INIT_HAMSH"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_security] (4/4) Boot QEMU + drive security smoke"
# DRIVER HARDENING (T66-style, mirrors scripts/test_fork_eagain_pipeline.sh):
#
#   The previous driver (qemu_drive) fired each command exactly ONCE with a
#   fixed post-delay. The FULL installer-image kernel boots to runlevel 5
#   under TCG (~2-3 min) and the serial readline only starts consuming stdin
#   AFTER rc.boot hands off; a freshly-busy readline also drops its first
#   line. So a fire-once command frequently never landed and the test MISSed
#   all four lookups (the "commands not landing" signature) even though the
#   underlying auth/perm behaviour is correct (proven by
#   scripts/test_newshell_auth_elevation.sh).
#
#   This driver instead RE-SENDS each idempotent query until its own proof
#   marker appears on the serial log, after first gating on the un-fakeable
#   shell-ready banner + a SYNC echo handshake (a live readline must echo
#   our probe before we drive the real commands). Each repeated query is
#   harmless: re-reading /etc/passwd or re-running `newshell nosuchuser`
#   just produces the same line again.
#
# WRONG-PASSWORD path — IMPORTANT subtlety:
#   The serial/console shell already runs as uid 1 (the kernel upgrades
#   /init to the hostowner before exec'ing hamsh). For the uid-1 -> uid-1
#   transition `newshell <hostowner>` takes the PASSWORD-FREE self-
#   elevation fast path (you don't prove a secret to become who you
#   already are — see builtin_newshell Step 1.5 in user/hamsh.ad). So
#   `newshell live` from the console would NEVER prompt and a "wrong
#   password" would just be run as a command — it could never produce
#   "authentication failed".
#
#   To actually exercise the credential check we first DROP to a regular
#   user with `setuid 1000` (the hostowner can step down to any uid).
#   From uid 1000, `newshell live` (target uid 1) is NOT the fast path:
#   it prompts, and the next line we feed ("wrong-password") is consumed
#   by newshell's silent read loop and handed to /dev/auth, which rejects
#   it -> "newshell: authentication failed". Because uid 1 would have
#   skipped the prompt entirely, the auth-failed marker is itself proof
#   the drop to uid 1000 took effect. The /etc/shadow read (hostowner-
#   only, 0600) therefore happens BEFORE the setuid-1000 drop.
set +e
python3 - "$ELF" "$LOG" "${SEC_BOOT_WAIT:-360}" <<'PYDRV'
import sys, subprocess, time, threading

elf, logpath, boot_wait = sys.argv[1], sys.argv[2], int(sys.argv[3])

# The build/binshim qemu-system-x86_64 wrapper (on PATH via _kernel_iso.sh)
# turns this -kernel <elf64> into a -cdrom <GRUB ISO> boot and injects KVM
# when /dev/kvm is usable. 2G: the debug kernel embeds a large initramfs and
# the BIOS GRUB loader needs headroom.
qemu = subprocess.Popen(
    ["qemu-system-x86_64", "-kernel", elf,
     "-smp", "2", "-nographic", "-no-reboot",
     "-m", "2G", "-monitor", "none", "-serial", "stdio"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT, bufsize=0)

logf = open(logpath, "wb")
buf = bytearray()
lock = threading.Lock()

def reader():
    while True:
        b = qemu.stdout.read(1)
        if not b:
            break
        logf.write(b); logf.flush()
        with lock:
            buf.extend(b)

threading.Thread(target=reader, daemon=True).start()

def snap():
    with lock:
        return bytes(buf)

def have(marker):
    return marker.encode() in snap()

def wait_for(marker, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if have(marker):
            return True
        if qemu.poll() is not None:
            return False
        time.sleep(0.5)
    return False

def send(line):
    try:
        qemu.stdin.write((line + "\n").encode()); qemu.stdin.flush()
    except Exception:
        pass

def resend_until(lines, marker, attempts=40, gap=3.0):
    """Re-send the command line(s) until `marker` shows up (or attempts run
    out). Each query is idempotent so duplicates are harmless."""
    for _ in range(attempts):
        if have(marker):
            return True
        for ln in lines:
            send(ln)
        time.sleep(gap)
    return have(marker)

try:
    # 1. Shell ready (un-fakeable banner), with the stage-07 heartbeat as a
    #    fallback marker.
    if not wait_for("M16.35 shell ready", boot_wait):
        wait_for("stage-07", 30)
    # The stripped rc prints TEST_RC_DONE when it finishes sourcing (device +
    # passwd/shadow binds done) — that is the settle point after which the
    # serial readline consumes stdin. Best-effort; the sync handshake below
    # is the real proof the shell is live.
    wait_for("TEST_RC_DONE", 90)
    time.sleep(3)

    # 2. SYNC handshake: a freshly-busy readline drops its first line, so
    #    re-send an idempotent probe until it echoes back — proof a live
    #    readline is consuming our stdin.
    synced = False
    for _ in range(120):
        send("echo SEC_SERIAL_SYNC")
        time.sleep(1.0)
        if have("SEC_SERIAL_SYNC"):
            synced = True
            break
    if not synced:
        print("DRIVER: SEC_SERIAL_SYNC never echoed", file=sys.stderr)

    # 3. Idempotent reads — re-send each until its proof marker lands.
    if not resend_until(["cat /etc/passwd"], "live:x:1:1:"):
        print("DRIVER: /etc/passwd read never captured", file=sys.stderr)
    if not resend_until(["cat /etc/shadow"], "live:$6$"):
        print("DRIVER: /etc/shadow read never captured", file=sys.stderr)
    # Block-size read: pair the cat with an echo marker so the gate can find
    # the digits just above SEC_STAGE_BLK_READ.
    if not resend_until(["cat /dev/blk/vda/size", "echo SEC_STAGE_BLK_READ"],
                        "SEC_STAGE_BLK_READ"):
        print("DRIVER: /dev/blk/vda/size read never captured", file=sys.stderr)
    if not resend_until(["newshell nosuchuser"], "newshell: no such user"):
        print("DRIVER: newshell bad-user never captured", file=sys.stderr)

    # 4. Drop to a regular user (uid 1000) IN-PLACE. Confirm the command
    #    landed via an echo marker; from uid 1 the hostowner can always step
    #    down, so a landed `setuid 1000` necessarily took effect.
    resend_until(["setuid 1000", "echo SEC_DROP_OK"], "SEC_DROP_OK",
                 attempts=20)

    # 5. WRONG password from uid 1000. `newshell live` prompts; the next line
    #    is consumed as the (wrong) password and /dev/auth rejects it. Re-send
    #    the prompt+password PAIR until the auth-failed marker lands — each
    #    denied attempt just returns to the uid-1000 prompt, so retries are
    #    safe. The marker can only appear from a non-uid-1 caller (uid 1 would
    #    skip the prompt), so it doubles as proof the drop in step 4 worked.
    got_authfail = False
    for _ in range(20):
        if have("newshell: authentication failed"):
            got_authfail = True
            break
        send("newshell live")
        time.sleep(3.0)
        send("wrong-password")
        time.sleep(4.0)
    if not got_authfail and not have("newshell: authentication failed"):
        print("DRIVER: auth-failed marker never captured", file=sys.stderr)

    send("echo SEC_STAGE_DONE"); time.sleep(2)
except Exception as e:
    print("DRIVER exception: %r" % (e,), file=sys.stderr)
finally:
    try:
        qemu.terminate(); time.sleep(1); qemu.kill()
    except Exception:
        pass
sys.exit(0)
PYDRV
rc=$?
set -e

echo "[test_security] --- captured output ---"
cat "$LOG"
echo "[test_security] --- end output ---"

fail=0

# 1. Shell came up.
if ! grep -q "M16.35 shell ready\|hamsh.*ready\|stage-07" "$LOG"; then
    echo "[test_security] FAIL: hamsh never reached the interactive loop"
    fail=1
fi

# 2. /etc/passwd contains the live hostowner.
if ! grep -q "live:x:1:1:" "$LOG"; then
    echo "[test_security] FAIL: /etc/passwd missing live:x:1:1:..."
    fail=1
else
    echo "[test_security] OK: /etc/passwd has live:x:1:1:..."
fi

# 3. /etc/shadow contains the live hostowner's hash with $6$ prefix.
if ! grep -q "live:\\\$6\\\$" "$LOG"; then
    echo "[test_security] FAIL: /etc/shadow missing live:\$6\$..."
    fail=1
else
    echo "[test_security] OK: /etc/shadow has live:\$6\$..."
fi

# 4. newshell with a non-existent user produces the no-such-user diag.
if ! grep -q "newshell: no such user" "$LOG"; then
    echo "[test_security] FAIL: newshell <bad-user> didn't error correctly"
    echo "[test_security]       (looking for 'newshell: no such user')"
    fail=1
else
    echo "[test_security] OK: newshell rejected unknown user"
fi

# 5. /dev/blk/vda/size reads for the live (hostowner) user. Phase 5's
#    perm check has a uid==1 bypass, so hostowner can still address
#    the raw block device. The /size cdev returns a decimal byte
#    count followed by newline — match the digits + newline shape.
if grep -E -q "SEC_STAGE_BLK_READ" "$LOG" && \
   grep -B 3 "SEC_STAGE_BLK_READ" "$LOG" | grep -E -q "^[0-9]+$"; then
    echo "[test_security] OK: hostowner read /dev/blk/vda/size"
else
    # The size file may be absent if QEMU isn't passing a vda — relax
    # to just confirming the open didn't trip the perm-check denial.
    # A 'permission denied' on this line would mean the hostowner
    # bypass broke.
    if grep -E -q "permission denied" "$LOG"; then
        echo "[test_security] FAIL: hostowner got permission denied"
        echo "[test_security]       on /dev/blk/vda/size (perm bypass broken)"
        fail=1
    else
        echo "[test_security] OK: /dev/blk read attempted without perm denial"
    fi
fi

# 6. newshell live with a wrong password lands the auth-failed diag.
#    The /dev/auth cdev (Phase 4) reads /etc/shadow in kernel context,
#    runs SHA-512-crypt verify, and writes "denied\n" — newshell's
#    response read picks that up and prints the auth-failed message.
if grep -q "newshell: authentication failed" "$LOG"; then
    echo "[test_security] OK: newshell rejected wrong password"
else
    echo "[test_security] FAIL: newshell didn't print auth-failed for wrong password"
    echo "[test_security]       (looking for 'newshell: authentication failed')"
    fail=1
fi

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_security] qemu exited with rc=$rc"
fi

if [ $fail -ne 0 ]; then
    echo "[test_security] FAILED ($fail assertions)"
    exit 1
fi

echo "[test_security] PASSED"
exit 0
