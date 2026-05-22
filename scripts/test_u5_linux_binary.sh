#!/usr/bin/env bash
# scripts/test_u5_linux_binary.sh - U5 milestone end-to-end test.
#
# Boots Hamnix with /bin/u_hello embedded in the initramfs and drives
# hamsh to exec it. u_hello is a host-built, static, OSABI=Linux x86_64
# ELF whose _start does:
#
#     write(1, "U5: hello from a Linux ELF\n", 27);
#     exit_group(0);
#
# using the Linux syscall numbers (SYS_write=1, SYS_exit_group=231).
# Hitting that prompt means the full U1..U4 chain works on a real
# binary that was NEVER compiled for Hamnix: PT_LOAD + Linux-OSABI
# detection (U1/U2), per-task is_linux_userspace flag (U3), and
# u_syscalls routing (U4) all line up. If we see the line, this is
# the FIRST end-to-end Linux ELF running on Hamnix.
#
# Skip-on-missing: if tests/u-binary/u_hello hasn't been built on the
# host (`make -C tests/u-binary/src/hello install`), exit 0 with a
# notice so CI in environments without `as`/`ld` still passes.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_hello
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/hello; only SKIP on a real failure.
ensure_ubin_or_skip test_u5_linux_binary u_hello hello

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u5_linux_binary] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u5_linux_binary] (2/4) Swap /init = $HAMSH_ELF + embed u_hello"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u5_linux_binary] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u5_linux_binary] (4/4) Boot QEMU + run /bin/u_hello via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'u_hello\n'
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

echo "[test_u5_linux_binary] --- captured output ---"
cat "$LOG"
echo "[test_u5_linux_binary] --- end output ---"

fail=0
# Primary success criterion: the u_hello write() syscall's payload
# appeared on the kernel console. This requires U1 (ELF loader saw
# the OSABI=Linux ident), U2/U3 (per-task is_linux_userspace flag
# flipped on by elf_is_linux_binary), and U4 (syscall entry routed
# via u_syscalls so SYS_write=1 mapped to Hamnix sys_write).
if grep -F -q "U5: hello from a Linux ELF" "$LOG"; then
    echo "[test_u5_linux_binary] OK: u_hello reached write(1, ...)"
else
    echo "[test_u5_linux_binary] MISS: 'U5: hello from a Linux ELF'"
    fail=1
fi
# Secondary: the U1/U2 detect printk from fs/elf.ad's exec path is a
# strong signal that the OSABI-byte rewrite at install time stuck and
# the ELF loader is taking the Linux branch on this binary.
if grep -F -q "Linux-ABI binary detected" "$LOG"; then
    echo "[test_u5_linux_binary] OK: ELF loader detected Linux-ABI"
else
    echo "[test_u5_linux_binary] WARN: no 'Linux-ABI binary detected' printk"
fi
# Sanity: hamsh kept running after the child exited. exit_group(0)
# should reap cleanly and return the prompt to the shell's main loop.
if grep -F -q "[hamsh] bye." "$LOG"; then
    echo "[test_u5_linux_binary] OK: hamsh reaped u_hello and exited cleanly"
else
    echo "[test_u5_linux_binary] MISS: hamsh did not reach bye line"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u5_linux_binary] FAIL (qemu rc=$rc) — capture above is the U6 diagnostic"
    exit 1
fi

echo "[test_u5_linux_binary] PASS — first Linux ELF on Hamnix!"
