#!/usr/bin/env bash
# scripts/test_u10_pie.sh — U10 milestone: static-PIE Linux ELF.
#
# Boots Hamnix with /bin/u_pie embedded in the initramfs and drives
# hamsh to exec it. u_pie is a host-built, static-PIE, OSABI=Linux
# x86_64 ELF whose .data carries one absolute `.quad msg` slot that
# the linker emitted as an R_X86_64_RELATIVE entry in .rela.dyn.
#
# The marker line ONLY appears if fs/elf.ad::_load_elf64 walks
# PT_DYNAMIC, finds DT_RELA, and rewrites the slot to point at
# msg's RUNTIME address (region + msg_vaddr - lowest_v). Without
# the U10 reloc pass the slot stays at its link-time value
# (0x2000), which is far outside the user-mode image — the kernel
# either rejects the write(2) buffer or, more likely, the SYSCALL
# returns -EFAULT and "U10: pie hello via reloc" never appears.
#
# Skip-on-missing: if tests/u-binary/u_pie hasn't been built on the
# host (`make -C tests/u-binary/src/pie install`), exit 0 with a
# notice so CI in environments without `as`/`ld` still passes.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_pie
if [ ! -f "$UBIN" ]; then
    echo "[test_u10_pie] SKIP: $UBIN not staged"
    echo "    Build with: make -C tests/u-binary/src/pie install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u10_pie] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u10_pie] (2/4) Swap /init = $HAMSH_ELF + embed u_pie"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u10_pie] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u10_pie] (4/4) Boot QEMU + run /bin/u_pie via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_pie\n'
    sleep 2
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
rc=$?
set -e

echo "[test_u10_pie] --- captured output ---"
cat "$LOG"
echo "[test_u10_pie] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u10_pie] OK: $label  ('$needle')"
    else
        echo "[test_u10_pie] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Primary success criterion: the relocated msg pointer survived
# the write(2) syscall and the marker line landed on serial.
check_marker "static-PIE reloc applied" "U10: pie hello via reloc"
# Secondary: the loader announced it was applying relocations.
# Static-PIE with -nostdlib emits exactly 1 R_X86_64_RELATIVE
# (for the `.quad msg` slot), so the summary should read
# "applied 1 relocations".
check_marker "loader logged reloc count" "elf64: applied 1 relocations"
# U1/U2 path: OSABI=Linux byte got noticed.
check_marker "U1/U2 ELF detect"          "Linux-ABI binary detected"

# Sanity: hamsh kept running after the child exited.
if grep -F -q "[hamsh] bye." "$LOG"; then
    echo "[test_u10_pie] OK: hamsh reaped u_pie and exited cleanly"
else
    echo "[test_u10_pie] MISS: hamsh did not reach bye line"
    fail=1
fi

# Diagnostic: a #PF (vector 0x0e) from user mode on the deref'd
# pointer would surface as a do_trap printk. Pre-U10 a kernel that
# never applied the RELATIVE reloc would either #PF here (if the
# stale 0x2000 address is unmapped at CPL=3) or write(2) returns
# -EFAULT silently.
if grep -F -q "TRAP: vector 0x0e" "$LOG"; then
    echo "[test_u10_pie] DIAG: kernel reported #PF — likely user-mode" \
         "deref of unrelocated absolute pointer (pre-U10 behavior)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u10_pie] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u10_pie] PASS — static-PIE binary ran via dynamic relocations"
