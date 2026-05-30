#!/usr/bin/env bash
# scripts/test_crond.sh — verify the native cron daemon fires a job.
#
# Chain under test:
#   1. user/crontab.ad installs a crontab at /var/cron/crontab (the
#      writable /var tmpfs subtree) from a file in /tmp.
#   2. user/crond.ad reads /proc/realtime (RTC + TSC wall clock), polls
#      every few seconds via sys_get_jiffies, and on each MINUTE EDGE
#      re-reads the crontab and fires every matching job.
#   3. A `* * * * * /bin/echo CRON_FIRED_SENTINEL` entry fires every
#      minute. crond logs `crond: fired ... at <ISO-8601>` to stdout and
#      the spawned echo prints CRON_FIRED_SENTINEL — both land on the
#      serial console.
#
# Because crond fires on the wall-clock minute edge, the test must let
# at least one minute roll over after crond starts. We give crond ~80 s
# of guest time (QEMU's emulated RTC tracks the host clock, so a real
# minute boundary is crossed) and then assert the fire log appears.
#
# Assertions (in the QEMU serial log):
#   - hamsh reached its interactive loop (boot got to userland)
#   - `crontab -l` echoed the installed entry back (install path works)
#   - "crond: started" appears (the daemon launched)
#   - "crond: fired" appears at least once (the minute-edge scheduler
#     evaluated and matched the every-minute job)
#   - "CRON_FIRED_SENTINEL" appears (the spawned command actually ran)
#
# DRIVER: uses _qemu_drive.sh so input waits for hamsh's banner before
# keystrokes land — same pattern as scripts/test_date.sh.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
CROND_ELF=build/user/crond.elf
CRONTAB_ELF=build/user/crontab.elf

echo "[test_crond] (1/4) Build userland (crond + crontab + hamsh)"
bash scripts/build_user.sh >/dev/null
for elf in "$CROND_ELF" "$CRONTAB_ELF" "$HAMSH_ELF"; do
    if [ ! -s "$elf" ]; then
        echo "[test_crond] FAIL: $elf missing or empty after build."
        exit 1
    fi
done

echo "[test_crond] (2/4) Plant hamsh as /init in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_crond] (3/4) Rebuild kernel"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_crond] (4/4) Boot QEMU + install crontab, run crond, wait a minute"
LOG=$(mktemp /tmp/test-crond.XXXXXX.log)
# Restore /init = init.elf on the way out so the next test isn't
# surprised by an "init = hamsh" initramfs.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# The crontab line: every-minute job that spawns /bin/echo with a
# unique sentinel. crond spawns by absolute path (it does NOT do PATH
# resolution), so /bin/echo is spelled out.
#
# Build the crontab file in /tmp with `echo > file`, install it with
# `crontab`, list it back, then launch crond in the background (`&`) so
# the shell stays interactive while crond's minute loop runs.
#
# Overall timeout 240 s: boot (~30-60 s) + a 75 s post-`crond &` wait
# (one wall-clock minute always rolls over inside it, so the every-
# minute job fires at least once) + headroom for the `exit` to land so
# QEMU shuts down cleanly (rc 0) rather than being timeout-killed.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 240 \
    -- "echo '* * * * * /bin/echo CRON_FIRED_SENTINEL' > /tmp/mycron"  2 \
       "crontab /tmp/mycron"                                            2 \
       "echo CRONTAB_LIST_BEGIN"                                        2 \
       "crontab -l"                                                     2 \
       "echo CRONTAB_LIST_END"                                          2 \
       "crond &"                                                       75 \
       "echo DONE_WAITING"                                              2 \
       "exit"                                                           1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_crond] --- captured ---"
cat "$LOG"
echo "[test_crond] --- end ---"

fail=0

# NOTE: the serial log carries readline/console control bytes, so grep
# would treat it as a binary file and suppress text matches — every
# grep here uses -a (treat as text) for that reason.

# hamsh came up.
if ! grep -a -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[test_crond] FAIL: hamsh never reached the interactive loop"
    fail=1
fi

# crontab -l echoed the entry back (install + list path works).
list_block=$(sed -n '/CRONTAB_LIST_BEGIN/,/CRONTAB_LIST_END/p' "$LOG")
if echo "$list_block" | grep -a -F -q "* * * * * /bin/echo CRON_FIRED_SENTINEL"; then
    echo "[test_crond] OK: crontab -l shows the installed entry"
else
    echo "[test_crond] FAIL: crontab -l did not echo the installed entry"
    echo "[test_crond]   captured LIST block:"
    echo "$list_block" | sed 's/^/[test_crond]     /'
    fail=1
fi

# crond launched.
if grep -a -F -q "crond: started" "$LOG"; then
    echo "[test_crond] OK: crond started"
else
    echo "[test_crond] FAIL: 'crond: started' not seen — daemon never launched"
    fail=1
fi

# crond fired the job (minute-edge scheduler matched).
if grep -a -F -q "crond: fired" "$LOG"; then
    echo "[test_crond] OK: crond fired a job"
else
    echo "[test_crond] FAIL: 'crond: fired' not seen — scheduler never matched"
    fail=1
fi

# The spawned command actually RAN (not just "matched + logged"). When
# crond sys_spawns /bin/echo the kernel's user-ELF runtime prints
# "[runtime:echo] _start" as the child enters userland — a marker that
# only appears because crond actually launched the binary. We require
# it to confirm the fire is a real spawn, not just a log line. (The raw
# serial stream uses bare CRs, so the echo's own CRON_FIRED_SENTINEL
# output can share a physical line with the "crond: fired" log; the
# _start marker is the unambiguous spawn proof.)
if grep -a -F -q "[runtime:echo] _start" "$LOG"; then
    echo "[test_crond] OK: crond spawned /bin/echo (runtime _start seen)"
else
    echo "[test_crond] FAIL: no '[runtime:echo] _start' — the fired job never executed"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_crond] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_crond] PASS (qemu rc=$rc)"
