#!/usr/bin/env bash
# Fast wc/sort focused repro for the RLIMIT-stack-undersize fix.
set -euo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/_build_lock.sh"
ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
bash scripts/build_local_apt_repo.sh >/dev/null 2>&1 || true
RC_TMP=$(mktemp /tmp/hamsh-rc-wc.XXXXXX.rc)
cat > "$RC_TMP" <<'RCEOF'
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
RCEOF
HAMNIX_DEFAULT_REAL_DEBIAN=1 HAMNIX_HAMSH_RC="$RC_TMP" \
    ENABLE_XHCI_KO=0 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null
LOG=$(mktemp /tmp/kvm-coreutils.XXXXXX.log)
cleanup() { rm -f "$RC_TMP"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true; }
trap cleanup EXIT
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null
echo "LOG=$LOG"
(
    waited=0
    while [ "$waited" -lt 200 ]; do
        grep -aq "TEST_RC_DONE_DEFINING_NS" "$LOG" 2>/dev/null && break
        sleep 1; waited=$((waited + 1))
    done
    sleep 2
    for cmd in "/usr/bin/wc -l /etc/os-release" "/usr/bin/sort /etc/os-release" "/usr/bin/wc -c /etc/debian_version"; do
        tag=$(echo "$cmd" | tr -c 'A-Za-z0-9' '_')
        printf 'echo BAN_%s_S\n' "$tag"; sleep 1
        printf 'enter linux { %s }\n' "$cmd"; sleep 6
        printf 'echo BAN_%s_E\n' "$tag"; sleep 1
    done
    printf 'echo BANNER_ALLDONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 900s qemu-system-x86_64 -kernel "$ELF" -smp 2 -nographic -no-reboot -m 1024M -monitor none -serial stdio > "$LOG" 2>&1 || true
echo "=== TRAP/EXIT lines ==="
grep -na "trap-diag\|\[pf\]\|halting\|exited (code\|SIGSEGV\|BAN_\|BANNER_ALLDONE\|RLIMIT\]" "$LOG" | tail -60
