#!/usr/bin/env bash
# scripts/test_useradd.sh — ACCEPTANCE GATE for `useradd`: a per-user
# home FILE SERVER on the shared ext4 root (docs/security.md, the
# multi-user landing).
#
# The user's design intent (verbatim): "as we add in users, it should
# make additional top-level directories that become file servers with
# the user's name to be used for their home folder. The point is to
# keep the isolation, but at the same time be able to use the entire
# disk space for whatever needs it."
#
# So `useradd bob` must:
#   * append a `bob bob` line to `.hamnix-roots` on the ext4 root,
#   * create a top-level `bob/` directory on the same ext4 partition,
#   * register `#bob` so it resolves (live this boot; via the sentinel
#     on the next boot),
#   * give bob a /home/bob that is namespace-isolated from sysroot's
#     /home and from the Debian distro/ tree.
#
# HOW THIS TEST PROVES IT (two boots of the SAME, now-modified disk):
#
#   BOOT 1 — run `useradd bob`, then exercise the LIVE `#bob` root:
#     1. `useradd bob`                              — create the user.
#     2. `bind '#bob' /home/bob`                    — graft bob's home
#                                                      server (the LIVE
#                                                      name_push from
#                                                      the syscall).
#     3. write a marker into /home/bob/, then `ls '#bob'`
#                                                   — the marker MUST
#                                                      appear under the
#                                                      #bob file server.
#     4. native `ls /home`                          — the marker MUST
#                                                      NOT appear (bob's
#                                                      home is a SEPARATE
#                                                      top-level subtree,
#                                                      not under sysroot).
#     5. `enter debian { /bin/ls / }`               — the distro root
#                                                      MUST NOT carry a
#                                                      `bob` top-level
#                                                      dir (isolation
#                                                      from distro/).
#
#   BOOT 2 — reboot the SAME disk image (bob's edits persisted) and grep
#   the kernel sentinel-parser log:
#     6. the boot log MUST show `.hamnix-roots: #bob -> bob`            —
#        proving the `bob bob` sentinel LINE and the top-level `bob/`
#        dir were durably written to the partition root by useradd
#        (the parser only registers a `#bob` root if the line is present
#        AND name_push succeeds).
#
# ASSERTIONS:
#   A. `useradd bob` reported success ("created bob ... home server #bob").
#   B. The marker written into /home/bob appears under `ls '#bob'`.
#   C. The marker does NOT appear in native `ls /home` (sysroot home).
#   D. The distro root has no `bob` top-level dir.
#   E. BOOT 2's kernel log shows `.hamnix-roots: #bob -> bob` (durable
#      sentinel line + top-level dir survived the reboot).
#
# Boots the INSTALLED ext4-on-NVMe system (the golden disk produced by the
# real installer, scripts/build_installed_nvme.sh) — the baked hamnix.img
# was retired; a real system is installed onto a disk, never shipped as a
# pre-baked root image. The boot harness lives in scripts/_installed_boot.sh,
# whose per-test writable disk copy persists boot-1's useradd edits into
# boot-2 (exactly the old single-IMG_RW two-boot pattern).
#
# SKIPS CLEANLY (exit 0) when /dev/kvm, OVMF, or the golden disk is
# unavailable (the shared helper gates this). The Debian-subsystem probe
# (assertion D) is itself gated on the busybox fixture; if absent we skip
# ONLY that probe and still assert A/B/C/E.
#
# Env overrides:
#   GOLDEN_NVME        installed disk path       (default: build/hamnix-installed.qcow2)
#   OVMF_FD            OVMF firmware path        (default: auto-resolved)
#   SHELL_BOOT_WAIT    seconds to wait for the   (default: 200)
#                      interactive-prompt marker
#   HAMNIX_SKIP_BUILD  1 = require an existing golden disk (no rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KERNEL_BANNER="Hamnix kernel booting"
PROMPT_MARKER="handing off to interactive shell"

# Fence markers driven into the serial stream so the assertions can
# attribute each listing to a specific command in the interleaved log.
M_ADD="HAMNIX_UA_USERADD"
M_BIND="HAMNIX_UA_BIND"
M_BOBLS="HAMNIX_UA_BOB_LS"
M_NATIVE="HAMNIX_UA_NATIVE_HOME"
M_DEBIAN="HAMNIX_UA_DEBIAN_ROOT"
M_DONE="HAMNIX_UA_DONE_99"
# The marker file written into /home/bob. If it shows up in the native
# /home listing, the per-user-home isolation is broken.
BOB_FILE="HAMNIX_BOB_ONLY_MARKER"

