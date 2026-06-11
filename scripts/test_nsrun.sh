#!/usr/bin/env bash
# scripts/test_nsrun.sh — smoke for the nsrun shim launcher
# (user/nsrun.ad).
#
# nsrun runs a program in a FRESH private namespace whose /var, /usr,
# and /etc are each served by a live distrofs 9P daemon. This test
# proves BOTH halves of the Plan 9 invariant with one fixture binary
# (tests/test_nsrun.ad) run several ways from hamsh:
#
#   A. `/bin/nsrun /bin/test_nsrun write`
#      nsrun spawns THREE distrofs daemons (one per subtree), clones
#      the namespace, mounts them at /var, /usr, /etc, then exec's the
#      fixture in "write" mode. The fixture creates + writes + reads
#      back a probe file under EACH of /var/lib/dpkg/, /usr/, /etc/ —
#      paths the initramfs does NOT ship — so a successful round trip
#      proves the ops landed on the distrofs daemons.
#
#   B. `/bin/test_nsrun probe`   (bare — NO nsrun)
#      In the plain shell namespace. /var here is the initramfs view
#      (ships /var/www/* but nothing under /var/lib/dpkg/). The fixture
#      asserts /var/lib/dpkg/nsrun_probe is NOT openable — proving the
#      write from run A did not leak into the parent's namespace.
#
#   C, D. `/bin/nsrun /bin/test_nsrun write` (x2 more)
#      The second and third sequential nsrun invocations. They reuse
#      the same low srvfd numbers run A used; with the p9_conns leak
#      fixed, their mounts MUST still succeed (fresh connection slots).
#
# CONCURRENCY: the /srv post name carries the launcher pid
# (nsrun.distrofs.<pid>.<sub>) so two concurrent nsrun invocations get
# distinct /srv names and never collide. We assert the [nsrun] pid=
# marker is present; a second nsrun run (run C) proves a fresh pid is
# used and its mounts work independently.
#
# CONNECTION-TABLE LEAK FIX: the in-kernel 9P client's p9_conns table
# (sys/src/9/port/9p_client.ad) is now released — on unmount and on
# task exit (chan.ad's mnttab_unmount + pgrp_ref_dec call p9c_detach).
# A 9P connection is owned by the namespace mount entry, refcounted so
# rfork(RFNAMEG) clones share it safely. Because of this, a SECOND and
# THIRD sequential nsrun each get FRESH connection slots even though
# they reuse the same low srvfd numbers. This test runs nsrun THREE
# times sequentially (runs A, C, D) and asserts EVERY run's mounts
# succeed — proving the table no longer leaks.
#
# Pipeline (same shape as scripts/test_9p_realfd.sh):
#   1. Build userland (hamsh + coreutils + distrofs + nsrun).
#   2. Build tests/test_nsrun.ad -> build/user/test_nsrun.elf.
#   3. Plant /init = hamsh.elf.
#   4. Rebuild the kernel image.
#   5. Boot QEMU, drive the invocations over serial, exit.
#   6. Grep the serial log for the markers.
#
# MARKERS asserted (from user/nsrun.ad + tests/test_nsrun.ad):
#   [nsrun] pid=<n>
#   [nsrun] distrofs daemon spawned
#   [nsrun] private namespace cloned
#   [nsrun] distrofs mounted at /var
#   [nsrun] distrofs mounted at /usr
#   [nsrun] distrofs mounted at /etc
#   [nsrun] exec target in namespace
#   [nsrun_test] mode=write
#   [nsrun_test] write OK
#   [nsrun_test] payload OK         (round trip byte-exact, /var, run A)
#   [nsrun_test] usr OK             (round trip byte-exact, /usr, run A)
#   [nsrun_test] etc OK             (round trip byte-exact, /etc, run A)
#   [nsrun_test] mode=probe
#   [nsrun_test] isolation OK       (parent /var/lib/dpkg empty, run B)

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_nsrun.elf

