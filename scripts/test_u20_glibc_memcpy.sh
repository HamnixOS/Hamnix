#!/usr/bin/env bash
# scripts/test_u20_glibc_memcpy.sh -- U20 milestone: kernel stops
# processing ELF relocations; glibc's _dl_relocate_static_pie does
# its own RELATIVE / GLOB_DAT / JUMP_SLOT / IRELATIVE pass.
#
# Boots Hamnix with /bin/u_glibc_memcpy embedded in the initramfs and
# drives hamsh to exec it. u_glibc_memcpy is a host-built, static-PIE,
# OSABI=Linux x86_64 ELF that calls glibc's memcpy() — which on
# modern glibc is an IFUNC: the .got slot starts pointing at the
# resolver function and only becomes a real memcpy after the
# R_X86_64_IRELATIVE entries in .rela.dyn have been processed.
#
# Pre-U20 Hamnix walked .rela.dyn in the kernel but skipped the 22
# IRELATIVE entries glibc ships (the kernel had no resolver caller).
# U20 deletes the kernel reloc walker entirely; glibc's _start does
# the work itself, including invoking each IFUNC resolver. If we see
# the marker line, the IRELATIVE pass ran to completion.
#
# Skip-on-missing: if tests/u-binary/u_glibc_memcpy hasn't been built
# on the host (`make -C tests/u-binary/src/glibc_memcpy install`),
# exit 0 with a notice so CI in environments without libc6-dev still
# passes.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_glibc_memcpy
if [ ! -f "$UBIN" ]; then
    echo "[test_u20_glibc_memcpy] SKIP: $UBIN not staged"
    echo "    REQUIRES host cc + libc6-dev (static glibc)."
    echo "    apt-get install -y libc6-dev  # (needs sudo)"
    echo "    then: make -C tests/u-binary/src/glibc_memcpy install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u20_glibc_memcpy] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u20_glibc_memcpy] (2/4) Swap /init = $HAMSH_ELF + embed u_glibc_memcpy"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u20_glibc_memcpy] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u20_glibc_memcpy] (4/4) Boot QEMU + run /bin/u_glibc_memcpy via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_glibc_memcpy\n'
    sleep 4
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

echo "[test_u20_glibc_memcpy] --- captured output ---"
cat "$LOG"
echo "[test_u20_glibc_memcpy] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u20_glibc_memcpy] OK: $label  ('$needle')"
    else
        echo "[test_u20_glibc_memcpy] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Primary success criterion: glibc's _start ran _dl_relocate_static_pie
# (including IRELATIVE resolvers) successfully and memcpy() copied the
# string. Without the IRELATIVE pass the memcpy call would land in the
# resolver function and either crash or write garbage.
check_marker "glibc ifunc memcpy resolved" "U20: ifunc memcpy ok"
# Secondary: the U1 ELF-detect path noticed the OSABI=Linux byte.
check_marker "U1/U2 ELF detect"            "Linux-ABI binary detected"

# Diagnostics: surface the next-gap signal for triage.
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u20_glibc_memcpy] DIAG: kernel logged 'unknown syscall'"
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u20_glibc_memcpy] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u20_glibc_memcpy] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u20_glibc_memcpy] PASS -- glibc's IRELATIVE pass ran; IFUNC memcpy works"
