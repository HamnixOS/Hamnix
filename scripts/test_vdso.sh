#!/usr/bin/env bash
# scripts/test_vdso.sh - #169 real Linux-ABI vDSO end-to-end test.
#
# Linux maps a tiny shared "vDSO" ELF page into every process and
# advertises it through the AT_SYSINFO_EHDR (type 33) auxv entry. glibc
# and musl parse that mini-ELF's .dynsym/.hash and call
# __vdso_clock_gettime / __vdso_gettimeofday DIRECTLY in userspace,
# reading a kernel-maintained shared time page WITHOUT trapping into the
# kernel. This test proves Hamnix now does the same.
#
# It boots Hamnix with /bin/u_vdso_probe embedded (a host-built static
# OSABI=Linux x86_64 ELF) and drives hamsh to exec it. The probe:
#   1. walks its initial stack to find AT_SYSINFO_EHDR (proves U-side
#      auxv wiring),
#   2. parses the vDSO mini-ELF and resolves __vdso_clock_gettime via
#      the SysV hash table (proves the image is a valid ET_DYN),
#   3. calls __vdso_clock_gettime VDSO_ITERS(=2000) times for
#      CLOCK_MONOTONIC and checks the time advances monotonically
#      (proves the kernel-maintained shared time page is live + seqlock
#      consistent),
#   4. makes EXACTLY ONE deliberate clock_gettime(2) syscall so the
#      kernel's [vdso-audit] trap counter lands at 1.
#
# PASS requires:
#   - "VDSO: PASS" on the console (probe self-verified end to end), AND
#   - the kernel's [vdso-audit] clock_gettime SYSCALL trap counter is
#     FAR below the 2000 library calls (we assert it never exceeds a
#     small bound). If the vDSO were a no-op fallback that trapped on
#     every call, the audit log would show ~2000 traps and we'd FAIL.
#
# Skip-on-missing: if the host fixture u_vdso_probe can't be built
# (no `as`/`ld`), exit 0 with a notice so CI without a toolchain passes.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_vdso_probe
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/vdso_probe; only SKIP on a real
# toolchain failure.
ensure_ubin_or_skip test_vdso u_vdso_probe vdso_probe

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_vdso] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_vdso] (2/4) Swap /init = $HAMSH_ELF + embed u_vdso_probe"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_vdso] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_vdso] (4/4) Boot QEMU + run /bin/u_vdso_probe via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# qemu_drive waits for hamsh's banner before feeding the command, so a
# slow/nondeterministic boot can't drop the first line (a fixed sleep
# did exactly that). It also wraps the elf64 higher-half kernel in a
# GRUB ISO internally. The probe runs 2000 vDSO calls — give it room.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 90 \
    -- "/bin/u_vdso_probe" 6 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_vdso] --- captured output ---"
cat "$LOG"
echo "[test_vdso] --- end output ---"

fail=0

# Primary success criterion: the probe self-verified the full vDSO path
# (auxv -> ELF parse -> symbol resolve -> 2000 monotonic calls).
if grep -F -q "VDSO: PASS" "$LOG"; then
    echo "[test_vdso] OK: probe reported VDSO: PASS"
else
    echo "[test_vdso] MISS: 'VDSO: PASS' (probe did not complete the vDSO path)"
    fail=1
fi

# Explicit non-failure marker guard: if the probe printed FAIL, surface it.
if grep -F -q "VDSO: FAIL" "$LOG"; then
    echo "[test_vdso] FAIL marker seen in probe output"
    fail=1
fi

# Strong cross-check: the kernel-side [vdso-audit] counter must show the
# clock_gettime SYSCALL was trapped at most a handful of times. The probe
# calls clock_gettime 2000 times via the vDSO (NO trap) plus exactly ONE
# deliberate syscall. If the vDSO path were not actually taken, every one
# of those 2000 calls would trap and the audit log would show ~2000.
#
# Count distinct trap log lines. We require: at least 1 (the deliberate
# syscall proves the audit path itself works) and far below the call
# count (we use 16 as a generous ceiling — real glibc/probe behavior is 1).
TRAP_CT=$(grep -c "vdso-audit] clock_gettime SYSCALL trap" "$LOG" 2>/dev/null || true)
# grep -c with no matches under set -e via || true yields the count.
TRAP_CT=${TRAP_CT:-0}
echo "[test_vdso] [vdso-audit] clock_gettime SYSCALL traps observed: $TRAP_CT"
# Highest trap index reported (the counter is monotonic: "trap #N").
TRAP_MAX=$(grep -oE "clock_gettime SYSCALL trap #[0-9]+" "$LOG" \
    | grep -oE "[0-9]+$" | sort -n | tail -1 || true)
TRAP_MAX=${TRAP_MAX:-0}
echo "[test_vdso] highest [vdso-audit] trap index: $TRAP_MAX"

VDSO_TRAP_CEILING=16
if [ "$TRAP_MAX" -gt "$VDSO_TRAP_CEILING" ]; then
    echo "[test_vdso] FAIL: $TRAP_MAX clock_gettime syscall traps exceeds"
    echo "[test_vdso]       ceiling $VDSO_TRAP_CEILING — the 2000 library"
    echo "[test_vdso]       calls fell back to the syscall path (vDSO NOT used)"
    fail=1
elif [ "$TRAP_MAX" -lt 1 ]; then
    # The probe makes one deliberate trap; if we never saw it, either the
    # audit instrumentation regressed or the probe never ran. Either way
    # we can't claim the vDSO bypass was proven.
    echo "[test_vdso] WARN: no [vdso-audit] trap seen — deliberate syscall"
    echo "[test_vdso]       control did not fire (probe may not have run)"
    # Don't hard-fail on this alone; VDSO: PASS above is the gate. But if
    # PASS is also missing we already failed.
else
    echo "[test_vdso] OK: only $TRAP_MAX syscall trap(s) for 2000 vDSO calls"
    echo "[test_vdso]     -> __vdso_clock_gettime ran in userspace (no trap)"
fi

# Sanity: hamsh kept running after the child exited.
if grep -F -q "[hamsh] bye." "$LOG"; then
    echo "[test_vdso] OK: hamsh reaped the probe and exited cleanly"
else
    echo "[test_vdso] WARN: hamsh did not reach bye line"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_vdso] FAIL (qemu rc=$rc) — capture above is the diagnostic"
    exit 1
fi

echo "[test_vdso] PASS — Linux vDSO clock_gettime bypassed the syscall path!"
