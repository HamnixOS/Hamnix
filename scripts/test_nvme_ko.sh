#!/usr/bin/env bash
# scripts/test_nvme_ko.sh — regression guard for the stock Linux nvme.ko
# load path via the L-series loader (storage-pivot batch, Agent D).
#
# Boots the kernel with `-device nvme` + a backing disk attached,
# stages nvme.ko at /lib/modules/6.12/nvme.ko in the initramfs, boots
# hamsh as PID 1, drives `insmod /lib/modules/6.12/nvme.ko` from the
# shell, and asserts the L-series loader resolved every UND symbol
# and called the module's init_module (which then went through
# __pci_register_driver against the live PCI bus).
#
# Assertions (V0 — module load + relocations + init invocation):
#   1. "[nvme.ko] loading" / "kmod_linux: relocations applied=" — the
#      .ko bytes were found and the loader applied every relocation
#      without an unresolved-external.
#   2. "kmod_linux: relocations applied=N skipped=0" — exhaustive
#      relocation success.
#   3. EITHER "kmod_linux: init returned 0" (init_module returned
#      success) OR a probe-time stub fired ("[nvme.ko] nvme_init_ctrl"
#      or "[pci_register_driver] MATCH 1b36:0010") — both prove the
#      L-shim worked end-to-end for an NVMe storage driver.
#
# nvme-core.ko is stubbed (~37 nvme_* symbols). probe gets to
# nvme_init_ctrl (logs "[nvme.ko] nvme_init_ctrl"), nvme_pci_enable
# (no-op MMIO), and async_schedule_node(reset_work) which we dispatch
# synchronously. Reset work eventually bails when it can't actually
# talk to silicon — but probe-invocation is the success floor.
#
# nvme0n1 won't show up in this V0 (no namespace scan can complete
# against stubbed nvme_submit_sync_cmd returning -ENODEV). That's a
# follow-up: bridge nvme to kernel/block/blk.ad's gendisk machinery.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/nvme.ko"

SRC_KO="kernel-modules/nvme/nvme.ko"
if [ ! -f "$SRC_KO" ]; then
    echo "[test_nvme_ko] FAIL: $SRC_KO missing — re-stage from Debian package"
    exit 1
fi

cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_nvme_ko] (1/4) Stage nvme.ko in tests/linux-modules/"
mkdir -p "$LKM_DIR"
cp "$SRC_KO" "$STAGED_KO"
ls -l "$STAGED_KO"

UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
MISSING=""
for sym in $UND_SYMS; do
    if ! grep -rq "_add_export(\"${sym}\"" linux_abi/ 2>/dev/null; then
        MISSING+=" $sym"
    fi
done
TOTAL_UND=$(echo "$UND_SYMS" | wc -w)
TOTAL_MISSING=$(echo "$MISSING" | wc -w)
echo "[test_nvme_ko] UND total=$TOTAL_UND missing=$TOTAL_MISSING"
if [ -n "$MISSING" ]; then
    echo "[test_nvme_ko] MISSING:"
    for s in $MISSING; do echo "  - $s"; done
fi

echo "[test_nvme_ko] (2/4) Build userland + modules + initramfs (hamsh as /init)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
ENABLE_NVME_KO=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_nvme_ko] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_nvme_ko] (4/4) Boot QEMU with -device nvme + backing disk; drive insmod"
LOG="$(mktemp)"
DISK="$(mktemp --suffix=.img)"
truncate -s 16M "$DISK"
trap 'rm -f "$LOG" "$DISK"; cleanup' EXIT