# busybox fixture gates ONLY the distro-isolation probe (assertion D).
HAVE_BUSYBOX=1
if [ ! -f "$PROJ_ROOT/tests/u-binary/u_busybox_musl" ]; then
    HAVE_BUSYBOX=0
    echo "[test_useradd] note: tests/u-binary/u_busybox_musl absent — skipping the distro-root probe (D); A/B/C/E still asserted." >&2
fi

# --- boot the installed system (gates KVM/OVMF/golden disk; SKIPs clean) -
# shellcheck source=_installed_boot.sh
source "$PROJ_ROOT/scripts/_installed_boot.sh"

type_cmd() { installed_type "$1" "${2:-4}"; }

# ====================================================================
# BOOT 1 — run useradd + exercise the live #bob home server. The helper's
# per-test writable disk copy persists boot-1's edits into boot-2.
# ====================================================================
installed_boot_start

echo "[test_useradd] BOOT 1: waiting up to ${SHELL_BOOT_WAIT}s for prompt..."
if ! installed_boot_wait; then
    echo "[test_useradd] FAIL: BOOT 1 prompt marker not seen." >&2
    exit 1
fi
echo "[test_useradd] BOOT 1: prompt reached; driving useradd probes."

# 1. Create the user.
type_cmd "echo $M_ADD" 2
type_cmd "useradd bob" 5

# 2. Graft bob's home server (the live name_push from the syscall) and
#    write a marker into it.
type_cmd "echo $M_BIND" 2
type_cmd "bind '#bob' /home/bob" 3
type_cmd "echo hello > /home/bob/$BOB_FILE" 3

# 3. List the #bob file server: the marker MUST be there.
type_cmd "echo $M_BOBLS" 2
type_cmd "ls '#bob'" 4

# 4. Native /home listing: the marker MUST NOT be there (separate
#    top-level subtree, not under sysroot).
type_cmd "echo $M_NATIVE" 2
type_cmd "ls /home" 4

# 5. The distro root MUST NOT carry a `bob` top-level dir (gated on the
#    busybox fixture).
if [ "$HAVE_BUSYBOX" -eq 1 ]; then
    type_cmd "echo $M_DEBIAN" 2
    type_cmd "enter debian { /bin/ls / }" 6
fi

type_cmd "echo $M_DONE" 2
sleep 3

installed_boot_stop

# Capture boot-1's log before BOOT 2 overwrites $INSTALLED_LOG.
LOG1="$INSTALLED_LOG"

# ====================================================================
# BOOT 2 — reboot the SAME (per-test) disk copy; the sentinel parser
# should now find the durable `bob bob` line + top-level bob/ dir and log
# `#bob -> bob`. The helper reuses boot-1's writable disk copy, so bob's
# edits persist.
# ====================================================================
echo "[test_useradd] BOOT 2: rebooting the same disk to verify durable .hamnix-roots edit..."
installed_boot_start

if ! installed_boot_wait; then
    echo "[test_useradd] FAIL: BOOT 2 prompt marker not seen." >&2
    exit 1
fi
echo "[test_useradd] BOOT 2: prompt reached."
type_cmd "echo HAMNIX_UA_BOOT2_DONE" 2
sleep 2

installed_boot_stop

# Capture boot-2's log.
LOG2="$INSTALLED_LOG"

echo "[test_useradd] --- BOOT 1 serial log ---"
cat "$LOG1"
echo "[test_useradd] --- BOOT 2 serial log (head) ---"
head -120 "$LOG2"
echo "[test_useradd] --- end serial logs ---"

# Sanitize boot-1 log (strip CRs + CSI/SGR escapes; busybox ls colorizes).
CLEAN=$(mktemp --tmpdir hamnix-ua.clean.XXXXXX.log)
sed -e 's/\r//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$LOG1" > "$CLEAN"
trap '_ib_cleanup; rm -f "$CLEAN"' EXIT

slice() {
    awk -v a="$1" -v b="$2" '
        $0 ~ a { grab=1; next }
        $0 ~ b { grab=0 }
        grab   { print }
    ' "$CLEAN"
}

