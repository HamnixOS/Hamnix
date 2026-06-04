#!/usr/bin/env bash
# scripts/test_landlock.sh — Landlock LSM round-trip + open-enforcement check.
#
# Proves the Linux-ABI Landlock syscalls (linux_abi/u_landlock.ad
# landlock_create_ruleset / landlock_add_rule / landlock_restrict_self,
# dispatched from linux_abi/u_syscalls.ad at nr 444/445/446) are a REAL
# per-task path-based deny filter — not an ENOSYS stub, and not a filter that
# never actually denies. The in-kernel landlock_selftest() (gated on the cpio
# marker /etc/landlock-test) runs the real assertions:
#   (A) landlock_create_ruleset(flags=VERSION) -> ABI version > 0
#   (B) malformed create attr (handled_access_fs==0) -> EINVAL
#   (C) create a ruleset handling READ_FILE, add a PATH_BENEATH rule allowing
#       READ under /etc/landlock-allowed, restrict_self
#   (D) open /etc/landlock-allowed/data (allowed)            -> SUCCEEDS
#   (E) open /etc/landlock-denied/data  (exists, NOT covered) -> -EACCES
#       (the denied file genuinely exists, so the deny is the RULESET, not
#        ENOENT — proving the rules truly gate the real open() through the
#        Linux-ABI open path _u_open in linux_abi/u_syscalls.ad).
# The enforcement opens are driven through the real syscall dispatch, so the
# _u_open landlock_check_open() hook is exercised end to end. The selftest does
# all the work and needs NO extra QEMU disk.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [test_landlock] PASS   (kernel prints [landlock] PASS)
# Fail marker:  [test_landlock] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

LOG=${HAMNIX_LANDLOCK_LOG:-$(mktemp)}
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_landlock] (1/3) Build userland + plant /etc/landlock-test + /init"
bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" ENABLE_LANDLOCK_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_landlock] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_landlock] (3/3) Boot QEMU (no extra disk needed)"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_landlock] --- landlock self-test output ---"
grep -a -E "\[LANDLOCK\]|\[landlock\]" "$LOG" || true
echo "[test_landlock] --- end ---"

fail=0

if grep -a -F -q "[landlock] FAIL" "$LOG"; then
    echo "[test_landlock] FAIL: kernel self-test reported an internal failure" >&2
    grep -a -F "[landlock] FAIL" "$LOG" >&2 || true
    fail=1
fi

if ! grep -a -F -q "[landlock] PASS" "$LOG"; then
    echo "[test_landlock] MISS: self-test PASS banner (expected '[landlock] PASS')" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_landlock] --- full log ---"
    cat "$LOG"
    echo "[test_landlock] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_landlock] PASS — create/add_rule/restrict_self gate real open()" \
     "through the per-task ruleset (qemu rc=$rc)"
