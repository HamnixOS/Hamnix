#!/usr/bin/env bash
# scripts/test_9p_v35_userinit.sh — 9P V3.5 regression.
#
# Verifies the V3.5 Plan 9 layering:
#
#   - Kernel exposes `#X` device aliases directly (`#s`, `#p`,
#     `#c`, `#/`); they open without any namespace binding.
#   - Userspace `init` (user/init.ad) does the canonical `bind`
#     calls at boot before exec'ing hamsh.
#   - After init runs, `/srv`, `/proc/<pid>/ns`, `/n` resolve to
#     the same devices via chan_resolve_prefix rewrite.
#   - The init recipe is rendered in /proc/1/ns (three bind lines).
#
# Unlike test_9p_v3_defaults.sh, this script boots with init.elf as
# `/init` (NOT hamsh directly), proving the recipe-driven path works
# end to end. init exec's hamsh after applying binds.
#
# Markers (greppable):
#   [v35-userinit] start
#   [v35-hash-s] OK
#   [v35-hash-p] OK
#   [v35-hash-c] OK
#   [v35-hash-slot] OK
#   [v35-recipe-srv] OK
#   [v35-recipe-proc] OK
#   [v35-recipe-n] OK
#   [v35-recipe-text] OK
#   [v35-userinit] PASS

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
TEST_ELF=build/user/test_9p_v35_userinit.elf

echo "[test_9p_v35_userinit] (1/5) Build userland (init + hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_9p_v35_userinit] (2/5) Build tests/test_9p_v35_userinit.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_9p_v35_userinit.ad \
    -o "$TEST_ELF" >/dev/null

# build_initramfs.py automatically picks up build/user/init.elf and
# installs it at /init in the cpio archive (no INIT_ELF override
# needed). init applies the recipe then execs /bin/hamsh.
echo "[test_9p_v35_userinit] (3/5) Plant /init = init.elf + /bin/test_9p_v35_userinit in cpio"
python3 scripts/build_initramfs.py >/dev/null

echo "[test_9p_v35_userinit] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_9p_v35_userinit] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
(
    # init prints its progress, exec's hamsh, then we type the test
    # command into the shell prompt. Pacing matches the other V3 /
    # ns-isolation tests.
    sleep 4
    printf '/bin/test_9p_v35_userinit\n'
    sleep 4
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
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

echo "[test_9p_v35_userinit] --- captured output ---"
cat "$LOG"
echo "[test_9p_v35_userinit] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[test_9p_v35_userinit] OK: $label"
    else
        echo "[test_9p_v35_userinit] MISS: $label ($marker)"
        fail=1
    fi
}

check_marker "[v35-userinit] start"    "fixture ran"
check_marker "[v35-hash-s] OK"         "#s device alias"
check_marker "[v35-hash-p] OK"         "#p/<pid>/ns dispatch"
check_marker "[v35-hash-c] OK"         "#c console alias"
check_marker "[v35-hash-slot] OK"      "#/ root-dir slot"
check_marker "[v35-recipe-srv] OK"     "/srv after recipe bind"
check_marker "[v35-recipe-proc] OK"    "/proc/1/ns after recipe bind"
check_marker "[v35-recipe-n] OK"       "/n after recipe bind"
check_marker "[v35-recipe-text] OK"    "/proc/1/ns text shows recipe"
check_marker "[v35-userinit] PASS"     "fixture reached PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_9p_v35_userinit] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_9p_v35_userinit] PASS"
