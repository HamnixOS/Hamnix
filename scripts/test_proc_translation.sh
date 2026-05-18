#!/usr/bin/env bash
# scripts/test_proc_translation.sh — M16.134 regression.
#
# Layer-2 /proc/<name> -> /dev/<name> translation. Linux ELFs opening
# /proc/cpuinfo (and the five siblings) now get the bytes the native
# /dev/cpuinfo cdev emits, with the redirect entirely inside
# linux_abi/u_syscalls.ad's _u_open / _u_openat. The native rootfs
# remains free of /proc/<name> entries.
#
# Pipeline mirrors test_u9_access.sh:
#   1. Build userland (hamsh + helpers).
#   2. Skip-on-missing the host-built ELF if `make install` hasn't run.
#   3. Embed u_proc_translation in the cpio via HAMNIX_EMBED_UBIN=1.
#   4. Rebuild kernel image (includes the new translator).
#   5. Boot QEMU, drive `/bin/u_proc_translation` from hamsh, grep the
#      captured log for the contract markers.
#
# PASS markers from the fixture (defined in
# tests/u-binary/src/proc_translation/proc_translation.S):
#   - "[proc-translation] /proc/cpuinfo open OK"
#       open of /proc/cpuinfo via Linux open(2) returned a valid fd.
#       Without the M16.134 translator this would be -ENOENT — the
#       native namespace has /dev/cpuinfo only.
#   - "[proc-translation] /dev/cpuinfo open OK"
#       open of /dev/cpuinfo (the native source-of-truth) succeeded
#       — sanity reference; if this fails the translation isn't even
#       the bug, the cdev surface itself is.
#   - "[proc-translation] /proc/cpuinfo == /dev/cpuinfo OK"
#       both reads produced byte-identical content. devcpuinfo_read is
#       deterministic across a boot (CPUID leaves + cpus_online), so
#       any mismatch means the translation routed somewhere else.
#   - "[proc-translation] vendor line present OK"
#       the read blob contains the "vendor:" substring devcpuinfo_read
#       emits — confirms the bytes are the real cdev output, not a
#       stale procfs renderer leak.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_proc_translation
if [ ! -f "$UBIN" ]; then
    echo "[test_proc_translation] SKIP: $UBIN not staged"
    echo "    Build with: make -C tests/u-binary/src/proc_translation install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_proc_translation] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_proc_translation] (2/4) Swap /init = $HAMSH_ELF + embed u_proc_translation"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_proc_translation] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_proc_translation] (4/4) Boot QEMU + run /bin/u_proc_translation"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_proc_translation\n'
    sleep 3
    printf 'echo POST_PROC_TRANSLATION_OK\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_proc_translation] --- captured output ---"
cat "$LOG"
echo "[test_proc_translation] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_proc_translation] OK: $label"
    else
        echo "[test_proc_translation] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "U1/U2 ELF detect"      "Linux-ABI binary detected"
check_marker "/proc/cpuinfo opens"   "[proc-translation] /proc/cpuinfo open OK"
check_marker "/dev/cpuinfo opens"    "[proc-translation] /dev/cpuinfo open OK"
check_marker "byte-equality"         "[proc-translation] /proc/cpuinfo == /dev/cpuinfo OK"
check_marker "vendor line present"   "[proc-translation] vendor line present OK"

# Surface every diagnostic the fixture emits so a regression names
# itself in the test log. Each negative marker corresponds to one of
# the failure-exit paths in proc_translation.S.
for negmark in \
    "[proc-translation] open(/proc/cpuinfo) FAIL" \
    "[proc-translation] read(/proc/cpuinfo) FAIL" \
    "[proc-translation] open(/dev/cpuinfo) FAIL" \
    "[proc-translation] read(/dev/cpuinfo) FAIL" \
    "[proc-translation] length mismatch FAIL" \
    "[proc-translation] byte mismatch FAIL" \
    "[proc-translation] vendor line missing FAIL"
do
    if grep -F -q "$negmark" "$LOG"; then
        echo "[test_proc_translation] DIAG: fixture reported '$negmark'"
        fail=1
    fi
done

# Hamsh-survives-the-child sentinel — same shape as test_u9_access.sh.
if grep -F -q "POST_PROC_TRANSLATION_OK" "$LOG"; then
    echo "[test_proc_translation] OK: hamsh remains responsive"
else
    echo "[test_proc_translation] MISS: hamsh died after fixture run"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_proc_translation] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_proc_translation] PASS — Layer-2 /proc/cpuinfo -> /dev/cpuinfo working"
