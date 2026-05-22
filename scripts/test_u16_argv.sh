#!/usr/bin/env bash
# scripts/test_u16_argv.sh — U16 milestone: Linux process init-stack.
#
# Builds tests/u-binary/u_musl_argv (same fixture as U15) and boots
# Hamnix with it staged at /bin/u_musl_argv. Where U15 only required
# that musl's printf path *worked* (argc=0 was tolerated), U16
# requires that the kernel hands main() a real argc/argv via the
# Linux process init-stack ABI:
#
#   *rsp at user entry:
#       argc
#       argv[0..argc-1], NULL
#       envp[0..envc-1], NULL
#       auxv pairs ending in AT_NULL
#
# musl's _start does `mov %rsp,%rdi; call _start_c`; _start_c then
# reads argc from `(*rdi)` and walks argv / envp / auxv from rdi+8.
# Before U16 the kernel laid out argv at *rsp and passed argc/argv
# via %rdi/%rsi (the native-Hamnix SysV convention), so musl's
# _start_c read random stack as argc and the fixture printed
# "argc=0".
#
# U16 PASS criteria:
#   - "U15: musl printf works! argc=1" appears (the printf marker
#     stays the same; only the value changes).
#   - "  arg[0]=" appears with a non-empty path after the '='.
#
# REQUIRES: musl-gcc on the host. SKIP-on-missing per U-track norm.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_musl_argv
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/musl_argv; only SKIP on a real
# failure (e.g. a genuine missing musl-gcc).
ensure_ubin_or_skip test_u16_argv u_musl_argv musl_argv

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u16_argv] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u16_argv] (2/4) Swap /init = $HAMSH_ELF + embed u_musl_argv"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u16_argv] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u16_argv] (4/4) Boot QEMU + run /bin/u_musl_argv via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_musl_argv\n'
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

echo "[test_u16_argv] --- captured output ---"
cat "$LOG"
echo "[test_u16_argv] --- end output ---"

fail=0

# Primary: argc came through as 1 — the Linux init-stack layout works.
if grep -F -q "U15: musl printf works! argc=1" "$LOG"; then
    echo "[test_u16_argv] OK: argc=1 (Linux init-stack handed musl a real argc)"
else
    echo "[test_u16_argv] MISS: argc=1 line — Linux init-stack regressed"
    if grep -F -q "U15: musl printf works! argc=0" "$LOG"; then
        echo "[test_u16_argv] DIAG: argc=0 still — kernel didn't switch to Linux layout."
    fi
    fail=1
fi

# Secondary: arg[0] is non-empty — argv[0] resolves to a real string.
# The kernel's early_putc stamps every console line with a monotonic
# "[NNNNNN] " sequence prefix (commit e664fd3), so the fixture's
# "  arg[0]=..." line lands on serial as "[000249]   arg[0]=...".
# Allow that optional log prefix before the two-space-indented marker
# so the anchor stays strict (real indent + non-empty value) without
# being defeated by the line stamp.
arg0_re='^(\[[0-9]{6}\] )?  arg\[0\]=.+$'
if grep -E -q "$arg0_re" "$LOG"; then
    arg0_line=$(grep -E "$arg0_re" "$LOG" | head -1)
    echo "[test_u16_argv] OK: $arg0_line"
else
    echo "[test_u16_argv] MISS: 'arg[0]=<non-empty>' — argv[0] string didn't resolve"
    fail=1
fi

# Sanity: hamsh kept running after the child exited.
if grep -F -q "[hamsh] bye." "$LOG"; then
    echo "[test_u16_argv] OK: hamsh reaped u_musl_argv and exited cleanly"
else
    echo "[test_u16_argv] MISS: hamsh did not reach bye line"
    fail=1
fi

# Diagnostics on failure.
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u16_argv] DIAG: kernel logged 'unknown syscall' —" \
         "auxv walk may have hit a new Linux syscall."
    grep -F "unknown syscall" "$LOG" | sort -u || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u16_argv] DIAG: CPU exception — likely bad pointer in argv/envp/auxv."
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u16_argv] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u16_argv] PASS — Linux process init-stack works on Hamnix"
