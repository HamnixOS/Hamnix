#!/usr/bin/env bash
# scripts/test_cgroup_v2_fs.sh — cgroup v2 WRITE/MKDIR surface, end-to-end
# FROM THE SHELL.
#
# The ddd66d74 wave made the controllers ENFORCE (pids.max rejects an
# over-limit fork; memory.max charges/reclaims/OOMs; cpu.max throttles)
# but the userland VFS *write* surface was not yet dispatched into the
# live object graph — you could not drive the controllers from a shell.
# This fixture proves that gap is closed: a hamsh session creates a
# cgroup, sets pids.max, moves ITSELF into the cgroup, and then a fork
# past the limit is REJECTED — i.e. a limit set VIA THE FILESYSTEM
# actually enforces.
#
# Boot model: /init = hamsh.elf (same as test_hamsh.sh), so the serial
# shell IS pid 1 — no DE/runlevel-5 in the way, stdin is consumed
# immediately, and `echo 1 > cgroup.procs` moves the shell itself.
#
# Scenario (all via the real VFS path — mkdir(2) -> vfs_mkdir cgroup arm,
# `> file` -> vfs_open_write FD_CGROUP_WRITE_MARK -> vfs_write ->
# cgroup_fs_write/cgroup_fs_attach into kernel/sched/cgroup_cpu.ad):
#
#   mkdir /sys/fs/cgroup/t                 # create a LIVE cgroup
#   echo 2 > /sys/fs/cgroup/t/pids.max     # set the limit via the fs
#   cat /sys/fs/cgroup/t/pids.max          # read back "2"  (FSMAX)
#   echo 0 > /sys/fs/cgroup/t/cgroup.procs # move the shell (PID 1) in
#   cat /sys/fs/cgroup/t/pids.current      # read back "1"  (FSCUR)
#   cat /etc/hostname | cat                # 2-stage pipeline: shell(1) +
#                                          #   stage1 fork -> pids_cur 2,
#                                          #   stage2 fork -> would be 3 >
#                                          #   pids.max=2 -> REJECTED.
#                                          # run_pipeline launches BOTH
#                                          # stages before waiting, so no
#                                          # reap-race: the 2nd fork is
#                                          # denied. cat EXISTS, so a
#                                          # "command not found: cat" line
#                                          # can ONLY be the rfork -EAGAIN
#                                          # rejection.
#
# As a control, the SAME pipeline is run BEFORE the cgroup is set up and
# is expected to run cleanly (no spurious fork rejection).
#
# Pass marker:  [test_cgroup_v2_fs] PASS
# Fail marker:  [test_cgroup_v2_fs] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
BOOT_TIMEOUT="${CGROUP_FS_BOOT_TIMEOUT:-60}"

echo "[test_cgroup_v2_fs] (1/4) Build userland (incl. user/hamsh.ad)"
bash scripts/build_user.sh > /tmp/test_cgroup_v2_fs.build_user.log 2>&1 || {
    echo "[test_cgroup_v2_fs] FAIL: build_user.sh failed. Tail:"
    tail -30 /tmp/test_cgroup_v2_fs.build_user.log
    exit 1
}

echo "[test_cgroup_v2_fs] (2/4) Swap /init = $HAMSH_ELF in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py > /tmp/test_cgroup_v2_fs.initramfs.log 2>&1

echo "[test_cgroup_v2_fs] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" \
    > /tmp/test_cgroup_v2_fs.kernel.log 2>&1 || {
    echo "[test_cgroup_v2_fs] FAIL: kernel compile failed. Tail:"
    tail -30 /tmp/test_cgroup_v2_fs.kernel.log
    exit 1
}

LOG=$(mktemp /tmp/test-cgroup-v2-fs.XXXXXX.log)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_cgroup_v2_fs] (4/4) Boot QEMU + drive the cgroup-fs scenario"
set +e
(
    sleep 4
    # CONTROL: the pipeline runs cleanly before any cgroup is set up.
    printf 'echo CG_CONTROL_BEGIN\n';                          sleep 1
    printf 'cat /etc/hostname | cat\n';                        sleep 2
    printf 'echo CG_CONTROL_END\n';                            sleep 1
    # Create a live cgroup + set pids.max via the filesystem.
    printf 'mkdir /sys/fs/cgroup/t\n';                         sleep 1
    printf 'echo CG_MKDIR_DONE\n';                             sleep 1
    printf 'echo 2 > /sys/fs/cgroup/t/pids.max\n';             sleep 1
    printf 'echo FSMAX_BEGIN\n';                               sleep 1
    printf 'cat /sys/fs/cgroup/t/pids.max\n';                  sleep 1
    printf 'echo FSMAX_END\n';                                 sleep 1
    # Move the shell (pid 1) into the cgroup, then read the live count.
    printf 'echo 0 > /sys/fs/cgroup/t/cgroup.procs\n';         sleep 1
    printf 'echo FSCUR_BEGIN\n';                               sleep 1
    printf 'cat /sys/fs/cgroup/t/pids.current\n';              sleep 1
    printf 'echo FSCUR_END\n';                                 sleep 1
    # ENFORCE: the 2-stage pipeline's 2nd fork must be REJECTED now.
    printf 'echo CG_ENFORCE_BEGIN\n';                          sleep 1
    printf 'cat /etc/hostname | cat\n';                        sleep 2
    printf 'echo CG_ENFORCE_END\n';                            sleep 1
    printf 'exit\n';                                           sleep 1
) | timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_cgroup_v2_fs] --- captured ---"
cat "$LOG"
echo "[test_cgroup_v2_fs] --- end ---"

