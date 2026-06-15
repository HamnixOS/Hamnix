#!/usr/bin/env bash
# scripts/test_bind.sh — Plan-9 namespace bind(2)/mount(2)/unmount(2).
#
# Boots the kernel once with /etc/bind-test planted (ENABLE_BIND_TEST=1)
# plus two cpio source-dir fixtures; init/main.ad at boot:37.bind calls
# bind_selftest() (sys/src/9/port/bind_test.ad), which exercises the REAL
# namespace machinery and reads backing bytes THROUGH each bound name.
#
# UNFORGEABLE assertions the kernel self-test prints as [bind] lines,
# all of which this script requires:
#   * REDIRECT: bind /bind_src_a -> /bind_union, then /bind_union/onlyA.txt
#     reads 'AAA' (a bare table record could not make a NEW name resolve
#     to A's bytes — only a walk that consults the mount table does)
#   * UNION (MBEFORE): with /bind_src_b unioned over /bind_src_a, BOTH
#     /bind_union/onlyA.txt ('AAA') AND /bind_union/onlyB.txt ('BBB') are
#     visible at the one union point, and the shared name resolves to the
#     MBEFORE member ('FROM-B', shadowing the base 'FROM-A')
#   * UNMOUNT: after unmounting everything at /bind_union, neither
#     /bind_union/onlyA.txt nor /bind_union/onlyB.txt resolves (reverted)
#   * ISOLATION: a bind in a cloned child Pgrp is visible in the child
#     but NOT after restoring the parent Pgrp (binds are per-namespace)
#   * UNION (MAFTER): on a fresh /bind_union2, with /bind_src_a as the
#     MREPL base and /bind_src_b added with MAFTER, BOTH /bind_union2/
#     onlyA.txt ('AAA') AND /bind_union2/onlyB.txt ('BBB') resolve, AND
#     the shared name resolves to 'FROM-A' (the base — REVERSE of MBEFORE)
#   * the [bind] PASS banner
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel`
# on this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_bind] PASS
# Fail marker:  [test_bind] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_bind] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_bind] (2/3) Build kernel with /etc/bind-test marker + fixtures"
INIT_ELF=build/user/init.elf ENABLE_BIND_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_bind] (3/3) Boot QEMU and run the bind self-test"
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

echo "[test_bind] --- bind self-test output ---"
grep -E "\[bind\]" "$LOG" || true
echo "[test_bind] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_bind] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Any explicit internal failure is fatal.
if grep -qF "[bind] FAIL" "$LOG"; then
    echo "[test_bind] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_bind] PASS: $label"
    else
        echo "[test_bind] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "MREPL bind redirects a walk to source A" \
    "[bind] phase1 OK: /bind_union/onlyA.txt -> 'AAA' (MREPL redirect)"
check "union member A still visible under MBEFORE" \
    "[bind] phase2 OK: union member A visible (/bind_union/onlyA.txt -> 'AAA')"
check "union member B visible at same union point" \
    "[bind] phase2 OK: union member B visible (/bind_union/onlyB.txt -> 'BBB')"
check "MBEFORE member shadows the base for a shared name" \
    "[bind] phase2 OK: MBEFORE shadows base (/bind_union/shared.txt -> 'FROM-B')"
check "unmount reverts the B branch resolution" \
    "[bind] phase3 OK: post-unmount /bind_union/onlyB.txt no longer resolves"
check "unmount reverts the A branch resolution" \
    "[bind] phase3 OK: post-unmount /bind_union/onlyA.txt no longer resolves"
check "child namespace sees its own bind" \
    "[bind] phase4 OK: child namespace sees its own bind (/iso_union/onlyB.txt -> 'BBB')"
check "parent namespace does NOT see the child bind (isolation)" \
    "[bind] phase4 OK: parent namespace does NOT see child bind (isolation holds)"
check "MAFTER base A still visible at union" \
    "[bind] phase5 OK: union base A visible (/bind_union2/onlyA.txt -> 'AAA')"
check "MAFTER member B visible at same union point" \
    "[bind] phase5 OK: MAFTER member B visible (/bind_union2/onlyB.txt -> 'BBB')"
check "MAFTER does NOT shadow base for shared name (reverse of MBEFORE)" \
    "[bind] phase5 OK: MAFTER does NOT shadow base (/bind_union2/shared.txt -> 'FROM-A')"
check "MCREATE probe sees an MCREATE member at the union point" \
    "[bind] phase6 OK: mnttab_any_mcreate_covers reports MCREATE present"
check "MCREATE target rewrites to the MCREATE member (B)" \
    "[bind] phase6 OK: mnttab_create_target picked MCREATE member B (#r/bind_src_b/newfile.txt)"
check "MCREATE back-compat: no MCREATE -> probe returns 0" \
    "[bind] phase6 OK: back-compat (no MCREATE) -> probe returns 0"
check "MCREATE back-compat: no MCREATE -> create_target returns 0 (legacy fallback)" \
    "[bind] phase6 OK: back-compat (no MCREATE) -> create_target returns 0 (legacy fallback)"
check "MCACHE-flagged bind stored harmlessly (stub) and still resolves" \
    "[bind] phase7 OK: MCACHE-flagged bind still resolves (stub stored, harmless)"
check "bind self-test PASS banner" \
    "[bind] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_bind] FAIL"
    exit 1
fi

echo "[test_bind] PASS — bind redirects the namespace walk, MBEFORE unions both members at one name, unmount reverts the bindings, and binds are per-Pgrp isolated"
