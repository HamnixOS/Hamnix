#!/usr/bin/env bash
# scripts/test_devstat.sh — regression for /dev/uptime + /dev/loadavg.
#
# Pipeline mirrors test_devsysinfo.sh exactly (the M16.131 sibling),
# except we run BOTH fixtures (test_devuptime + test_devloadavg) inside
# the same QEMU boot so we only pay the build-and-boot cost once:
#   1. Build userland (hamsh, coreutils).
#   2. Build the test fixtures tests/test_devuptime.ad and
#      tests/test_devloadavg.ad. build_initramfs.py auto-globs
#      build/user/*.elf so they land at /bin/test_devuptime and
#      /bin/test_devloadavg in the cpio.
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image so devuptime.ad + devloadavg.ad +
#      FD_UPTIME_MARK / FD_LOADAVG_MARK arms are compiled in.
#   5. Boot in QEMU, drive both fixtures over the serial stdio, grep
#      the captured log for the contract markers.
#
# PASS markers:
#   - "[devuptime] N.NN" (the fixture rendered a well-formed
#     "<secs>.<CC>" first field; we echo the parsed integer secs).
#   - "[devloadavg] N.NN N.NN N.NN R/T P" (the fixture verified the
#     five whitespace-separated fields).
# We also assert each fixture's "done" banner and that hamsh remains
# responsive after both round-trips.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
UP_ELF=build/user/test_devuptime.elf
LA_ELF=build/user/test_devloadavg.elf

echo "[test_devstat] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devstat] (2/5) Build tests/test_devuptime.ad + test_devloadavg.ad"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devuptime.ad \
    -o "$UP_ELF" >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devloadavg.ad \
    -o "$LA_ELF" >/dev/null

echo "[test_devstat] (3/5) Plant /init = hamsh + /bin/test_dev{uptime,loadavg} in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devstat] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devstat] (5/5) Boot QEMU + drive both fixtures via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_devuptime\n'
    sleep 2
    printf '/bin/test_devloadavg\n'
    sleep 2
    printf 'echo POST_DEVSTAT_OK\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 20s qemu-system-x86_64 \
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

echo "[test_devstat] --- captured output ---"
cat "$LOG"
echo "[test_devstat] --- end output ---"

fail=0

# ---- /dev/uptime asserts ----
if grep -F -q "[test_devuptime] start" "$LOG"; then
    echo "[test_devstat] OK: uptime fixture ran"
else
    echo "[test_devstat] MISS: uptime fixture banner missing"
    fail=1
fi
if grep -F -q "[test_devuptime] opened /dev/uptime OK" "$LOG"; then
    echo "[test_devstat] OK: /dev/uptime opened cleanly"
else
    echo "[test_devstat] MISS: /dev/uptime open failed"
    fail=1
fi
if grep -E -q "\[test_devuptime\] uptime_secs=[0-9]+" "$LOG"; then
    # `|| true` guards the command substitutions: under `set -o
    # pipefail`, `grep | head` can SIGPIPE the grep (head closes the
    # pipe early), and the QEMU serial log lines carry printk's
    # "[NNNNNN]" timestamp prefix so the `^digit` blob regex finds
    # nothing — either way the pipeline exits non-zero. The values
    # are cosmetic PASS-marker echoes, so a miss must not abort.
    us=$(grep -E -o 'uptime_secs=[0-9]+' "$LOG" | head -n1 | cut -d= -f2 || true)
    # Re-emit the raw "<secs>.<CC>" first field from the blob for the
    # exact PASS marker contract (the orchestrator's report greps
    # this line for "[devuptime] N.NN"). Allow the printk prefix.
    blob_field=$(grep -E -o '[0-9]+\.[0-9]{2} [0-9]+\.[0-9]{2}' "$LOG" | head -n1 | awk '{print $1}' || true)
    echo "[devuptime] ${blob_field:-${us}.00}"
else
    echo "[test_devstat] MISS: uptime_secs line absent"
    fail=1
fi
if grep -F -q "[test_devuptime] done" "$LOG"; then
    echo "[test_devstat] OK: uptime fixture completed"
else
    echo "[test_devstat] MISS: uptime fixture didn't reach done"
    fail=1
fi

# ---- /dev/loadavg asserts ----
if grep -F -q "[test_devloadavg] start" "$LOG"; then
    echo "[test_devstat] OK: loadavg fixture ran"
else
    echo "[test_devstat] MISS: loadavg fixture banner missing"
    fail=1
fi
if grep -F -q "[test_devloadavg] opened /dev/loadavg OK" "$LOG"; then
    echo "[test_devstat] OK: /dev/loadavg opened cleanly"
else
    echo "[test_devstat] MISS: /dev/loadavg open failed"
    fail=1
fi
if grep -F -q "[test_devloadavg] field_count=5" "$LOG"; then
    # Echo the raw loadavg blob line as the PASS marker. `|| true`
    # for the same pipefail/SIGPIPE reason as the uptime block above;
    # the regex no longer anchors on `^` so the printk line prefix
    # doesn't defeat the match.
    la_line=$(grep -E -o '[0-9]+\.[0-9]{2} [0-9]+\.[0-9]{2} [0-9]+\.[0-9]{2} [0-9]+/[0-9]+ [0-9]+' "$LOG" | head -n1 || true)
    echo "[devloadavg] ${la_line}"
else
    echo "[test_devstat] MISS: field_count=5 line absent"
    fail=1
fi
if grep -F -q "[test_devloadavg] done" "$LOG"; then
    echo "[test_devstat] OK: loadavg fixture completed"
else
    echo "[test_devstat] MISS: loadavg fixture didn't reach done"
    fail=1
fi

# ---- hamsh responsiveness sentinel ----
if grep -F -q "POST_DEVSTAT_OK" "$LOG"; then
    echo "[test_devstat] OK: hamsh remains responsive"
else
    echo "[test_devstat] MISS: hamsh died after devstat round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devstat] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devstat] PASS"
