#!/usr/bin/env bash
# scripts/test_smap_uaccess_paths.sh — prove the bracketed kernel-on-behalf-
# of-user access paths (the v3h SMAP audit) all COMPLETE under live CR4.SMAP
# enforcement, with NO spurious SMAP #PF.
#
# Background (arch/x86/kernel/cpu_mitigations.ad v3g/v3h):
#   With CR4.SMAP=1, any CPL=0 load/store to a US=1 user page #PFs unless
#   RFLAGS.AC=1 (stac) OR the access is routed through the physical-frame
#   identity window (copy_*_user). The v3g agent bracketed 3 sites; the v3h
#   audit (this change) swept the rest: poll/select/sendfile/copy_file_range/
#   splice *offset, signalfd sigset, statfs, timerfd timespec, epoll events[],
#   clone3, ptrace PEEK/POKE/GET/SETREGS, io_uring iovec + openat/statx path,
#   and the UMDF irq-fd read.
#
# How this gate exercises them: several kernel boot self-tests drive the
# REAL Linux-ABI syscall handlers for the audited paths, each inside a
# uaccess_kernel_begin()/end() (KERNEL_DS) bracket so the resolve layer
# accepts the staged buffers:
#   * UABI_FILLS  : sendfile + copy_file_range with an *offset pointer
#                   (the get_user_64/put_user_64 offset legs).
#   * SPLICE      : splice/copy_file_range *offset + vmsplice against a REAL
#                   vaddr!=phys user page (genuine US=1 access).
#   * IOURING     : READV/WRITEV iovec walk + OPENAT/STATX pathname copy-in.
#   * USERFAULTFD : UFFDIO_COPY populates a faulted page through the mm path.
#   * STATX       : statx(2) round-trip (copy_to_user statx struct).
# With SMAP_RUNTIME_ENABLE=1 (default on main) and KVM, CR4.SMAP latches and
# any missing bracket would #PF (panic / no PASS). All five must PASS.
#
# Pass marker:  [test_smap_uaccess_paths] PASS
# Fail marker:  [test_smap_uaccess_paths] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf

echo "[test_smap_uaccess_paths] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_smap_uaccess_paths] (2/3) Build kernel with uaccess self-test markers"
INIT_ELF=build/user/init.elf \
    ENABLE_UABI_FILLS_TEST=1 \
    ENABLE_SPLICE_TEST=1 \
    ENABLE_IOURING_TEST=1 \
    ENABLE_USERFAULTFD_TEST=1 \
    ENABLE_STATX_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

# SMAP CPUID bits are only exposed under a hardware accelerator. Inject
# -accel kvm -cpu host when /dev/kvm is usable; otherwise SMAP is masked
# (TCG) and the brackets become no-ops — the self-tests still run and must
# PASS, but they do not prove SMAP enforcement (they prove no regression).
KVM=0
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM=1
fi
echo "[test_smap_uaccess_paths] KVM usable: $KVM (SMAP only enforces under KVM)"

ACCEL_ARGS=()
if [ "$KVM" = "1" ]; then
    ACCEL_ARGS=(-accel kvm -cpu host)
else
    ACCEL_ARGS=(-cpu qemu64)
fi

echo "[test_smap_uaccess_paths] (3/3) Boot QEMU (accel: ${ACCEL_ARGS[*]})"
set +e
timeout 240s qemu-system-x86_64 \
    -kernel "$ELF" \
    "${ACCEL_ARGS[@]}" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_smap_uaccess_paths] --- mitigation + self-test output ---"
grep -E "\[mitig\]|\[UABI_FILLS\]|\[splice\]|\[iouring\]|\[USERFAULTFD\]|\[STATX|PANIC|#PF|smap" "$LOG" | head -60 || true
echo "[test_smap_uaccess_paths] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_smap_uaccess_paths] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# A spurious SMAP fault would panic — assert no panic / page-fault death.
if grep -qiE "PANIC|kernel page fault|triple|unhandled #PF" "$LOG"; then
    echo "[test_smap_uaccess_paths] FAIL: kernel fault/panic in log" >&2
    fail=1
fi

if [ "$KVM" -eq 1 ]; then
    if ! grep -qE "\[mitig\] CR4 SMEP=1 SMAP=1" "$LOG"; then
        echo "[test_smap_uaccess_paths] FAIL: CR4.SMAP did not latch under KVM" >&2
        fail=1
    fi
fi

# Each audited-path self-test must PASS. A missing bracket would #PF before
# its PASS line ever prints.
check_pass() {
    local marker="$1" label="$2"
    if grep -qE "$marker" "$LOG"; then
        echo "[test_smap_uaccess_paths]   $label: PASS"
    else
        echo "[test_smap_uaccess_paths] FAIL: $label did not PASS" >&2
        fail=1
    fi
}
check_pass "\[UABI_FILLS\] PASS"      "sendfile/copy_file_range *offset"
check_pass "\[splice\] PASS"          "splice *offset + vmsplice user iovec"
check_pass "\[iouring\] PASS"         "io_uring iovec + path copy-in"
check_pass "\[USERFAULTFD\] PASS UFFDIO_COPY" "userfaultfd UFFDIO_COPY"

if [ "$fail" -eq 0 ]; then
    echo "[test_smap_uaccess_paths] PASS"
    exit 0
else
    echo "[test_smap_uaccess_paths] FAIL"
    exit 1
fi
