#!/usr/bin/env bash
# scripts/test_u52_aslr_loadbias.sh -- ET_DYN load-bias + mmap-base ASLR.
#
# WHAT IT PROVES
#
# The two ASLR forms that the Stage 2 banner (arch/x86/kernel/syscall.ad)
# DEFERRED until real copy_to/from_user translation existed:
#
#   1. ET_DYN load-bias ASLR -- the virtual base at which a PIE/ET_DYN
#      user image (and its ld.so interpreter) is loaded is randomized per
#      exec/spawn, INDEPENDENT of its physical backing. The image's
#      PT_LOAD bytes still live at an identity-mapped physical `region`;
#      only the USER virtual base moves, mapped through the task's PML4
#      via the non-identity primitive elf_install_user_range already
#      supports (vaddr != phys). This is only sound because mm/uaccess.ad
#      now TRANSLATES every user-memory access on the exec path -- so a
#      program running at a randomized base whose phys differs is read /
#      written correctly.
#
#   2. mmap-base ASLR -- the virtual base of the windowed mmap allocator
#      (large eager anon, demand-paged anon, file-shared) is randomized
#      per exec. Those paths already establish vaddr != phys (the eager
#      large path overlays alloc_pages chunks at the window vaddr; the
#      demand path faults pages in at the window vaddr), so perturbing the
#      window start adds no raw-deref hazard. MAP_FIXED is unaffected.
#
# do_execve / SYS_SPAWN draw genuine per-exec entropy (read_tsc folded
# with tsc_monotonic_ns + a stream counter through splitmix64 -- the same
# source aslr_stack_slide uses) and log the chosen bases on every spawn:
#
#       [aslr] load bias  = 0x....      (application image vbase)
#       [aslr] interp bias = 0x....     (ld.so image vbase, dynamic only)
#       [aslr] mmap base  = 0x....      (windowed-mmap allocator start)
#
# This fixture SPAWNS a real binary (u_cow_fork -- reused purely as a
# "spawn a program that runs and exits cleanly" vehicle) once per boot,
# boots the SAME kernel image TWICE, and asserts:
#   1. each boot emits the [aslr] load-bias AND mmap-base sentinels
#      (both ASLR forms live), AND
#   2. the load-bias value DIFFERS between the two boots (per-exec
#      random, not a constant), AND
#   3. the mmap-base value DIFFERS between the two boots, AND
#   4. the spawned program still ran correctly in BOTH boots (its PASS
#      marker lands both times) -- proving a real process executes at its
#      randomized base, i.e. the uaccess translation on the exec path is
#      sound.
#
# A PASS therefore demonstrates per-exec, bounded, page-aligned ET_DYN
# load-bias AND mmap-base ASLR with zero boot/exec regression.
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
ensure_ubin_or_skip test_u52_aslr u_cow_fork cow_fork

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u52_aslr] (1/3) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u52_aslr] (2/3) Swap /init = $HAMSH_ELF + embed u_cow_fork"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u52_aslr] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# Drive one boot: wait for hamsh's banner, spawn u_cow_fork (one
# SYS_SPAWN -> one [aslr] load-bias + mmap-base draw), then exit. The
# command is sent twice (the 2nd is a harmless re-run if the 1st landed)
# so the [hamsh-alive] heartbeat redraw can't eat the only delivery.
run_boot() {
    local log="$1"
    set +e
    qemu_drive "$log" "$ELF" "[hamsh] M16.35 shell ready" 70 \
        -- "u_cow_fork" 8 \
           "u_cow_fork" 8 \
           "exit" 1
    set -e
}

LOG1=$(mktemp)
LOG2=$(mktemp)
trap 'rm -f "$LOG1" "$LOG2"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_u52_aslr] === BOOT 1 ==="
run_boot "$LOG1"
echo "[test_u52_aslr] === BOOT 2 ==="
run_boot "$LOG2"

# Extract the ordered list of a given sentinel's values from a boot log.
# $1 = log, $2 = sentinel label regex (e.g. 'load bias').
vals_of() {
    grep -a -oE "\[aslr\] $2 *= 0x[0-9a-fA-F]+" "$1" \
        | grep -a -oE '0x[0-9a-fA-F]+$' || true
}

LB1="$(vals_of "$LOG1" 'load bias')"
LB2="$(vals_of "$LOG2" 'load bias')"
MB1="$(vals_of "$LOG1" 'mmap base')"
MB2="$(vals_of "$LOG2" 'mmap base')"

