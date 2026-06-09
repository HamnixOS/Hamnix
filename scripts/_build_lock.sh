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
#
# Opt-in build isolation: when HAMNIX_BUILD_DIR is set, the lock (and the
# auto-wiped outputs) live in that caller-chosen directory instead. Two
# builds in ONE checkout with DIFFERENT HAMNIX_BUILD_DIR then take
# DIFFERENT locks and run in parallel. Unset → the historical
# script-relative ../build path.
if [ -n "${HAMNIX_BUILD_DIR:-}" ]; then
    _HAMNIX_BUILD_LOCK_DIR="$HAMNIX_BUILD_DIR"
else
    _HAMNIX_BUILD_LOCK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build"
fi
mkdir -p "$_HAMNIX_BUILD_LOCK_DIR"
_HAMNIX_BUILD_LOCK="$_HAMNIX_BUILD_LOCK_DIR/.build_lock"
_HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-120}"

# Higher-half kernel boot shim. The Hamnix kernel is now a true elf64
# higher-half image, which QEMU's `-kernel` multiboot1 loader refuses
# to load. _kernel_iso.sh defines a `qemu-system-x86_64` shell function
# that transparently boots an ELFCLASS64 `-kernel` target from a BIOS
# GRUB ISO instead. Sourced here — before the reentrancy return below —
# so every test_*.sh that sources _build_lock.sh (as its first action)
# picks the shim up. Real Linux bzImages and `-cdrom`/`-bios` boots are
# passed through untouched. See scripts/_kernel_iso.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_iso.sh"

# Reentrancy guard: many test_*.sh scripts source us AND invoke
# scripts/build_iso.sh which also sources us. The child process
# inherits fd 200 from the parent, but the child's `flock -x 200`
# would deadlock waiting for the lock the parent already holds.
# Detect "we're nested under a parent that already locked" via an
# exported env var that we set after acquiring. Same-worktree only —
# the lock path is part of the sentinel so a child from a different
# worktree (impossible today, but defensible) still acquires its own.
if [ "${HAMNIX_BUILD_LOCK_HELD:-}" = "$_HAMNIX_BUILD_LOCK" ]; then
    # Parent in this same worktree already holds the lock. Skip
    # re-acquisition. No `exec 200>` either — we don't want to clobber
    # the parent's fd 200 (it's inherited and the lock state is
    # attached to the inherited open-file-description).
    return 0 2>/dev/null || true
fi

# fd 200 reserved; matches conventional flock-in-bash pattern.
exec 200>"$_HAMNIX_BUILD_LOCK"
if ! flock -x -w "$_HAMNIX_BUILD_LOCK_TIMEOUT" 200; then
    echo "[$(basename "$0")] build lock timeout (${_HAMNIX_BUILD_LOCK_TIMEOUT}s) —" \
         "another test still holds $_HAMNIX_BUILD_LOCK." \
         "Override timeout: HAMNIX_BUILD_LOCK_TIMEOUT=<seconds>" >&2
    exit 1
fi

# Auto-wipe stale compiled outputs so every test starts from a clean
# build. A build interrupted hard (kill -9 of a compiler.adder compile)
# leaves TRUNCATED .elf / blob artifacts that the incremental rebuild
# won't regenerate — silently poisoning the next test (e.g. a kernel
# that boots to nothing, or a "not found" for an embedded binary).
# We hold the build lock here, so nothing races this wipe.
#   - WIPED: compiled code outputs (the poison surface).
#   - SPARED: build/*.img disk images (some tests persist + reuse them)
#             and build/.build_lock (a dotfile; * doesn't match it, and
#             fd 200 stays valid regardless).
rm -rf "$_HAMNIX_BUILD_LOCK_DIR"/user "$_HAMNIX_BUILD_LOCK_DIR"/mod \
       "$_HAMNIX_BUILD_LOCK_DIR"/iso "$_HAMNIX_BUILD_LOCK_DIR"/*.elf \
       "$_HAMNIX_BUILD_LOCK_DIR"/*.iso 2>/dev/null || true
# The in-source blob (default builds) AND an isolated build-dir blob
# (HAMNIX_BUILD_DIR builds) are both poison surfaces — wipe whichever
# applies. For the default case _HAMNIX_BUILD_LOCK_DIR is ../build so the
# first path resolves to ../fs/initramfs_blob.S as before; the second is
# a harmless no-op. For an isolated build dir the second path is the live
# blob and the first is a no-op.
rm -f "$_HAMNIX_BUILD_LOCK_DIR/../fs/initramfs_blob.S" 2>/dev/null || true
rm -f "$_HAMNIX_BUILD_LOCK_DIR/initramfs_blob.S" 2>/dev/null || true

export HAMNIX_BUILD_LOCK_HELD="$_HAMNIX_BUILD_LOCK"
