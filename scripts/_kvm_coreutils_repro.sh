#!/usr/bin/env bash
# Focused KVM repro for the ET_DYN/stack <-> kernel-stack aliasing #PF.
# Drives the coreutils matrix through `enter linux { ... }` under KVM.
set -euo pipefail
cd "$(dirname "$0")/.."
# Source the build-lock shim: it defines a qemu-system-x86_64 shell
# function that wraps `-kernel <64-bit ELF>` into a throwaway GRUB ISO so
# the host QEMU (which rejects the raw multiboot 64-bit ELF) can boot it.
. "$(dirname "$0")/_build_lock.sh"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
bash scripts/build_local_apt_repo.sh >/dev/null 2>&1 || true

RC_TMP=$(mktemp /tmp/hamsh-rc-kvm.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
linux = ns clean {
    bind '#r/var/lib/distros/default' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
    bind '#t/tmp' /tmp
}
echo TEST_RC_DONE_DEFINING_NS
EOF

# ENABLE_XHCI_KO=0: skip the Linux xHCI .ko dep-chain load at boot — it is
# pure boot-time cost under TCG (no USB device in this repro) and is
# irrelevant to the user-stack aliasing fix under test. Cuts ~8 min off the
# TCG boot so the coreutils matrix actually runs inside the timeout.
HAMNIX_DEFAULT_REAL_DEBIAN=1 HAMNIX_HAMSH_RC="$RC_TMP" \
    ENABLE_XHCI_KO=0 \
    INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LOG=$(mktemp /tmp/kvm-coreutils.XXXXXX.log)
cleanup() {
    rm -f "$RC_TMP"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "LOG=$LOG"
KVM_ARGS=""
KVM_ARGS=""  # host -kernel cannot KVM-boot the 64-bit ELF (multiboot/VBE limit)
(
    waited=0
    while [ "$waited" -lt 180 ]; do
        grep -aq "TEST_RC_DONE_DEFINING_NS" "$LOG" 2>/dev/null && break
        sleep 1; waited=$((waited + 1))
    done
    sleep 2
    for cmd in \
        "/usr/bin/uname -s" \
        "/usr/bin/id" \
        "/usr/bin/ls -la /" \
        "/usr/bin/stat /etc/os-release" \
        "/usr/bin/tail -n1 /etc/os-release" \
        "/usr/bin/cut -d= -f1 /etc/os-release" \
        "/usr/bin/sed -n 1p /etc/os-release" \
        "/usr/bin/head -n2 /etc/os-release" \
        "/usr/bin/md5sum /etc/debian_version" \
        "/usr/bin/readlink -f /etc/os-release" ; do
        tag=$(echo "$cmd" | tr -c 'A-Za-z0-9' '_')
        printf 'echo BAN_%s_S\n' "$tag"; sleep 1
        printf 'enter linux { %s }\n' "$cmd"; sleep 5
        printf 'echo BAN_%s_E\n' "$tag"; sleep 1
    done
    printf 'echo BANNER_ALLDONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 1100s qemu-system-x86_64 \
    -kernel "$ELF" \
    $KVM_ARGS \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 1024M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1 || true

echo "=== TAIL ==="
tail -120 "$LOG" | strings
echo "=== TRAP/EXIT lines ==="
grep -na "trap-diag\|\[pf\]\|halting\|exited (code\|SIGSEGV\|BAN_\|BANNER_ALLDONE\|cur-slot" "$LOG" | tail -80