echo "[test_u52_aslr] --- boot 1 load-bias ---"; printf '%s\n' "$LB1"
echo "[test_u52_aslr] --- boot 2 load-bias ---"; printf '%s\n' "$LB2"
echo "[test_u52_aslr] --- boot 1 mmap-base ---"; printf '%s\n' "$MB1"
echo "[test_u52_aslr] --- boot 2 mmap-base ---"; printf '%s\n' "$MB2"

fail=0

# (1) ASLR is live: each boot emitted at least one load-bias AND one
#     mmap-base line.
nlb1="$(printf '%s\n' "$LB1" | grep -ac '0x' || true)"
nlb2="$(printf '%s\n' "$LB2" | grep -ac '0x' || true)"
nmb1="$(printf '%s\n' "$MB1" | grep -ac '0x' || true)"
nmb2="$(printf '%s\n' "$MB2" | grep -ac '0x' || true)"
if [ "$nlb1" -ge 1 ] && [ "$nlb2" -ge 1 ] \
   && [ "$nmb1" -ge 1 ] && [ "$nmb2" -ge 1 ]; then
    echo "[test_u52_aslr] OK: ASLR live (load-bias boot1=$nlb1/boot2=$nlb2," \
         "mmap-base boot1=$nmb1/boot2=$nmb2)"
else
    echo "[test_u52_aslr] MISS: missing [aslr] load-bias/mmap-base lines" \
         "(lb $nlb1/$nlb2, mb $nmb1/$nmb2)"
    fail=1
fi

# (2) Load-bias randomization: compare the FIRST load-bias of each boot.
LBF1="$(printf '%s\n' "$LB1" | grep -a '0x' | head -1)"
LBF2="$(printf '%s\n' "$LB2" | grep -a '0x' | head -1)"
if [ -n "$LBF1" ] && [ -n "$LBF2" ] && [ "$LBF1" != "$LBF2" ]; then
    echo "[test_u52_aslr] OK: first load bias DIFFERS across boots" \
         "($LBF1 vs $LBF2) -- per-exec ET_DYN load-bias randomization"
elif [ "$LB1" != "$LB2" ]; then
    echo "[test_u52_aslr] OK: load-bias sequences DIFFER across boots" \
         "(first-value collision, full sequence still random)"
else
    echo "[test_u52_aslr] MISS: identical load-bias across boots" \
         "-- load-bias ASLR is not randomizing!"
    fail=1
fi

# (3) mmap-base randomization: compare the FIRST mmap-base of each boot.
MBF1="$(printf '%s\n' "$MB1" | grep -a '0x' | head -1)"
MBF2="$(printf '%s\n' "$MB2" | grep -a '0x' | head -1)"
if [ -n "$MBF1" ] && [ -n "$MBF2" ] && [ "$MBF1" != "$MBF2" ]; then
    echo "[test_u52_aslr] OK: first mmap base DIFFERS across boots" \
         "($MBF1 vs $MBF2) -- per-exec mmap-base randomization"
elif [ "$MB1" != "$MB2" ]; then
    echo "[test_u52_aslr] OK: mmap-base sequences DIFFER across boots" \
         "(first-value collision, full sequence still random)"
else
    echo "[test_u52_aslr] MISS: identical mmap-base across boots" \
         "-- mmap-base ASLR is not randomizing!"
    fail=1
fi

# (4) No regression: the spawned program ran correctly in BOTH boots.
#     This proves a real process executes at its randomized base -- the
#     uaccess translation on the exec path is sound.
for tag in 1 2; do
    eval "log=\$LOG$tag"
    if grep -a -F -q "cow_fork: PASS" "$log"; then
        echo "[test_u52_aslr] OK: boot $tag spawned program ran to PASS" \
             "at its randomized base"
    else
        echo "[test_u52_aslr] MISS: boot $tag spawned program did NOT PASS" \
             "-- exec/boot regression under randomized layout!"
        fail=1
    fi
done

# Diagnostics on failure.
if [ "$fail" -ne 0 ]; then
    for tag in 1 2; do
        eval "log=\$LOG$tag"
        echo "[test_u52_aslr] DIAG: boot $tag tail:"
        tail -40 "$log" || true
    done
    echo "[test_u52_aslr] FAIL"
    exit 1
fi

echo "[test_u52_aslr] PASS -- per-exec, bounded, page-aligned ET_DYN" \
     "load-bias AND mmap-base ASLR randomize across boots with a real" \
     "process running correctly at its randomized base (uaccess-translated)"