ADD=$(slice "$M_ADD" "$M_BIND")
BOBLS=$(slice "$M_BOBLS" "$M_NATIVE")
if [ "$HAVE_BUSYBOX" -eq 1 ]; then
    NATIVE=$(slice "$M_NATIVE" "$M_DEBIAN")
    DEBIAN=$(slice "$M_DEBIAN" "$M_DONE")
else
    NATIVE=$(slice "$M_NATIVE" "$M_DONE")
    DEBIAN=""
fi

fail=0

# Sanity: both boots came up.
grep -a -q "$KERNEL_BANNER" "$LOG1" || { echo "[test_useradd] FAIL: BOOT 1 kernel banner absent." >&2; fail=1; }
grep -a -q "$PROMPT_MARKER" "$LOG1" || { echo "[test_useradd] FAIL: BOOT 1 shell-ready marker absent." >&2; fail=1; }

# A. useradd reported success.
if printf '%s\n' "$ADD" | grep -a -q -E "useradd: created bob"; then
    echo "[test_useradd] PASS (A): useradd bob reported success."
else
    echo "[test_useradd] FAIL (A): 'useradd: created bob' not seen." >&2
    printf '%s\n' "$ADD" | sed 's/^/      /' >&2
    fail=1
fi

# B. the marker appears under the #bob file server.
if printf '%s\n' "$BOBLS" | grep -a -q -F "$BOB_FILE"; then
    echo "[test_useradd] PASS (B): '$BOB_FILE' present under ls '#bob' — #bob resolves to the per-user home subtree."
else
    echo "[test_useradd] FAIL (B): '$BOB_FILE' NOT found under ls '#bob' — #bob did not resolve / the write didn't land." >&2
    printf '%s\n' "$BOBLS" | sed 's/^/      /' >&2
    fail=1
fi

# C. the marker is NOT in native /home (sysroot's home).
if printf '%s\n' "$NATIVE" | grep -a -q -F "$BOB_FILE"; then
    echo "[test_useradd] FAIL (C): '$BOB_FILE' LEAKED into native /home — bob's home is not isolated." >&2
    printf '%s\n' "$NATIVE" | sed 's/^/      /' >&2
    fail=1
else
    echo "[test_useradd] PASS (C): '$BOB_FILE' does NOT appear in native /home — bob's home is a separate subtree."
fi

# D. the distro root carries no `bob` top-level dir (busybox-gated).
if [ "$HAVE_BUSYBOX" -eq 1 ]; then
    if [ -z "$(printf '%s' "$DEBIAN" | tr -d '[:space:]')" ]; then
        echo "[test_useradd] WARN (D): enter debian produced no output (busybox didn't run); skipping D." >&2
    elif printf '%s\n' "$DEBIAN" | grep -a -q -E "(^|[[:space:]/])bob([[:space:]/]|\$)"; then
        echo "[test_useradd] FAIL (D): distro root has a 'bob' top-level dir — per-user home leaked into distro/." >&2
        printf '%s\n' "$DEBIAN" | sed 's/^/      /' >&2
        fail=1
    else
        echo "[test_useradd] PASS (D): distro root has no 'bob' top-level dir."
    fi
fi

# E. BOOT 2's sentinel parser registered #bob -> bob (durable line +
#    top-level dir survived the reboot).
if grep -a -q -E "\.hamnix-roots: #bob -> bob" "$LOG2"; then
    echo "[test_useradd] PASS (E): BOOT 2 kernel log shows '.hamnix-roots: #bob -> bob' — the sentinel line + bob/ dir persisted."
else
    echo "[test_useradd] FAIL (E): BOOT 2 kernel log did NOT show '.hamnix-roots: #bob -> bob' — the durable .hamnix-roots edit / bob/ dir is missing." >&2
    grep -a -E "hamnix-roots|rootfs" "$LOG2" | head -20 | sed 's/^/      /' >&2
    fail=1
fi

# No CPU trap during the run.
if grep -a -q -E "TRAP: vector|page fault" "$LOG1"; then
    echo "[test_useradd] FAIL: CPU exception observed during BOOT 1:" >&2
    grep -a -E "TRAP: vector|page fault" "$LOG1" | head -5 >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_useradd] PASS — useradd created a namespace-isolated per-user home file server on the shared ext4 root."
    rm -f "$LOG1" "$LOG2"
    exit 0
else
    echo "[test_useradd] FAIL (serial logs: $LOG1 , $LOG2)" >&2
    exit 1
fi
