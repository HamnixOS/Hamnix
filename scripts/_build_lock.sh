# scripts/_build_lock.sh — per-worktree exclusive lock for the build pipeline.
#
# REAL BUG (not a flake, not a retry-worthy thing):
#
# Every test_*.sh script rebuilds the world (userland binaries +
# initramfs + kernel ELF) IN PLACE in build/, with the per-test
# INIT_ELF override mutating fs/initramfs_blob.S. The kernel image
# then EMBEDS that blob via .incbin, so the kernel's identity
# depends on the source file's contents at compile time.
#
# Within ONE checkout, two concurrent test_*.sh invocations would
# race on fs/initramfs_blob.S — the second one's INIT_ELF clobbers
# the first one's, and qemu boots a kernel built from the wrong
# mix of states. The lock prevents that.
#
# Worktree note (2026-05-18): the lock LIVES IN THE WORKTREE
# (build/.build_lock), not at a global /tmp path. `git worktree`-
# created worktrees have their own physical copy of every tracked
# file including fs/initramfs_blob.S, so agents in separate
# worktrees CAN safely build in parallel — they're touching
# disjoint files on disk. Putting the lock at /tmp would serialise
# them artificially and starve agents that should have been
# independent. Each worktree owns its own lock; the main checkout
# (`/home/david/Hamnix/build/.build_lock`) and any worktree
# (`.claude/worktrees/agent-*/build/.build_lock`) lock different
# files.
#
# Usage: each test_*.sh sources this file as its FIRST action
# (before any `set -e`). The flock is held for the lifetime of
# the script (released when the shell exits). Timeout is 120s —
# if you can't acquire in two minutes within ONE worktree, fail
# fast instead of looping (the previous 600s ate agent cycles).
# Override via HAMNIX_BUILD_LOCK_TIMEOUT=<seconds>.

# Resolve the lock path relative to this script's location, so it
# follows the worktree. ${BASH_SOURCE} is scripts/_build_lock.sh
# inside whichever checkout sourced us.
_HAMNIX_BUILD_LOCK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build"
mkdir -p "$_HAMNIX_BUILD_LOCK_DIR"
_HAMNIX_BUILD_LOCK="$_HAMNIX_BUILD_LOCK_DIR/.build_lock"
_HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-120}"

# fd 200 reserved; matches conventional flock-in-bash pattern.
exec 200>"$_HAMNIX_BUILD_LOCK"
if ! flock -x -w "$_HAMNIX_BUILD_LOCK_TIMEOUT" 200; then
    echo "[$(basename "$0")] build lock timeout (${_HAMNIX_BUILD_LOCK_TIMEOUT}s) —" \
         "another test still holds $_HAMNIX_BUILD_LOCK." \
         "Override timeout: HAMNIX_BUILD_LOCK_TIMEOUT=<seconds>" >&2
    exit 1
fi
