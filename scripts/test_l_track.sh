#!/usr/bin/env bash
# scripts/test_l_track.sh — L-track regression driver.
#
# For each tests/linux-modules/*.ko fixture:
#   1. Confirm it's already been picked up by build_initramfs.py
#      (which globs tests/linux-modules/ → /lib/modules/6.12/<name>.ko
#      inside the cpio archive).
#   2. Boot the Hamnix kernel with hamsh as /init.
#   3. Drive the shell:
#         insmod /lib/modules/6.12/<name>.ko
#         rmmod  <slot id>            # always slot 1 since we load one
#   4. Grep the captured serial log for the per-module success marker
#      (e.g. "L1: hello.ko module_init" for hello.ko).
#   5. Report PASS / FAIL per module.
#
# Modules whose .ko isn't checked in get a SKIP (warn, no failure) so
# the regression remains green as new fixtures are stubbed out before
# their binaries land.
#
# Pattern mirrors scripts/test_hamsh.sh and scripts/test_procfs.sh.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules

# --- per-module success markers ---------------------------------------
#
# Each fixture writes a printk line that begins "L<N>: <name>.ko ..."
# on module_init. The grep target is exactly that line; if it appears
# in the captured serial log, the module successfully loaded all the
# way through init_module. We deliberately do NOT also grep for the
# module_exit line because rmmod-by-slot is best-effort here — the
# regression cares about LOAD, not UNLOAD (M-track tests will tighten
# this once kmod_linux_unload's slot-id reporting is plumbed back to
# userspace).
declare -A MARKERS=(
    [hello]="L1: hello.ko module_init"
    [slab]="L2: slab.ko module_init"
    [proc]="L3: proc.ko module_init"
    [chrdev]="L4: chrdev.ko module_init"
    [sync]="L6: sync.ko module_init"
    [timer]="L9: timer.ko module_init"
)

# --- build prerequisites ---------------------------------------------
echo "[test_l_track] (1/4) Build userland (hamsh + insmod + rmmod)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_l_track] (2/4) Swap /init = $HAMSH_ELF and embed *.ko"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_l_track] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

# Restore default /init on exit so subsequent test runs don't surprise.
trap 'INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# --- per-module loop --------------------------------------------------
echo "[test_l_track] (4/4) Run per-module insmod/rmmod cycles"
echo

total=0
passed=0
failed=0
skipped=0

for stem in "${!MARKERS[@]}"; do
    total=$((total + 1))
    ko_src="$LKM_DIR/${stem}.ko"
    if [ ! -f "$ko_src" ]; then
        echo "[test_l_track] SKIP $stem  (no $ko_src — fixture not built/staged)"
        skipped=$((skipped + 1))
        continue
    fi

    marker="${MARKERS[$stem]}"
    echo "[test_l_track] --- $stem.ko ---"
    LOG=$(mktemp)

    # Drive the shell:
    #   insmod prints back its slot id (typically "1" since we load
    #   one module per boot), then rmmod by that slot.
    set +e
    (
        sleep 3
        printf 'insmod /lib/modules/6.12/%s.ko\n' "$stem"
        sleep 2
        printf 'rmmod 1\n'
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
    qrc=$?
    set -e

    if grep -F -q "$marker" "$LOG"; then
        echo "[test_l_track] PASS $stem  (matched: '$marker')"
        passed=$((passed + 1))
    else
        echo "[test_l_track] FAIL $stem  (missing: '$marker', qemu rc=$qrc)"
        echo "[test_l_track] --- captured log: $stem ---"
        cat "$LOG"
        echo "[test_l_track] --- end log ---"
        failed=$((failed + 1))
    fi

    rm -f "$LOG"
    echo
done

echo "[test_l_track] ================================================="
echo "[test_l_track] total=$total passed=$passed failed=$failed skipped=$skipped"
echo "[test_l_track] ================================================="

if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