echo "[test_nsrun] (1/5) Build userland (hamsh + coreutils + distrofs + nsrun)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_nsrun] (2/5) Build tests/test_nsrun.ad -> $TEST_ELF"
mkdir -p build/user
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_nsrun.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_nsrun] (3/5) Plant /init = hamsh + /bin/test_nsrun in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_nsrun] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_nsrun] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Marker-gated feeder (same proven shape as test_distrofs_persist.sh):
    # a freshly-booted hamsh sometimes drops the FIRST serial command line
    # (it never echoes), and fixed sleeps race a slowing boot. Gate on the
    # shell-ready marker, RE-SEND each command until its echo shows up in
    # the log (cumulative count — runs A/C/D reuse the same command text),
    # and gate run-to-run pacing on the fixture's own PASS lines. All the
    # count assertions below are >=, so a rare double-driven run only adds
    # runs and can never turn a pass into a fail.
    for _ in $(seq 1 40); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    # send_cmd CMD ECHO_WANT: type CMD, re-send until the log holds at
    # least ECHO_WANT echo lines of it.
    send_cmd() {
        printf '%s\n' "$1"
        for _ in $(seq 1 10); do
            sleep 1.5
            [ "$(grep -a -c -F "$1" "$LOG" 2>/dev/null || true)" -ge "$2" ] && break
            printf '%s\n' "$1"
        done
    }
    # wait_pass N: wait until N cumulative '[nsrun_test] PASS' lines.
    wait_pass() {
        for _ in $(seq 1 40); do
            [ "$(grep -a -c -F '[nsrun_test] PASS' "$LOG" 2>/dev/null || true)" -ge "$1" ] && break
            sleep 0.5
        done
    }
    # Run A: round trip inside the nsrun-built distrofs namespace
    # (/var, /usr, /etc all distrofs-backed).
    send_cmd '/bin/nsrun /bin/test_nsrun write' 1
    wait_pass 1
    # Run B: bare isolation probe in the plain shell namespace.
    send_cmd '/bin/test_nsrun probe' 1
    wait_pass 2
    # Run C: a SECOND nsrun invocation. It gets a fresh pid, hence
    # fresh /srv post names (nsrun.distrofs.<pid>.<sub>) — proving two
    # nsrun runs don't collide on /srv. Its own three daemons back its
    # own private /var, /usr, /etc trees. With the p9_conns leak fixed,
    # its mounts MUST succeed even though it reuses the same low srvfd
    # numbers run A used (run A's conns were detached when run A's
    # exec'd target exited and its Pgrp was freed).
    send_cmd '/bin/nsrun /bin/test_nsrun write' 2
    wait_pass 3
    # Run D: a THIRD sequential nsrun invocation — the acceptance bar
    # for the connection-table-leak fix is "3+ sequential runs all
    # succeed". Like run C, it reuses low srvfd numbers and MUST get
    # fresh connection slots.
    send_cmd '/bin/nsrun /bin/test_nsrun write' 3
    wait_pass 4
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 150s qemu-system-x86_64 \
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

echo "[test_nsrun] --- captured output ---"
cat "$LOG"
echo "[test_nsrun] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_nsrun] OK: $label"
    else
        echo "[test_nsrun] MISS: $label ($marker)"
        fail=1
    fi
}

# Any per-assertion FAIL line means a round-trip / isolation check broke.
if grep -a -F -q "[nsrun_test] FAIL:" "$LOG"; then
    echo "[test_nsrun] MISS: per-assertion FAIL line(s) present:"
    grep -a -F "[nsrun_test] FAIL:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_nsrun] OK: no per-assertion FAIL lines"
fi

