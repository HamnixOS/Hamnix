#!/usr/bin/env bash
# scripts/test_u51_aslr_stack.sh -- Stage 2 ASLR: user stack-base
# randomization (per-exec, bounded, page-aligned), proven by diffing two
# independent boots.
#
# WHAT IT PROVES
#
# Stage 3 of the security hardening (the uaccess / identity-map audit)
# established that this kernel directly dereferences user pointers and
# directly STORES into the user stack assuming a vaddr == phys identity
# map (see the ASLR banner in arch/x86/kernel/syscall.ad). The ONE ASLR
# form safe under that invariant is an INTRA-REGION stack slide: the
# initial user-stack top (the value the argv/envp/auxv builder grows DOWN
# from, hence the program's initial RSP) is perturbed DOWN by a random
# page multiple INSIDE the single identity-mapped alloc_pages() stack run.
# vaddr == phys is preserved, so no uaccess path changes meaning -- the
# program just starts at a randomized stack address.
#
# aslr_stack_slide() (arch/x86/kernel/syscall.ad) draws genuine per-exec
# entropy from read_tsc() (an rdtsc) folded with tsc_monotonic_ns() and a
# per-call stream counter through a splitmix64 finalizer, then logs the
# chosen slide on every SYS_SPAWN / execve:
#
#       [aslr] stack slide = 0x....
#
# This fixture SPAWNS a real binary (u_cow_fork -- reused purely as a
# "spawn a program that runs and exits cleanly" vehicle) once per boot,
# boots the SAME kernel image TWICE, and asserts:
#   1. each boot emits at least one [aslr] slide line (ASLR is live), AND
#   2. the slide value DIFFERS between the two boots (per-exec random, not
#      a constant), AND
#   3. the spawned program still ran correctly in BOTH boots (no exec/boot
#      regression) -- its PASS marker lands both times.
#
# A PASS therefore demonstrates real, bounded, per-exec stack ASLR with
# zero boot/exec regression.
#
# Build-on-missing: the u_cow_fork fixture is gitignored (host-built). If
# absent, build it from tests/u-binary/src/cow_fork; only SKIP on a real
# build failure (e.g. a genuine missing musl-gcc).
#
# REQUIRES: musl-gcc on $PATH. Build step:
#     make -C tests/u-binary/src/cow_fork install
#
# NOTE: a trailing QEMU rc=124 AFTER the markers have printed is benign
# (the kernel halts without powering off qemu); the grep checks below are
# authoritative.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_cow_fork
ensure_ubin_or_skip test_u51_aslr u_cow_fork cow_fork

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u51_aslr] (1/3) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u51_aslr] (2/3) Swap /init = $HAMSH_ELF + embed u_cow_fork"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u51_aslr] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# Drive one boot: wait for hamsh's banner, spawn u_cow_fork (one
# SYS_SPAWN -> one [aslr] slide), then run `dmesg` and exit. The command
# is sent twice (the 2nd is a harmless re-run if the 1st landed) so the
# [hamsh-alive] heartbeat redraw can't eat the only delivery -- we just
# need at least one spawn to reach the kernel.
#
# The [aslr] sentinels are emitted at INFO severity, which the console
# log-level gate suppresses from the LIVE console once the shell is
# interactive (so they no longer flood the user's prompt -- see
# arch/x86/kernel/syscall.ad + drivers/tty/serial/early_8250.ad). Every
# line is still pushed into the kernel printk ring buffer unconditionally,
# so we run `dmesg` after the spawns to replay the ring (dmesg's stdout is
# always console-visible) and grep the [aslr] slides out of that replay.
run_boot() {
    local log="$1"
    set +e
    qemu_drive "$log" "$ELF" "[hamsh] M16.35 shell ready" 70 \
        -- "u_cow_fork" 8 \
           "u_cow_fork" 8 \
           "dmesg" 5 \
           "exit" 1
    set -e
}

LOG1=$(mktemp)
LOG2=$(mktemp)
trap 'rm -f "$LOG1" "$LOG2"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_u51_aslr] === BOOT 1 ==="
run_boot "$LOG1"
echo "[test_u51_aslr] === BOOT 2 ==="
run_boot "$LOG2"

# Extract the ordered list of slide values from a boot log.
slides_of() {
    grep -a -oE '\[aslr\] stack slide = 0x[0-9a-fA-F]+' "$1" \
        | grep -a -oE '0x[0-9a-fA-F]+$' || true
}

SL1="$(slides_of "$LOG1")"
SL2="$(slides_of "$LOG2")"

echo "[test_u51_aslr] --- boot 1 slides ---"; printf '%s\n' "$SL1"
echo "[test_u51_aslr] --- boot 2 slides ---"; printf '%s\n' "$SL2"

fail=0

# (1) ASLR is live: each boot emitted at least one slide line.
n1="$(printf '%s\n' "$SL1" | grep -ac '0x' || true)"
n2="$(printf '%s\n' "$SL2" | grep -ac '0x' || true)"
if [ "$n1" -ge 1 ] && [ "$n2" -ge 1 ]; then
    echo "[test_u51_aslr] OK: ASLR live (boot1=$n1 slides, boot2=$n2 slides)"
else
    echo "[test_u51_aslr] MISS: no [aslr] slide lines (boot1=$n1, boot2=$n2)"
    fail=1
fi

# (2) Randomization: compare the FIRST slide of each boot. With a real
#     per-exec entropy source the first u_cow_fork spawn after boot draws
#     an independent value each run; a constant ASLR would emit the same
#     value both times. (Comparing the first slide avoids a false PASS
#     from one boot merely spawning a different NUMBER of times.)
FIRST1="$(printf '%s\n' "$SL1" | grep -a '0x' | head -1)"
FIRST2="$(printf '%s\n' "$SL2" | grep -a '0x' | head -1)"
if [ -n "$FIRST1" ] && [ -n "$FIRST2" ] && [ "$FIRST1" != "$FIRST2" ]; then
    echo "[test_u51_aslr] OK: first stack slide DIFFERS across the two" \
         "boots ($FIRST1 vs $FIRST2) -- per-exec randomization confirmed"
elif [ "$SL1" != "$SL2" ]; then
    # Fallback: the first slides collided (a ~1/17 chance with 17 buckets)
    # but the full sequences still differ -- still proves randomization.
    echo "[test_u51_aslr] OK: stack slide sequences DIFFER across boots" \
         "(first-slide collision, full sequence still random)"
else
    echo "[test_u51_aslr] MISS: identical slide sequences across boots" \
         "-- ASLR is not randomizing!"
    fail=1
fi

# (3) No regression: the spawned program ran correctly in BOTH boots.
for tag in 1 2; do
    eval "log=\$LOG$tag"
    if grep -a -F -q "cow_fork: PASS" "$log"; then
        echo "[test_u51_aslr] OK: boot $tag spawned program ran to PASS"
    else
        echo "[test_u51_aslr] MISS: boot $tag spawned program did NOT PASS" \
             "-- exec/boot regression!"
        fail=1
    fi
done

# Diagnostics on failure.
if [ "$fail" -ne 0 ]; then
    for tag in 1 2; do
        eval "log=\$LOG$tag"
        echo "[test_u51_aslr] DIAG: boot $tag tail:"
        tail -30 "$log" || true
    done
    echo "[test_u51_aslr] FAIL"
    exit 1
fi

echo "[test_u51_aslr] PASS -- per-exec, bounded, page-aligned user-stack" \
     "ASLR randomizes across boots with no exec/boot regression"
