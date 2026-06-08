#!/usr/bin/env bash
# scripts/test_installer_boot_heartbeat.sh - INSTALLER-IMAGE BOOT GATE.
#
# PURPOSE (the orchestrator's pre-push gate)
# ------------------------------------------
# This is the boot SMOKE TEST the orchestrator runs as a GATE before
# pushing anything to main. The user asked, verbatim, for "a test that
# looks for the heartbeat of the ham shell as a gate on whether or not
# you push something." That is exactly this script.
#
# It boots the production installer image (build/hamnix-installer.img)
# under OVMF+TCG single-CPU and PASSES only if the hamsh idle heartbeat
# line "[hamsh-alive]" reaches the serial console AND no fatal-trap
# indication (TRAP: vector / triple fault / double fault / cpu_reset)
# appears. The heartbeat is emitted ~every 3s from hamsh's ed_readline
# idle poll (user/hamsh.ad _hb_emit_to_stderr, ~line 7270); seeing it
# proves SYSRET into ring-3 worked AND the shell keeps getting scheduled
# across timer IRQs from userspace.
#
# Why an installer-image boot specifically: scripts/test_hamsh_heartbeat.sh
# boots a -kernel ELF directly and never exercises the full OVMF -> EFI
# stub -> kernel -> userspace-IRQ path. Boot regression #402 (per-CPU
# TSS/GDT/MSR) triple-faulted at the FIRST timer IRQ from userspace
# (#UD->#GP->#DF->cpu_reset) so NO heartbeat ever appeared on the
# installer image, yet the direct-kernel heartbeat test could not see it.
# That regression reached main because there was no installer-boot gate.
# This script is that gate.
#
# HOW THE ORCHESTRATOR INVOKES IT AS A PUSH GATE
# ----------------------------------------------
#   # Build once, then gate against the fresh image before pushing:
#   bash scripts/build_installer_img.sh                # ~14 min, Stage 1
#   bash scripts/test_installer_boot_heartbeat.sh && git push   # gate
#
#   # Or point it at an already-built image and skip the 14-min rebuild:
#   SKIP_BUILD=1 IMG=build/hamnix-installer.img \
#       bash scripts/test_installer_boot_heartbeat.sh && git push
#
# Exit code is 0 on PASS, non-zero on FAIL, so `&& git push` is the gate.
#
# Env overrides
# -------------
#   IMG          installer image path     (default: build/hamnix-installer.img)
#   SKIP_BUILD=1 do NOT (re)build the image even if missing/stale; fail
#                instead if IMG is absent. Lets the orchestrator gate a
#                pre-built image without paying the ~14-min Stage-1 cost.
#   BOOT_TIMEOUT deadline seconds for the heartbeat to appear (default 180).
#                The boot is slow under TCG; the script polls and exits as
#                soon as the marker is seen, so this is only an upper bound.
#   OVMF_FD      OVMF firmware path       (default: /usr/share/ovmf/OVMF.fd)
#   SERIAL_LOG   pre-captured serial log to evaluate INSTEAD of booting
#                (logic-only mode for CI/dev: feed a known-good or
#                known-broken log and assert the PASS/FAIL verdict without
#                spinning QEMU). When set, no QEMU is launched.
#   KEEP_LOG=1   keep the temp serial log on exit (debugging).
#
# Pass marker:  [test_installer_boot_heartbeat] PASS
# Fail marker:  [test_installer_boot_heartbeat] FAIL

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

IMG="${IMG:-build/hamnix-installer.img}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
OVMF_FD="${OVMF_FD:-/usr/share/ovmf/OVMF.fd}"

# The liveness marker we require, and the fatal-trap markers we reject.
HEARTBEAT_RE='\[hamsh-alive\]'
# A fatal first-IRQ-from-userspace triple-fault (regression #402) surfaces
# as a "TRAP: vector 0xNN" print from the trap handler and/or the firmware
# resetting the CPU. Any of these means the boot died, even if a stale
# heartbeat fragment somehow appeared.
FATAL_RE='TRAP: vector|triple fault|double fault|cpu_reset|#DF'

say() { echo "[test_installer_boot_heartbeat] $*"; }

# --- evaluate(): the PASS/FAIL verdict over a serial log --------------
# Shared by both the live-boot path and the SERIAL_LOG logic-only path so
# the gate logic is asserted identically either way. Returns 0=PASS,1=FAIL.
evaluate() {
    local log="$1"
    local hb fatal
    hb=$(grep -aE -c "$HEARTBEAT_RE" "$log" || true)
    say "observed $hb heartbeat line(s) matching '$HEARTBEAT_RE'"

    if grep -aE -q "$FATAL_RE" "$log"; then
        fatal=1
    else
        fatal=0
    fi

    if [ "$fatal" -ne 0 ]; then
        say "FAIL: fatal-trap indication present (matched '$FATAL_RE') --"
        say "      this is the regression #402 signature (first timer IRQ"
        say "      from userspace -> #UD->#GP->#DF->cpu_reset). Offending lines:"
        grep -aEn "$FATAL_RE" "$log" | head -8 | sed 's/^/    /' >&2
        return 1
    fi

    if [ "$hb" -lt 1 ]; then
        say "FAIL: no '[hamsh-alive]' heartbeat reached the serial console"
        say "      within the boot window. The shell never got scheduled"
        say "      after SYSRET into ring-3 (boot wedged or starved)."
        say "--- last 40 serial lines ---"
        tail -40 "$log" | strings | sed 's/^/    /' >&2
        return 1
    fi

    say "heartbeat present and no fatal trap detected."
    return 0
}

