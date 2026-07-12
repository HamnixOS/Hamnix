#!/usr/bin/env bash
# scripts/test_bind_noresolve.sh — #86 acceptance: a Plan 9 `bind` whose
# SOURCE (OLD) resolves to nothing must FAIL loudly (kernel error +
# non-zero shell status), not succeed as a silent no-op.
#
# THE BUG (fixed): bind(2) resolves OLD to a channel at bind time. For a
# `/`-anchored OLD, chan.ad::mnttab_bind's ns_walk only checked that a
# SERVER covers the prefix — the boot `/` -> #r root covers EVERY path —
# never that the path actually exists on that server. So
# `bind /nonexistent/src /somewhere` returned success and bound nothing;
# the user found out only later when the destination was mysteriously
# empty. do_bind (syschan.ad) now calls vfs_path_source_exists(OLD) and
# rejects a genuinely non-resolving cpio/tmpfs source with EINVAL-shape
# errstr; hamsh's `bind` builtin surfaces it (non-zero status + the
# kernel error line).
#
# WHAT THIS PROVES (unforgeably — every assertion keys on a token that
# the guest's REAL code path must PRODUCE, never on the typed command
# echo, per task #27's input-echo false-green fix):
#   1. The non-resolving bind ERRORS: the KERNEL-generated errstr token
#      "does not resolve" appears. That phrase is emitted by
#      do_bind's set_current_errstr and pulled into hamsh's errstr_buf —
#      it is NOT present in any line the harness TYPES.
#   2. The non-resolving bind sets a NON-ZERO shell status: "NRBIND_RC=1"
#      can only materialise from hamsh expanding `$status` (the typed
#      line is the literal `echo NRBIND_RC=$status`).
#   3. Regression — a LEGIT source still SUCCEEDS silently: `bind /etc
#      /nx_good` (an existing cpio dir) yields "GOODBIND_RC=0" and emits
#      NO "bind:" error line, and `bind '#c' /nx_dev` (a device server
#      source) yields "DEVBIND_RC=0". Device / union / ext4 / named-root
#      sources are ADMITTED, never false-rejected.
#
# DRIVE STRATEGY mirrors test_bind_warn.sh: hamsh as /init
# (INIT_ELF=hamsh.elf) driven through scripts/_hamsh_drive.sh's
# load-adaptive handshake. A starved guest that never reaches its markers
# is reported INCONCLUSIVE (scripts/_verdict.sh), never a false FAIL.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
trap '' PIPE
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
. "$PROJ_ROOT/scripts/_hamsh_drive.sh"

TAG=test_bind_noresolve
# -smp 1: a trustworthy verdict; an -smp 2 boot only false-FAILs under
# host contention (a PASS stays trustworthy).
export HAMNIX_TEST_SMP="${HAMNIX_TEST_SMP:-1}"
BOOT_WAIT="${BOOT_WAIT:-420}"
CMD_WAIT="${CMD_WAIT:-240}"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[$TAG] (1/3) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null

echo "[$TAG] (2/3) Plant hamsh as /init (no rc.boot / no sshd)"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[$TAG] (3/3) Build kernel"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
cleanup() {
    hamsh_shutdown
    # Restore the default initramfs so subsequent gates boot the
    # production /init shim path.
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
    [ "${KEEP_LOGS:-0}" = "1" ] || rm -f "$LOG" "${CLEAN:-}"
}
trap cleanup EXIT

hamsh_boot "$LOG" "$ELF"
hamsh_wait_boot "[hamsh] M16.35 shell ready" "$BOOT_WAIT" \
    || verdict_inconclusive "$TAG" "hamsh never reached its prompt in ${BOOT_WAIT}s (host-starved?)"
hamsh_sync 120 \
    || verdict_inconclusive "$TAG" "readline never echoed FEEDER_SYNC — stdin not consumed"

drive_step() {                      # $1 = command   $2 = barrier marker
    hamsh_send "$1"
    hamsh_send_await "echo $2" "$2" "$CMD_WAIT" || true
}

# 1. Non-resolving source: /nonexistent/src is covered by the boot
#    `/` -> #r root but names no cpio file/dir. Must ERROR. Capture
#    $status on the VERY NEXT line (before any barrier resets it).
drive_step "echo NR_BEGIN"          NR_BEGIN_MARK
hamsh_send "bind /nonexistent/src /nx_dst"
hamsh_send_await 'echo NRBIND_RC=$status' "NRBIND_RC=" "$CMD_WAIT" || true
drive_step "echo NR_END"            NR_END_MARK

