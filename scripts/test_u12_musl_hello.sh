#!/usr/bin/env bash
# scripts/test_u12_musl_hello.sh — U12 milestone: first real
# toolchain-built C binary running on Hamnix.
#
# Boots Hamnix with /bin/u_musl_hello embedded in the initramfs
# and drives hamsh to exec it. u_musl_hello is a host-built,
# musl-libc, static-PIE, OSABI=Linux x86_64 ELF whose `int main()`
# fires an inline `write(2)` syscall to emit a marker. The whole
# point of U12 is that everything ahead of `main()` — musl's
# crt1.o `_start`, `__libc_start_main`, `__init_libc` — runs
# *unmodified* against Hamnix's U-track syscall surface.
#
# Why this is a milestone: musl static-PIE only touches
#   arch_prctl(ARCH_SET_FS), set_tid_address, brk, writev/write,
#   exit_group
# and Hamnix implements all of those — so this is the smallest
# bona-fide GCC-toolchain binary that ought to "just work."
# (glibc static, by contrast, drags in TLS / sigaction / futex
# / poll / read-/proc-/self-/maps on startup and dies.)
#
# REQUIRES: musl-gcc on the host. If tests/u-binary/u_musl_hello
# hasn't been staged (because musl-gcc wasn't installed at
# `make -C tests/u-binary/src/musl_hello install` time), exit 0
# with a clear note so CI without the host toolchain still passes.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_musl_hello
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/musl_hello; only SKIP on a real
# failure (e.g. a genuine missing musl-gcc).
ensure_ubin_or_skip test_u12_musl_hello u_musl_hello musl_hello

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u12_musl_hello] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u12_musl_hello] (2/4) Swap /init = $HAMSH_ELF + embed u_musl_hello"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u12_musl_hello] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u12_musl_hello] (4/4) Boot QEMU + run /bin/u_musl_hello via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_musl_hello\n'
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

echo "[test_u12_musl_hello] --- captured output ---"
cat "$LOG"
echo "[test_u12_musl_hello] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u12_musl_hello] OK: $label  ('$needle')"
    else
        echo "[test_u12_musl_hello] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Primary success criterion: musl's crt1 + __libc_start_main ran
# to completion against the Hamnix syscall surface and main()'s
# inline write(2) made it onto serial.
#
# U20: the kernel no longer processes relocations (and so no
# "elf64: applied ... relocations" log line) — musl's own
# _dl_relocate_static_pie inside _start fixes RELATIVE / GLOB_DAT
# / JUMP_SLOT / IRELATIVE using AT_PHDR / AT_PHNUM / AT_ENTRY from
# auxv. If "U12: musl hello" hits serial, the self-relocation pass
# succeeded; there is no kernel-side signal to assert on.
check_marker "musl main() reached serial" "U12: musl hello"
# Secondary: U1/U2 path — the OSABI=Linux byte got noticed.
check_marker "U1/U2 ELF detect"           "Linux-ABI binary detected"

# Sanity: hamsh kept running after the child exited.
if grep -F -q "[hamsh] bye." "$LOG"; then
    echo "[test_u12_musl_hello] OK: hamsh reaped u_musl_hello and exited cleanly"
else
    echo "[test_u12_musl_hello] MISS: hamsh did not reach bye line"
    fail=1
fi

# Diagnostics: surface useful failure-mode hints for U13 triage.
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u12_musl_hello] DIAG: kernel logged 'unknown syscall' —" \
         "musl exercised a syscall Hamnix doesn't handle yet."
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u12_musl_hello] DIAG: kernel reported a CPU exception" \
         "— check vector + RIP for user-mode fault site."
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "ENOSYS" "$LOG"; then
    echo "[test_u12_musl_hello] DIAG: -ENOSYS returned to userspace —" \
         "musl may or may not tolerate; check which nr."
    grep -F "ENOSYS" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u12_musl_hello] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u12_musl_hello] PASS — first real toolchain-built C" \
     "binary ran on Hamnix"
