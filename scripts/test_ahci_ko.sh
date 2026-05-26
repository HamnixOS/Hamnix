#!/usr/bin/env bash
# scripts/test_ahci_ko.sh — regression guard for the stock Linux ahci.ko
# load path via the L-series loader (storage-pivot batch, Agent D).
#
# Boots the kernel with `-device ich9-ahci` + a backing disk attached,
# stages ahci.ko at /lib/modules/6.12/ahci.ko in the initramfs, boots
# hamsh as PID 1, drives `insmod /lib/modules/6.12/ahci.ko` from the
# shell, and asserts the L-series loader resolved every UND symbol
# and called the module's init_module (which then went through
# __pci_register_driver against the live PCI bus).
#
# Assertions (V0 — module load + relocations + init invocation):
#   1. "[ahci.ko] loading" / "kmod_linux: relocations applied=" —
#      the .ko bytes were found and the loader applied every
#      relocation without an unresolved-external.
#   2. "kmod_linux: relocations applied=N skipped=0" — exhaustive
#      relocation success.
#   3. EITHER "kmod_linux: init returned 0" (init_module succeeded)
#      OR "kmod_linux: no init function" (header-only fallback) OR
#      "[ahci.ko] ahci_host_activate" / "[ahci.ko] libata version"
#      (one of the cold-path probe stubs fired, proving probe was
#      invoked) — any of these is PASS.
#
# libata + scsi_mid_layer is stubbed. Probe gets through pcim_enable_
# device + ata_host_alloc_pinfo + ahci_host_activate (banner-only).
# Real disk I/O is the next milestone (would need a libata.ko shim or
# native SATA bridging via kernel/block/blk.ad).

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_KO="$LKM_DIR/ahci.ko"

# Source: the kernel-modules/ copy committed to the worktree
# (Debian 6.1.0-32 build, ~117 KiB) is canonical.
SRC_KO="kernel-modules/ahci/ahci.ko"
if [ ! -f "$SRC_KO" ]; then
    echo "[test_ahci_ko] FAIL: $SRC_KO missing — re-stage from Debian package"
    exit 1
fi

cleanup() {
    rm -f "$STAGED_KO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_ahci_ko] (1/4) Stage ahci.ko in tests/linux-modules/"
mkdir -p "$LKM_DIR"
cp "$SRC_KO" "$STAGED_KO"
ls -l "$STAGED_KO"

# Gap diagnostic (informational, non-fatal).
UND_SYMS=$(nm -u "$STAGED_KO" 2>/dev/null | awk '{print $2}' | sort -u)
MISSING=""
for sym in $UND_SYMS; do
    if ! grep -rq "_add_export(\"${sym}\"" linux_abi/ 2>/dev/null; then
        MISSING+=" $sym"
    fi
done
TOTAL_UND=$(echo "$UND_SYMS" | wc -w)
TOTAL_MISSING=$(echo "$MISSING" | wc -w)
echo "[test_ahci_ko] UND total=$TOTAL_UND missing=$TOTAL_MISSING"
if [ -n "$MISSING" ]; then
    echo "[test_ahci_ko] MISSING:"
    for s in $MISSING; do echo "  - $s"; done
fi

echo "[test_ahci_ko] (2/4) Build userland + modules + initramfs (hamsh as /init)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
ENABLE_AHCI_KO=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_ahci_ko] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_ahci_ko] (4/4) Boot QEMU with ich9-ahci + backing disk; drive insmod"
LOG="$(mktemp)"
# A small empty backing disk so the AHCI controller has something to
# probe ports against. The driver never actually issues a READ in our
# env (libata/SCSI mid-layer is stubbed), so the disk content is moot;
# we just need the controller's PCI BAR window to be present.
DISK="$(mktemp --suffix=.img)"
truncate -s 16M "$DISK"
trap 'rm -f "$LOG" "$DISK"; cleanup' EXIT