# 2. Regression: an EXISTING cpio directory source SUCCEEDS silently.
drive_step "echo GOOD_BEGIN"        GOOD_BEGIN_MARK
hamsh_send "bind /etc /nx_good"
hamsh_send_await 'echo GOODBIND_RC=$status' "GOODBIND_RC=" "$CMD_WAIT" || true
drive_step "echo GOOD_END"          GOOD_END_MARK

# 3. Regression: a DEVICE-server source ('#c') SUCCEEDS silently.
drive_step "echo DEV_BEGIN"         DEV_BEGIN_MARK
hamsh_send "bind '#c' /nx_dev"
hamsh_send_await 'echo DEVBIND_RC=$status' "DEVBIND_RC=" "$CMD_WAIT" || true
drive_step "echo DEV_END"           DEV_END_MARK

hamsh_send 'exit'
sleep 2

echo "[$TAG] --- captured output (tail) ---"
tail -200 "$LOG" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r//g'
echo "[$TAG] --- end ---"

CLEAN=$(mktemp)
sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b[()][AB0]//g' -e 's/\r//g' \
    "$LOG" > "$CLEAN"

# Nothing observed at all -> INCONCLUSIVE, not a FAIL.
verdict_boot_gate "$TAG" "$CLEAN" 0 '(NR|GOOD|DEV)_BEGIN'

fail=0

# (a) UNFORGEABLE: the KERNEL-generated errstr fired. This phrase is
#     produced by do_bind's set_current_errstr, pulled into hamsh's
#     errstr_buf, and printed by run_builtin — it is absent from every
#     typed line.
if grep -a -F -q "does not resolve" "$CLEAN"; then
    echo "[$TAG] OK: non-resolving bind emitted the kernel error ('... does not resolve ...')"
else
    echo "[$TAG] MISS: non-resolving bind produced NO kernel error (silent no-op regressed?)"
    fail=1
fi

# (b) UNFORGEABLE: the failing bind set a non-zero shell status.
#     "NRBIND_RC=1" can only come from hamsh expanding $status.
if grep -a -F -q "NRBIND_RC=1" "$CLEAN"; then
    echo "[$TAG] OK: non-resolving bind set non-zero status (NRBIND_RC=1)"
else
    echo "[$TAG] MISS: non-resolving bind did NOT set non-zero status"
    grep -a -F "NRBIND_RC=" "$CLEAN" | sed 's/^/    /'
    fail=1
fi

# (c) Regression: the legit cpio-dir bind SUCCEEDED (status 0).
if grep -a -F -q "GOODBIND_RC=0" "$CLEAN"; then
    echo "[$TAG] OK: legit source 'bind /etc /nx_good' succeeded (GOODBIND_RC=0)"
else
    echo "[$TAG] FAIL: legit 'bind /etc /nx_good' did NOT succeed — false-reject!"
    grep -a -F "GOODBIND_RC=" "$CLEAN" | sed 's/^/    /'
    fail=1
fi

# (d) Regression: the legit bind emitted NO error line in its window.
if awk '/GOOD_BEGIN/{a=1;next} /GOOD_END/{a=0} a' "$CLEAN" \
        | grep -a -E -q 'bind:|does not resolve'; then
    echo "[$TAG] FAIL: an error line appeared for the legit source bind"
    fail=1
else
    echo "[$TAG] OK: legit source bind produced no error line"
fi

# (e) Regression: a device-server source ('#c') SUCCEEDED (status 0).
if grep -a -F -q "DEVBIND_RC=0" "$CLEAN"; then
    echo "[$TAG] OK: device source \"bind '#c' /nx_dev\" succeeded (DEVBIND_RC=0)"
else
    echo "[$TAG] FAIL: \"bind '#c' /nx_dev\" did NOT succeed — device source false-rejected!"
    grep -a -F "DEVBIND_RC=" "$CLEAN" | sed 's/^/    /'
    fail=1
fi

[ "$fail" -eq 0 ] \
    || verdict_fail "$TAG" "a bind non-resolving-source assertion was VIOLATED (see MISS:/FAIL lines)."
verdict_pass "$TAG" "non-resolving bind errors (kernel errstr + non-zero status); legit cpio/device sources still bind."
