#!/usr/bin/env bash
# scripts/test_fd_marker_uniqueness.sh — static drift-check that every
# special-fd sentinel marker (FD_*_MARK : uint32 = 0xFFFFFFxx) has a
# GLOBALLY UNIQUE value across the whole source tree.
#
# WHY THIS EXISTS
# ---------------
# Hamnix tags special file descriptors with a 32-bit "marker" constant
# (stored in task.fd_idx[]) so the VFS / syscall layer can route a
# read/write/close/poll to the right backend. fs/vfs.ad's dispatch is a
# chain of independent `if file_idx == FD_FOO_MARK:` arms — several of
# which are NOT mutually exclusive (e.g. vfs_close runs its FD_NET_MARK
# teardown AND its FD_SIGNALFD_MARK teardown as separate `if`s). If two
# DISTINCT markers share the same numeric value, a single fd matches
# BOTH arms: one backend's handler runs on the OTHER backend's packed
# fd_buf, silently corrupting state (calling devnet_conn_unref() on a
# bogus /net conn while closing a signalfd, etc.).
#
# This has already bitten the tree THREE times:
#   * FD_AUTH_MARK / FD_P9_MARK   (fixed historically)
#   * FD_EPOLL_MARK / FD_DEVFD_MARK (0xDF — fixed, see u_epoll.ad)
#   * FD_NET_MARK / FD_SIGNALFD_MARK (0xD8) + FD_AUTH_MARK / FD_FAT_MARK
#     (0xF7) — fixed in the commit that adds this test.
#
# A duplicated marker is a latent landmine; this guard makes it a hard,
# cheap, host-side FAIL the moment any two collide again.
#
# Pure static check — greps the sources, extracts all marker values,
# fails if any value repeats. No build, no QEMU, runs in well under a
# second. Gates on the PASS/FAIL echo line, per repo convention.
#
# Usage:
#   bash scripts/test_fd_marker_uniqueness.sh
#
# Prints "[test_fd_markers] PASS" and exits 0 if all markers are
# distinct; prints "[test_fd_markers] FAIL" (with the offending pairs)
# and exits 1 otherwise.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. "$PROJ_ROOT/scripts/_verdict.sh"
# NOTE: this gate is a PURE STATIC source scan — no build, no QEMU, no boot.
# It therefore has NO starvation/INCONCLUSIVE state: the assertion is always
# fully observed. It adopts the verdict_* vocabulary only so its terminal
# line matches the standard `[tag] (PASS|FAIL):` grep shape; it stays a
# DIRECT (unwrapped) manifest gate, never ci_run_gate.sh.
TAG=test_fd_markers

# Extract every  FD_NAME_MARK : uint32 = 0xFFFFFFxx  definition across
# all .ad sources, normalize to "0xVALUE NAME" (uppercased hex), one per
# line. Matches optional whitespace around ':' and '=', and trailing
# inline comments. Excludes commented-out lines (leading '#').
# NOTE: scan ONLY the canonical in-repo sources. Exclude the per-agent
# worktree copies under .claude/, generated build/ output, the .git dir,
# and the vendored submodules (adder/, packages/) — otherwise every
# marker shows up dozens of times (once per source-tree copy) and trips
# a bogus self-"collision".
mapfile -t entries < <(
    grep -rhnE '^[[:space:]]*FD_[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*uint32[[:space:]]*=[[:space:]]*0[xX][Ff]{2}[0-9A-Fa-f]{6}' \
        --include='*.ad' \
        --exclude-dir=.claude --exclude-dir=build --exclude-dir=.git \
        --exclude-dir=adder --exclude-dir=packages \
        . 2>/dev/null \
    | sed -E 's/^[0-9]+://' \
    | grep -oiE 'FD_[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*uint32[[:space:]]*=[[:space:]]*0x[0-9A-Fa-f]{8}' \
    | sed -E 's/[[:space:]]*:[[:space:]]*uint32[[:space:]]*=[[:space:]]*/ /' \
    | awk '{ name=$1; val=toupper($2); print val, name }' \
    | sort -u
)

n="${#entries[@]}"
if [ "$n" -eq 0 ]; then
    verdict_fail "$TAG" "found ZERO FD_*_MARK definitions — grep/regex broke?"
fi

# Walk the value-sorted list; flag any adjacent pair with equal value.
dup=0
prev_val=""
prev_name=""
for e in "${entries[@]}"; do
    val="${e%% *}"
    name="${e#* }"
    if [ "$val" = "$prev_val" ]; then
        echo "[test_fd_markers] DUPLICATE: $name and $prev_name both = $val"
        dup=1
    fi
    prev_val="$val"
    prev_name="$name"
done

echo "[test_fd_markers] scanned $n FD_*_MARK definitions"

if [ "$dup" -ne 0 ]; then
    verdict_fail "$TAG" "two distinct FD_*_MARK sentinels share a numeric value (see DUPLICATE lines above) — a latent fd-routing collision."
fi

verdict_pass "$TAG" "all $n FD_*_MARK sentinels have globally-unique values."
