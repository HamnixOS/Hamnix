#!/usr/bin/env bash
# scripts/test_u24_cpp_demo.sh -- U24 milestone: first C++ static-PIE
# binary running through the Hamnix U-track ABI.
#
# Boots Hamnix with /bin/u_cpp_demo embedded in the initramfs and
# drives hamsh to exec it. u_cpp_demo is a host-built static-PIE
# OSABI=Linux x86_64 ELF that exercises libstdc++ + libgcc on top of
# the same glibc surface U22 covers. The four markers it must produce
# on serial are:
#
#   1. "U24: cpp hello via std::cout" -- iostream + TLS-backed locale
#      state walking through %fs:.
#   2. "U24: sorted=1 2 3 5 8 9"      -- std::vector + std::sort,
#      stressing libstdc++'s allocator (operator new -> malloc).
#   3. "U24: hello, world!"           -- std::string concat (short-
#      string optimisation + the heap path beyond the SSO limit).
#   4. "U24: exception caught"        -- try/throw/catch, exercising
#      libgcc's _Unwind_RaiseException, .eh_frame walk via
#      _dl_iterate_phdr (keyed off auxv AT_PHDR/AT_PHENT/AT_PHNUM).
#
# Skip-on-missing: if tests/u-binary/u_cpp_demo hasn't been built
# on the host (`make -C tests/u-binary/src/cpp_demo install`),
# exit 0 with a notice so CI in environments without g++/libstdc++
# static still passes.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_cpp_demo
if [ ! -f "$UBIN" ]; then
    echo "[test_u24_cpp_demo] SKIP: $UBIN not staged"
    echo "    REQUIRES host g++ + libc6-dev + static libstdc++."
    echo "    apt-get install -y g++ libc6-dev  # (needs sudo)"
    echo "    then: make -C tests/u-binary/src/cpp_demo install"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u24_cpp_demo] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u24_cpp_demo] (2/4) Swap /init = $HAMSH_ELF + embed u_cpp_demo"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u24_cpp_demo] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u24_cpp_demo] (4/4) Boot QEMU + run /bin/u_cpp_demo via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 5
    printf 'u_cpp_demo\n'
    sleep 60
    printf 'exit\n'
    sleep 1
) | timeout 120s qemu-system-x86_64 \
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

echo "[test_u24_cpp_demo] --- captured output ---"
cat "$LOG"
echo "[test_u24_cpp_demo] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u24_cpp_demo] OK: $label  ('$needle')"
    else
        echo "[test_u24_cpp_demo] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Primary success criteria: each of the four libstdc++ / libgcc paths
# produced its marker line on serial.
check_marker "iostream std::cout"          "U24: cpp hello via std::cout"
check_marker "std::vector + std::sort"     "U24: sorted=1 2 3 5 8 9"
check_marker "std::string concat"          "U24: hello, world!"
check_marker "try/throw/catch + _Unwind_*" "U24: exception caught"
# Secondary: the U1 ELF-detect path noticed the OSABI=Linux byte.
check_marker "U1/U2 ELF detect"            "Linux-ABI binary detected"

# Diagnostics: surface the next-gap signal for triage.
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u24_cpp_demo] DIAG: kernel logged 'unknown syscall'"
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u24_cpp_demo] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "linux_u:" "$LOG"; then
    echo "[test_u24_cpp_demo] DIAG: linux_u trace lines"
    grep -F "linux_u:" "$LOG" | head -20 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u24_cpp_demo] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u24_cpp_demo] PASS -- iostream + STL + string + C++ exceptions all live"
