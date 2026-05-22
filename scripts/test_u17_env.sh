#!/usr/bin/env bash
# scripts/test_u17_env.sh — U17 milestone: envp plumbed onto the Linux
# process init-stack so getenv() works in musl-built binaries.
#
# Builds tests/u-binary/u_musl_env and boots Hamnix with it staged at
# /bin/u_musl_env. Drives hamsh to set HOME and USER shell variables
# (which hamsh exports verbatim via SYS_SPAWN's new envp arg) and then
# runs the binary. The binary prints HOME / USER via getenv(3); if the
# kernel's envp build is right and hamsh's _build_envp_block is right,
# both values come back as the strings hamsh set.
#
# Before U17, hamsh passed envp=0 to SYS_SPAWN and the kernel laid out
# an empty envp[] on the init-stack — getenv("HOME") returned NULL.
#
# U17 PASS criteria:
#   - "U17: HOME=/root" appears on stdout.
#   - "U17: USER=david" appears on stdout.
#   - "U17: envc=2" (the exact count of shell vars we exported).
#
# REQUIRES: musl-gcc on the host. SKIP-on-missing per U-track norm.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_musl_env
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/musl_env; only SKIP on a real
# failure (e.g. a genuine missing musl-gcc).
ensure_ubin_or_skip test_u17_env u_musl_env musl_env

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u17_env] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u17_env] (2/4) Swap /init = $HAMSH_ELF + embed u_musl_env"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u17_env] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u17_env] (4/4) Boot QEMU + run /bin/u_musl_env via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'HOME=/root\n'
    sleep 1
    printf 'USER=david\n'
    sleep 1
    printf 'u_musl_env\n'
    sleep 2
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

echo "[test_u17_env] --- captured output ---"
cat "$LOG"
echo "[test_u17_env] --- end output ---"

fail=0

# Primary: getenv("HOME") returned the value hamsh set.
if grep -F -q "U17: HOME=/root" "$LOG"; then
    echo "[test_u17_env] OK: getenv(\"HOME\") returned /root"
else
    echo "[test_u17_env] MISS: 'U17: HOME=/root' — envp didn't reach musl"
    if grep -F -q "U17: HOME=(unset)" "$LOG"; then
        echo "[test_u17_env] DIAG: HOME=(unset) — envp is empty at musl startup."
        echo "[test_u17_env]   Either hamsh's envp build is wrong, or the kernel"
        echo "[test_u17_env]   path is still calling _build_user_argv_linux with"
        echo "[test_u17_env]   envp_user=0."
    fi
    fail=1
fi

# Primary: getenv("USER") returned the value hamsh set.
if grep -F -q "U17: USER=david" "$LOG"; then
    echo "[test_u17_env] OK: getenv(\"USER\") returned david"
else
    echo "[test_u17_env] MISS: 'U17: USER=david' — second env entry didn't survive"
    fail=1
fi

# Secondary: envc matches the number of vars hamsh exported.
if grep -F -q "U17: envc=2" "$LOG"; then
    echo "[test_u17_env] OK: envc=2 (HOME + USER both walked)"
else
    echo "[test_u17_env] MISS: 'U17: envc=2' — envp pointer array malformed"
    grep -F "U17: envc=" "$LOG" | head -1 || true
    fail=1
fi

# Sanity: hamsh kept running after the child exited.
if grep -F -q "[hamsh] bye." "$LOG"; then
    echo "[test_u17_env] OK: hamsh reaped u_musl_env and exited cleanly"
else
    echo "[test_u17_env] MISS: hamsh did not reach bye line"
    fail=1
fi

# Diagnostics on failure.
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u17_env] DIAG: kernel logged 'unknown syscall' — musl may be"
    echo "    calling a getenv-adjacent libc syscall we don't stub yet."
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u17_env] DIAG: CPU exception — likely bad pointer in envp."
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u17_env] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u17_env] PASS — envp plumbed into Linux process init-stack"