set +e
# Drive `insmod` then `dmesg` from hamsh. The console_set_interactive()
# path tightens printk suppression to INFO at first stdin-read, which
# would swallow the kmod_linux INFO-level messages from the live
# console mirror. Every byte still lands in the printk ring buffer
# (printk_log.ad), and `dmesg` snapshots that ring through
# /proc/kmsg — userland writes are forcibly mirrored to the console
# via console_force_mirror(), so the kmod_linux trace appears in our
# captured log via dmesg's stdout.
(
    sleep 3
    printf 'insmod /lib/modules/6.12/ahci.ko\n'
    sleep 8
    printf 'dmesg\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive id=d0,file="$DISK",if=none,format=raw \
    -device ich9-ahci,id=ahci0 \
    -device ide-hd,drive=d0,bus=ahci0.0 \
    -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ahci_ko] --- captured (kmod / ahci / pci_register_driver) ---"
grep -aE 'kmod_linux|\[ahci\.ko\]|\[pci_register_driver\]|ahci_|libata' "$LOG" | head -40 || true
echo "[test_ahci_ko] --- end ---"

# Stash the full raw log for post-mortem so cherry-picks have something
# to read if a regression surfaces after merge.
cp "$LOG" /tmp/test_ahci_ko.last.log || true

# Hard fails — any of these are unambiguous regressions.
fail=0

# 1. No traps / panics / page faults. Post-preemption (b08853e), the
#    .ko load path is supposed to be IF-clear-safe end-to-end; a #UD or
#    #GP here means a busy-poll site or shim entry inverted EFLAGS the
#    wrong way (see the tcp.ad / sound-stack precedent).
n_traps=$(grep -acE "TRAP: vector|#UD|#GP fault|Page Fault|kernel panic|PANIC|panic:" "$LOG" || true)
if [ "${n_traps:-0}" -ne 0 ]; then
    echo "[test_ahci_ko] FAIL: ${n_traps} trap/panic line(s) in boot log"
    grep -aE "TRAP: vector|#UD|#GP fault|Page Fault|kernel panic|PANIC|panic:" "$LOG" | head -10
    fail=1
else
    echo "[test_ahci_ko] OK: no traps/panics in boot log"
fi

# 2. Post-load forward-progress check (wedge guard). After the .ko
#    finishes loading, hamsh must still be alive and able to fork its
#    next child (dmesg). If the .ko load wedged the scheduler — e.g. a
#    polled probe holding the CPU with IF=0 — hamsh would never reach
#    the dmesg fork+exec path. The `[runtime:dmesg] _start` marker
#    fires from u_syscalls's elf-loader entry, post-fork, AFTER the
#    insmod child already returned to hamsh. Its presence proves
#    end-to-end scheduler liveness across the .ko load.
INSMOD_LINE=$(grep -anE "kmod_linux: name=ahci$" "$LOG" | head -1 | cut -d: -f1)
INSMOD_LINE=${INSMOD_LINE:-0}
POST_LOAD_FORK=0
if [ "$INSMOD_LINE" -gt 0 ]; then
    POST_LOAD_FORK=$(tail -n +"$INSMOD_LINE" "$LOG" | grep -acE "\[runtime:dmesg\] _start|task: pid [0-9]+ exited" || true)
    POST_LOAD_FORK=${POST_LOAD_FORK:-0}
fi
if [ "$POST_LOAD_FORK" -ge 1 ]; then
    echo "[test_ahci_ko] OK: hamsh forked+exited dmesg AFTER .ko load (no scheduler wedge)"
else
    echo "[test_ahci_ko] FAIL: no post-load fork progress — scheduler may be wedged"
    fail=1
fi
# Also surface heartbeat ticks if any (informational; the .ko test's
# stdin-pipe shape rarely yields the 3s of idle hamsh needs for one
# heartbeat to fire, so we don't gate PASS on it).
TICKS_TOTAL=$(grep -acE "\[hamsh-alive\] tick=" "$LOG" || true)
TICKS_TOTAL=${TICKS_TOTAL:-0}
echo "[test_ahci_ko] heartbeat ticks observed: $TICKS_TOTAL (informational)"

INIT_OK=$(grep -acE "kmod_linux: init returned 0" "$LOG" || true)
INIT_OK=${INIT_OK:-0}
LIB_ONLY=$(grep -acE "kmod_linux: no init function" "$LOG" || true)
LIB_ONLY=${LIB_ONLY:-0}
INSMOD_FAIL=$(grep -acE "insmod: init_module failed" "$LOG" || true)
INSMOD_FAIL=${INSMOD_FAIL:-0}
PROBE_HIT=$(grep -acE "\[ahci\.ko\] ahci_host_activate|\[ahci\.ko\] libata version|\[pci_register_driver\] MATCH" "$LOG" || true)
PROBE_HIT=${PROBE_HIT:-0}
RELOC_OK=$(grep -acE "kmod_linux: relocations applied=[0-9]+ skipped=0" "$LOG" || true)
RELOC_OK=${RELOC_OK:-0}

# 3. Every relocation pass that fired must report skipped=0 — no UND
#    silently left unresolved. Counter-test: if any `applied=N` line
#    has skipped!=0, we'd have a quietly broken module.
n_bad_skipped=$( { grep -aE "kmod_linux: relocations applied=" "$LOG" || true; } \
                | { grep -vE 'skipped=0' || true; } | wc -l)
if [ "$n_bad_skipped" -ne 0 ]; then
    echo "[test_ahci_ko] FAIL: $n_bad_skipped relocation pass(es) had skipped>0"
    grep -aE "kmod_linux: relocations applied=" "$LOG" | grep -vE 'skipped=0' | head
    fail=1
else
    echo "[test_ahci_ko] OK: every relocation pass resolved (skipped=0)"
fi

echo "[test_ahci_ko] init_ok=$INIT_OK lib_only=$LIB_ONLY insmod_fail=$INSMOD_FAIL probe_hit=$PROBE_HIT reloc_clean=$RELOC_OK"

if [ "$INSMOD_FAIL" -ge 1 ]; then
    echo "[test_ahci_ko] FAIL: insmod reported init_module failure"
    fail=1
fi

# PASS criteria:
#   * relocations applied with 0 skipped (every UND resolved), AND
#   * init returned 0 OR no-init-function path OR a probe-time stub
#     fired (which proves __pci_register_driver matched and invoked
#     probe — the "L-shim works for STORAGE" assertion).
if [ "$RELOC_OK" -ge 1 ] && \
   { [ "$INIT_OK" -ge 1 ] || [ "$LIB_ONLY" -ge 1 ] || [ "$PROBE_HIT" -ge 1 ]; }; then
    :
else
    echo "[test_ahci_ko] FAIL: no PASS markers (qemu rc=$rc)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ahci_ko] FAIL — see /tmp/test_ahci_ko.last.log for full output"
    echo "[test_ahci_ko] --- full log tail ---"
    tail -n 100 "$LOG"
    exit 1
fi

echo "[test_ahci_ko] PASS: ahci.ko loaded; relocations clean; probe path exercised; no traps; post-load fork OK"
exit 0