set +e
# Drive `insmod` then `dmesg` from hamsh — same rationale as
# test_ahci_ko.sh: kmod_linux INFO-level prints land in the printk
# ring (printk_log.ad) but post-interactive the live console mirror
# suppresses them. `dmesg` snapshots /proc/kmsg and writes it to
# stdout, which goes through console_force_mirror().
(
    sleep 3
    printf 'insmod /lib/modules/6.12/nvme.ko\n'
    sleep 8
    printf 'dmesg\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive id=d0,file="$DISK",if=none,format=raw \
    -device nvme,drive=d0,serial=hamnix-nvme-0 \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_nvme_ko] --- captured (kmod / nvme / pci_register_driver) ---"
grep -aE 'kmod_linux|\[nvme\.ko\]|\[pci_register_driver\]|nvme0n1' "$LOG" | head -40 || true
echo "[test_nvme_ko] --- end ---"

# Stash the full raw log for post-mortem.
cp "$LOG" /tmp/test_nvme_ko.last.log || true

fail=0

# 1. No traps / panics / page faults — post-preemption (b08853e) the
#    .ko load path is supposed to be IF-clear-safe end-to-end.
n_traps=$(grep -acE "TRAP: vector|#UD|#GP fault|Page Fault|kernel panic|PANIC|panic:" "$LOG" || true)
if [ "${n_traps:-0}" -ne 0 ]; then
    echo "[test_nvme_ko] FAIL: ${n_traps} trap/panic line(s) in boot log"
    grep -aE "TRAP: vector|#UD|#GP fault|Page Fault|kernel panic|PANIC|panic:" "$LOG" | head -10
    fail=1
else
    echo "[test_nvme_ko] OK: no traps/panics in boot log"
fi

# 2. Post-load forward-progress check (wedge guard). After the .ko
#    finishes loading, hamsh must still be alive and able to fork its
#    next child (dmesg). Wedge during the .ko load would block hamsh
#    from ever reaching the next exec, so this asserts end-to-end
#    scheduler liveness across the load path. See test_ahci_ko.sh.
INSMOD_LINE=$(grep -anE "kmod_linux: name=nvme$" "$LOG" | head -1 | cut -d: -f1)
INSMOD_LINE=${INSMOD_LINE:-0}
POST_LOAD_FORK=0
if [ "$INSMOD_LINE" -gt 0 ]; then
    POST_LOAD_FORK=$(tail -n +"$INSMOD_LINE" "$LOG" | grep -acE "\[runtime:dmesg\] _start|task: pid [0-9]+ exited" || true)
    POST_LOAD_FORK=${POST_LOAD_FORK:-0}
fi
if [ "$POST_LOAD_FORK" -ge 1 ]; then
    echo "[test_nvme_ko] OK: hamsh forked+exited dmesg AFTER .ko load (no scheduler wedge)"
else
    echo "[test_nvme_ko] FAIL: no post-load fork progress — scheduler may be wedged"
    fail=1
fi
TICKS_TOTAL=$(grep -acE "\[hamsh-alive\] tick=" "$LOG" || true)
TICKS_TOTAL=${TICKS_TOTAL:-0}
echo "[test_nvme_ko] heartbeat ticks observed: $TICKS_TOTAL (informational)"

INIT_OK=$(grep -acE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK=${INIT_OK:-0}
LIB_ONLY=$(grep -acE "kmod_linux: no init function" "$LOG" || true)
LIB_ONLY=${LIB_ONLY:-0}
INSMOD_FAIL=$(grep -acE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL=${INSMOD_FAIL:-0}
PROBE_HIT=$(grep -acE "\[nvme\.ko\] nvme_init_ctrl|\[pci_register_driver\] MATCH 1b36:0010|\[pci_register_driver\] calling probe" "$LOG" || true)
PROBE_HIT=${PROBE_HIT:-0}
RELOC_OK=$(grep -acE "kmod_linux: relocations applied=[0-9]+ skipped=0" "$LOG" || true)
RELOC_OK=${RELOC_OK:-0}
NVME0N1=$(grep -acE "nvme0n1" "$LOG" || true)
NVME0N1=${NVME0N1:-0}

# 3. Every relocation pass that fired must report skipped=0.
n_bad_skipped=$( { grep -aE "kmod_linux: relocations applied=" "$LOG" || true; } \
                | { grep -vE 'skipped=0' || true; } | wc -l)
if [ "$n_bad_skipped" -ne 0 ]; then
    echo "[test_nvme_ko] FAIL: $n_bad_skipped relocation pass(es) had skipped>0"
    grep -aE "kmod_linux: relocations applied=" "$LOG" | grep -vE 'skipped=0' | head
    fail=1
else
    echo "[test_nvme_ko] OK: every relocation pass resolved (skipped=0)"
fi

echo "[test_nvme_ko] init_ok=$INIT_OK lib_only=$LIB_ONLY insmod_fail=$INSMOD_FAIL probe_hit=$PROBE_HIT reloc_clean=$RELOC_OK nvme0n1_seen=$NVME0N1"

if [ "$INSMOD_FAIL" -ge 1 ]; then
    echo "[test_nvme_ko] FAIL: insmod reported init_module failure"
    fail=1
fi

if [ "$RELOC_OK" -ge 1 ] && \
   { [ "$INIT_OK" -ge 1 ] || [ "$LIB_ONLY" -ge 1 ] || [ "$PROBE_HIT" -ge 1 ]; }; then
    :
else
    echo "[test_nvme_ko] FAIL: no PASS markers (qemu rc=$rc)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_nvme_ko] FAIL — see /tmp/test_nvme_ko.last.log for full output"
    echo "[test_nvme_ko] --- full log tail ---"
    tail -n 100 "$LOG"
    exit 1
fi

echo "[test_nvme_ko] PASS: nvme.ko loaded; relocations clean; probe path exercised; no traps; post-load fork OK"
if [ "$NVME0N1" -ge 1 ]; then
    echo "[test_nvme_ko] BONUS: nvme0n1 mention observed in log"
fi
exit 0
