# scripts/_build_lock.sh — shared exclusive lock for the build pipeline.
#
# REAL BUG (not a flake, not a retry-worthy thing):
#
# Every test_*.sh script rebuilds the world (userland binaries +
# initramfs + kernel ELF) IN PLACE in build/, with the per-test
# INIT_ELF override mutating fs/initramfs_blob.S. The kernel image
# then EMBEDS that blob via .incbin, so the kernel's identity
# depends on the source file's contents at compile time.
#
# When two test scripts run concurrently (regression iteration +
# parallel agent-dispatched test, for example):
#
#   1. Test A: build_initramfs.py with INIT_ELF=hamsh.elf  →
#      fs/initramfs_blob.S now embeds hamsh as /init.
#   2. Test B (concurrent): build_initramfs.py with INIT_ELF=hamsh.elf
#      → still hamsh as /init, OK.
#   3. Test B exits via its EXIT trap → INIT_ELF=init.elf rebuild →
#      fs/initramfs_blob.S now embeds the asm init.elf as /init.
#   4. Test A's compiler step reads fs/initramfs_blob.S — gets B's
#      restored state, NOT A's intended hamsh-as-init state.
#   5. Test A's qemu boots a kernel whose /init is init.elf, which
#      exec's /hello (not in /bin/) — test fails with confusing
#      "execve: '/hello' not in initramfs" + exit 24.
#
# This is the bug behind test_cwd / test_dup / test_signals "flakes"
# we'd seen since multi-agent dispatch started. The fix is to
# serialize the entire build+test pipeline against a shared lock.
#
# Usage: each test_*.sh sources this file as its FIRST action
# (before any `set -e`). The flock is held for the lifetime of
# the script (released when the shell exits).

# fd 200 reserved; matches conventional flock-in-bash pattern.
exec 200>/tmp/hamnix-build.lock
if ! flock -x -w 600 200; then
    echo "[$(basename "$0")] build lock timeout (10 min) — another" \
         "test still holds /tmp/hamnix-build.lock" >&2
    exit 1
fi
