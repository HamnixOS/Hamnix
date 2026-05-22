#!/usr/bin/env bash
# scripts/test_devid.sh — regression for /dev/version + /dev/hostname.
#
# Pipeline mirrors test_devsysinfo.sh / test_devstat.sh exactly, except
# we run BOTH fixtures (test_devversion + test_devhostname) inside the
# same QEMU boot so we only pay the build-and-boot cost once:
#   1. Build userland (hamsh, coreutils).
#   2. Build the test fixtures tests/test_devversion.ad and
#      tests/test_devhostname.ad. build_initramfs.py auto-globs
#      build/user/*.elf so they land at /bin/test_devversion and
#      /bin/test_devhostname in the cpio.
#   3. Plant hamsh as /init.
#   4. Rebuild the kernel image so devversion.ad + devhostname.ad +
#      FD_VERSION_MARK / FD_HOSTNAME_MARK arms are compiled in.
#   5. Boot in QEMU, drive both fixtures over the serial stdio, grep
#      the captured log for the contract markers.
#
# PASS markers:
#   - "[devversion] contains_hamnix=1" (the fixture confirmed the
#     /dev/version blob contains the "hamnix" substring — re-emitted
#     without the test prefix so the orchestrator contract is grep-
#     stable).
#   - "[devhostname] roundtrip_ok=1" (the fixture read the initial
#     hostname "hamnix", wrote "test-host", and read it back).
# We also assert each fixture's "done" banner and that hamsh remains
# responsive after both round-trips.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
VER_ELF=build/user/test_devversion.elf
HN_ELF=build/user/test_devhostname.elf

echo "[test_devid] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_devid] (2/5) Build tests/test_devversion.ad + test_devhostname.ad"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devversion.ad \
    -o "$VER_ELF" >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_devhostname.ad \
    -o "$HN_ELF" >/dev/null

echo "[test_devid] (3/5) Plant /init = hamsh + /bin/test_dev{version,hostname} in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_devid] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_devid] (5/5) Boot QEMU + drive both fixtures via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_devversion\n'
    sleep 2
    printf '/bin/test_devhostname\n'
    sleep 2
    printf 'echo POST_DEVID_OK\n'
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

echo "[test_devid] --- captured output ---"
cat "$LOG"
echo "[test_devid] --- end output ---"

fail=0

# ---- /dev/version asserts ----
if grep -F -q "[test_devversion] start" "$LOG"; then
    echo "[test_devid] OK: version fixture ran"
else
    echo "[test_devid] MISS: version fixture banner missing"
    fail=1
fi
if grep -F -q "[test_devversion] opened /dev/version OK" "$LOG"; then
    echo "[test_devid] OK: /dev/version opened cleanly"
else
    echo "[test_devid] MISS: /dev/version open failed"
    fail=1
fi
if grep -F -q "[test_devversion] contains_hamnix=1" "$LOG"; then
    echo "[devversion] contains_hamnix=1"
else
    echo "[test_devid] MISS: contains_hamnix=1 line absent"
    fail=1
fi
if grep -F -q "[test_devversion] done" "$LOG"; then
    echo "[test_devid] OK: version fixture completed"
else
    echo "[test_devid] MISS: version fixture didn't reach done"
    fail=1
fi

# ---- /dev/hostname asserts ----
if grep -F -q "[test_devhostname] start" "$LOG"; then
    echo "[test_devid] OK: hostname fixture ran"
else
    echo "[test_devid] MISS: hostname fixture banner missing"
    fail=1
fi
if grep -F -q "[test_devhostname] initial_ok=1" "$LOG"; then
    echo "[test_devid] OK: /dev/hostname initial read = hamnix"
else
    echo "[test_devid] MISS: initial_ok=1 absent (initial hostname != hamnix?)"
    fail=1
fi
if grep -F -q "[test_devhostname] roundtrip_ok=1" "$LOG"; then
    echo "[devhostname] roundtrip_ok=1"
else
    echo "[test_devid] MISS: roundtrip_ok=1 absent (write didn't stick?)"
    fail=1
fi
if grep -F -q "[test_devhostname] done" "$LOG"; then
    echo "[test_devid] OK: hostname fixture completed"
else
    echo "[test_devid] MISS: hostname fixture didn't reach done"
    fail=1
fi

# ---- hamsh responsiveness sentinel ----
if grep -F -q "POST_DEVID_OK" "$LOG"; then
    echo "[test_devid] OK: hamsh remains responsive"
else
    echo "[test_devid] MISS: hamsh died after devid round-trip"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_devid] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_devid] PASS"