fail=0

# Shell came up + feed ran to completion.
if ! grep -a -F -q "CG_ENFORCE_END" "$LOG"; then
    echo "[test_cgroup_v2_fs] FAIL: end marker never appeared — boot/feed wedged"
    trap - EXIT
    echo "[test_cgroup_v2_fs] preserved log: $LOG"
    exit 1
fi

extract_block() {
    local tag="$1"
    sed -n "/${tag}_BEGIN/,/${tag}_END/p" "$LOG"
}

# 1. The mkdir create succeeded (its DONE marker printed; no error).
if grep -a -F -q "CG_MKDIR_DONE" "$LOG" \
   && ! grep -a -E -q "mkdir.*(cannot|error|denied)" "$LOG"; then
    echo "[test_cgroup_v2_fs] OK: mkdir /sys/fs/cgroup/t completed"
else
    echo "[test_cgroup_v2_fs] MISS: mkdir /sys/fs/cgroup/t did not complete cleanly"
    fail=1
fi

# 2. pids.max read back "2" after the filesystem write.
fsmax_block=$(extract_block FSMAX)
if echo "$fsmax_block" | grep -a -qE '(^|[^0-9])2([^0-9]|$)'; then
    echo "[test_cgroup_v2_fs] OK: pids.max read back '2' after fs write"
else
    echo "[test_cgroup_v2_fs] MISS: pids.max did NOT read back '2'; block was:"
    echo "$fsmax_block" | sed 's/^/    /'
    fail=1
fi

# 3. pids.current read back NON-ZERO after `echo 0 > cgroup.procs` (the
#    cgroup v2 self-move: the writing shell joins the cgroup). The value
#    is 1 (the shell) or 2 (the shell + the `cat` reading the file, which
#    inherited the cgroup via charge_fork) — either is >0 and proves the
#    cgroup.procs write resolved the writer and bumped the live count.
fscur_block=$(extract_block FSCUR)
if echo "$fscur_block" | grep -a -qE '(^|[^0-9])[12]([^0-9]|$)'; then
    echo "[test_cgroup_v2_fs] OK: pids.current read back non-zero (shell joined cgroup)"
else
    echo "[test_cgroup_v2_fs] MISS: pids.current did NOT read back 1/2; block was:"
    echo "$fscur_block" | sed 's/^/    /'
    fail=1
fi

# 4. CONTROL: the pipeline ran cleanly BEFORE the cgroup was set up — no
#    spurious "command not found" for cat in the control block.
ctrl_block=$(extract_block CG_CONTROL)
if echo "$ctrl_block" | grep -a -q "command not found"; then
    echo "[test_cgroup_v2_fs] MISS: control pipeline spuriously failed:"
    echo "$ctrl_block" | sed 's/^/    /'
    fail=1
else
    echo "[test_cgroup_v2_fs] OK: control pipeline ran without a fork rejection"
fi

# 5. ENFORCE: after pids.max=2 and the shell in the cgroup, the 2-stage
#    pipeline's 2nd fork is REJECTED — surfaced as "command not found:
#    cat" for an EXISTING command (the rfork -EAGAIN signature). This is
#    the load-bearing assertion: a limit SET VIA THE FILESYSTEM enforces.
enf_block=$(extract_block CG_ENFORCE)
if echo "$enf_block" | grep -a -q "command not found"; then
    echo "[test_cgroup_v2_fs] OK: fork past pids.max=2 REJECTED (fs-set limit enforces)"
else
    echo "[test_cgroup_v2_fs] MISS: fork past the fs-set pids.max was NOT rejected:"
    echo "$enf_block" | sed 's/^/    /'
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_cgroup_v2_fs] FAIL (qemu rc=$rc)"
    trap - EXIT
    echo "[test_cgroup_v2_fs] preserved log: $LOG"
    exit 1
fi
echo "[test_cgroup_v2_fs] PASS — mkdir + echo>pids.max + echo>cgroup.procs via the VFS drive the LIVE cgroup; the fs-set pids.max enforces a fork rejection (qemu rc=$rc)"