# --- logic-only mode: evaluate a pre-captured serial log, no QEMU -----
if [ -n "${SERIAL_LOG:-}" ]; then
    if [ ! -f "$SERIAL_LOG" ]; then
        say "FAIL: SERIAL_LOG=$SERIAL_LOG does not exist"
        say "FAIL"
        exit 1
    fi
    say "logic-only mode: evaluating pre-captured log $SERIAL_LOG (no QEMU boot)"
    if evaluate "$SERIAL_LOG"; then
        say "PASS"
        exit 0
    else
        say "FAIL"
        exit 1
    fi
fi

# --- ensure the installer image exists (build it unless SKIP_BUILD) ---
if [ ! -f "$IMG" ]; then
    if [ "${SKIP_BUILD:-0}" = "1" ]; then
        say "FAIL: $IMG missing and SKIP_BUILD=1 (refusing the ~14-min rebuild)."
        say "FAIL"
        exit 1
    fi
    say "image $IMG absent -- building via scripts/build_installer_img.sh (~14 min)"
    HAMNIX_INSTALLER_IMG_OUT="$IMG" bash scripts/build_installer_img.sh
fi
if [ ! -f "$IMG" ]; then
    say "FAIL: $IMG still missing after build_installer_img.sh."
    say "FAIL"
    exit 1
fi

# --- OVMF firmware (writable copy: UEFI persists vars into the image) --
if [ ! -f "$OVMF_FD" ]; then
    if [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ ! -f "$OVMF_FD" ]; then
    say "FAIL: OVMF firmware not found (tried $OVMF_FD; apt install ovmf)."
    say "FAIL"
    exit 1
fi

LOG=$(mktemp --tmpdir hamnix-installer-heartbeat.XXXXXX.log)
OVMF_RW=$(mktemp --tmpdir hamnix-installer-heartbeat.ovmf.XXXXXX.fd)
QEMU_PID=""
cleanup() {
    # Kill QEMU on every exit path (success, failure, signal).
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [ "${KEEP_LOG:-0}" = "1" ]; then
        echo "[test_installer_boot_heartbeat] KEEP_LOG: serial log at $LOG" >&2
    else
        rm -f "$LOG"
    fi
    rm -f "$OVMF_RW"
}
trap cleanup EXIT INT TERM
cp "$OVMF_FD" "$OVMF_RW"

say "=== installer boot heartbeat gate ==="
say "  image      = $IMG"
say "  firmware   = $OVMF_FD"
say "  heartbeat  = '$HEARTBEAT_RE'   (must appear)"
say "  fatal      = '$FATAL_RE'   (must NOT appear)"
say "  deadline   = ${BOOT_TIMEOUT}s (polled; exits early on first marker)"

# Boot single-CPU under OVMF+TCG, serial -> $LOG. Background it so we can
# poll the log and tear down the instant the heartbeat (or a fatal trap)
# shows up rather than blocking for the full timeout.
qemu-system-x86_64 \
    -bios "$OVMF_RW" \
    -drive "file=$IMG,format=raw,if=virtio" \
    -m 1G \
    -vga std \
    -display none \
    -serial "file:$LOG" \
    -no-reboot \
    -monitor none \
    >/dev/null 2>&1 &
QEMU_PID=$!

# Poll the serial log until we see the heartbeat, a fatal trap, the boot
# deadline, or QEMU dying on its own.
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
saw_heartbeat=0
saw_fatal=0
while :; do
    if [ -f "$LOG" ]; then
        if grep -aE -q "$HEARTBEAT_RE" "$LOG"; then
            saw_heartbeat=1
            break
        fi
        if grep -aE -q "$FATAL_RE" "$LOG"; then
            saw_fatal=1
            break
        fi
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        # QEMU exited before either marker (e.g. -no-reboot halt after a
        # triple fault). Fall through to evaluate() on whatever it logged.
        QEMU_PID=""
        break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        say "deadline reached (${BOOT_TIMEOUT}s) without a heartbeat."
        break
    fi
    sleep 2
done

# Tear QEMU down before final evaluation (cleanup trap also covers this).
if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    QEMU_PID=""
fi

say "boot observation done (saw_heartbeat=$saw_heartbeat saw_fatal=$saw_fatal)"

if evaluate "$LOG"; then
    say "PASS"
    exit 0
else
    say "FAIL"
    exit 1
fi