# nsrun launcher steps (run A).
check_marker "[nsrun] pid="                      "nsrun reported its pid"
check_marker "[nsrun] distrofs daemon spawned"   "nsrun spawned distrofs"
check_marker "[nsrun] private namespace cloned"  "nsrun rfork(RFNAMEG)"
check_marker "[nsrun] distrofs mounted at /var"  "nsrun mounted distrofs /var"
check_marker "[nsrun] distrofs mounted at /usr"  "nsrun mounted distrofs /usr"
check_marker "[nsrun] distrofs mounted at /etc"  "nsrun mounted distrofs /etc"
check_marker "[nsrun] exec target in namespace"  "nsrun exec'd the target"
# Round trip inside the namespace (run A) — all three subtrees.
check_marker "[nsrun_test] mode=write"  "fixture ran in write mode"
check_marker "[nsrun_test] write OK"    "create+write on distrofs /var"
check_marker "[nsrun_test] payload OK"  "byte-exact round trip on distrofs /var"
check_marker "[nsrun_test] usr OK"      "byte-exact round trip on distrofs /usr"
check_marker "[nsrun_test] etc OK"      "byte-exact round trip on distrofs /etc"
# Isolation in the parent namespace (run B).
check_marker "[nsrun_test] mode=probe"   "fixture ran bare in probe mode"
check_marker "[nsrun_test] isolation OK" "parent /var/lib/dpkg untouched"

# Per-invocation /srv names: the post name must carry the pid so two
# concurrent nsruns never collide. Assert the suffixed-name shape is
# present in the log (the daemon-spawn path posts it).
if grep -a -E -q '\[nsrun\] pid=[0-9]+' "$LOG"; then
    echo "[test_nsrun] OK: /srv post name is per-pid (nsrun.distrofs.<pid>.<sub>)"
else
    echo "[test_nsrun] MISS: no per-pid marker — /srv name not pid-suffixed"
    fail=1
fi

# Concurrency: runs A, C and D are three SEPARATE nsrun invocations.
# Each must report a DIFFERENT pid (a fresh process) — proving the
# per-pid /srv names (nsrun.distrofs.<pid>.<sub>) are genuinely
# distinct across runs.
pids=$(grep -a -E -o '\[nsrun\] pid=[0-9]+' "$LOG" | grep -a -E -o '[0-9]+' | sort -u)
pid_count=$(echo "$pids" | grep -c . || true)
if [ "$pid_count" -ge 3 ]; then
    echo "[test_nsrun] OK: three nsrun runs used distinct pids ($(echo $pids | tr '\n' ' ')) -> distinct /srv names"
else
    echo "[test_nsrun] MISS: expected 3 distinct nsrun pids, saw $pid_count"
    fail=1
fi

# Per-run mount accounting. The connection-table-leak fix means EVERY
# sequential nsrun must mount all three subtrees — the kernel detaches
# a run's 9P connections when its exec'd target exits and its Pgrp is
# freed, so the next run gets fresh p9_conns slots even though it
# reuses the same low srvfd numbers. With three nsrun runs (A, C, D)
# each mounting /var + /usr + /etc, we expect 9 "distrofs mounted at"
# lines total. The known leak errstr ("p9c_attach (conn alloc)") must
# NOT appear at all — its presence means the table still leaks.
if grep -a -F -q "p9c_attach (conn alloc)" "$LOG"; then
    echo "[test_nsrun] MISS: 'p9c_attach (conn alloc)' present — 9P conn table still leaks"
    fail=1
else
    echo "[test_nsrun] OK: no 'p9c_attach (conn alloc)' — conn table released between runs"
fi

mount_count=$(grep -a -F -c "[nsrun] distrofs mounted at" "$LOG" || true)
if [ "$mount_count" -ge 9 ]; then
    echo "[test_nsrun] OK: all three nsrun runs mounted all three subtrees ($mount_count mount lines)"
else
    echo "[test_nsrun] MISS: expected >=9 'distrofs mounted at' lines (3 runs x 3 subtrees), saw $mount_count"
    fail=1
fi

# PASS-line accounting. Runs A (write), B (probe), C (write) and D
# (write) must ALL reach PASS. With the p9_conns leak fixed there is
# no longer a tolerated-failure case: 3+ sequential nsrun cycles MUST
# all succeed.
pass_count=$(grep -a -F -c "[nsrun_test] PASS" "$LOG" || true)
if [ "$pass_count" -ge 4 ]; then
    echo "[test_nsrun] OK: all four fixture runs reached PASS ($pass_count)"
else
    echo "[test_nsrun] MISS: expected >=4 PASS lines (runs A+B+C+D), saw $pass_count"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_nsrun] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_nsrun] PASS"
