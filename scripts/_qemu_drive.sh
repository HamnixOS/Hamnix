# scripts/_qemu_drive.sh — prompt-aware QEMU driver for hamsh tests.
#
# WHY THIS EXISTS
#
# The U-track test scripts used to drive hamsh like this:
#
#     ( sleep 3; printf 'cmd\n'; sleep 5; printf 'exit\n' ) | qemu ...
#
# The fixed `sleep 3` assumed hamsh's prompt was ready 3 s after QEMU
# started. As the kernel grew (ext4, USB, the per-process-address-space
# fork, more boot self-tests) boot got slower and less deterministic —
# the input was frequently shoved at the 16550 RX FIFO *before* hamsh
# had even printed its banner, so the first command was simply lost and
# the test MISSed its own pre-fork marker. A fixed sleep cannot be both
# fast and reliable.
#
# qemu_drive() replaces the fixed-sleep subshell with a driver that
# WAITS for a readiness marker to appear on the serial log before it
# sends each command, with a hard timeout backstop. Boot can take 2 s
# or 20 s — the driver adapts.
#
# HIGHER-HALF KERNEL NOTE: the Hamnix kernel is now a true elf64
# higher-half image, and QEMU's built-in `-kernel` multiboot1 loader
# REJECTS 64-bit ELFs. qemu_drive therefore wraps the kernel ELF in a
# minimal BIOS GRUB ISO (via scripts/_kernel_iso.sh) and boots it with
# `-cdrom` — GRUB's multiboot1 loader handles ELFCLASS64 fine. This is
# transparent to callers: they still pass a kernel ELF path.
#
# USAGE
#
#   . "$(dirname "$0")/_qemu_drive.sh"
#   qemu_drive <logfile> <kernel-elf> <ready-marker> <overall-timeout> \
#              -- <cmd1> <after1> <cmd2> <after2> ...
#
#   logfile         where QEMU's serial output is written (caller owns it)
#   kernel-elf      the kernel image (wrapped in a GRUB ISO internally)
#   ready-marker    a literal substring the driver waits for on the log
#                   before sending cmd1 (use hamsh's banner:
#                   "[hamsh] M16.35 shell ready")
#   overall-timeout seconds; the whole QEMU run is bounded by `timeout`
#   cmd / after     a command line to feed to hamsh's stdin, then the
#                   number of seconds to wait before the NEXT command.
#                   The newline is appended automatically.
#
# Extra QEMU args may be supplied via the QEMU_EXTRA_ARGS env var
# (space-separated). Default machine: -smp 2 -m 1G, -nographic,
# -no-reboot, serial to the logfile. (1G, not 256M: the debug kernel
# ELF embeds a ~200MB initramfs and the BIOS GRUB ISO loader runs out
# of memory loading it under a 256MB guest before reaching the kernel.)
#
# After the ready marker the driver performs a FEEDER_SYNC echo
# handshake: it re-sends `echo FEEDER_SYNC` once a second until that
# text echoes back on the serial log, proving a live readline is
# actually consuming stdin (the banner alone is not proof — on a
# default-/init boot it prints BEFORE rc.boot runs, and the first
# serial line is dropped by a fresh readline). Set QEMU_DRIVE_NO_SYNC=1
# to skip the handshake for non-shell stdin consumers.
#
# Returns QEMU's exit code in the global QEMU_DRIVE_RC.

# Pull in the higher-half kernel boot shim. _kernel_iso.sh installs a
# build/binshim/qemu-system-x86_64 wrapper and prepends it to PATH, so
# the `qemu-system-x86_64` call below transparently boots the elf64
# kernel from a BIOS GRUB ISO (QEMU's `-kernel` rejects 64-bit ELFs).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_iso.sh"

qemu_drive() {
    local logfile="$1"; shift
    local kernel="$1"; shift
    local ready_marker="$1"; shift
    local overall_timeout="$1"; shift
    # Expect a literal `--` separator before the command list.
    if [ "${1:-}" = "--" ]; then shift; fi

    # Commands + post-delays arrive as alternating args.
    local -a cmds=() delays=()
    while [ "$#" -gt 0 ]; do
        cmds+=("$1"); shift
        delays+=("${1:-1}"); shift || true
    done

    # FIFO carries hamsh's stdin. QEMU reads from it; the feeder writes
    # to it once the readiness marker shows up in the log.
    local fifo
    fifo="$(mktemp -u)"
    mkfifo "$fifo"

    # --- feeder: wait for the ready marker, then send commands -------
    (
        # Hold the FIFO open for writing for the whole feeder lifetime
        # so QEMU's reader doesn't see EOF between commands.
        exec 9>"$fifo"
        # Wait (bounded) for the readiness marker on the serial log.
        local waited=0
        local marker_seen=0
        # -a: QEMU's serial log carries NUL/escape bytes (varies run to
        # run with boot timing); without it grep may classify the log
        # as binary and silently never match the marker, so the feeder
        # sends NOTHING and the test starves with a live prompt.
        while [ "$waited" -lt "$overall_timeout" ]; do
            if [ -f "$logfile" ] && grep -a -F -q "$ready_marker" "$logfile"; then
                marker_seen=1
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done
        if [ "$marker_seen" -eq 0 ]; then
            # Marker never appeared — boot is wedged or far too slow.
            # Send nothing; the test's own grep checks will FAIL and
            # the captured log shows why.
            echo "[qemu_drive] readiness marker '$ready_marker' not seen" \
                 "within ${overall_timeout}s — boot stalled?" >&2
            exec 9>&-
            return 0
        fi
        # SYNC HANDSHAKE — the ready marker is NOT proof the shell is
        # consuming stdin:
        #   * On a default-/init boot the serial hamsh prints its
        #     "shell ready" banner BEFORE sourcing /etc/rc.boot; its
        #     interactive readline only starts consuming stdin after
        #     rc.boot hands off (tens of seconds later). Bytes typed in
        #     that window are silently dropped — task #439's root cause.
        #   * rc.boot also spawns VT gettys whose hamsh instances print
        #     the same banner, so "first banner on the log" may not even
        #     be the serial shell.
        #   * A freshly-booted readline drops the FIRST serial line it
        #     is sent (never echoes it).
        # So: re-send an idempotent probe until its text echoes back on
        # the serial log, which proves a live readline is consuming our
        # bytes. Only then feed the real commands. The probe is
        # idempotent (`echo`), so a duplicate landing twice is harmless.
        # Opt out with QEMU_DRIVE_NO_SYNC=1 (for non-shell consumers).
        if [ "${QEMU_DRIVE_NO_SYNC:-0}" != "1" ]; then
            local probes=0
            while [ "$probes" -lt "$overall_timeout" ]; do
                printf 'echo FEEDER_SYNC\n' >&9
                sleep 1
                # -a: the serial log carries escape/NUL bytes; without
                # it grep may classify the log as binary and not match.
                if grep -a -F -q "FEEDER_SYNC" "$logfile" 2>/dev/null; then
                    break
                fi
                probes=$((probes + 1))
            done
            if [ "$probes" -ge "$overall_timeout" ]; then
                echo "[qemu_drive] FEEDER_SYNC never echoed within" \
                     "${overall_timeout}s — readline not consuming stdin?" >&2
            fi
        else
            # A short settle so the consumer has a live SYS_READ on
            # stdin before the first byte lands.
            sleep 1
        fi
        local i
        for i in "${!cmds[@]}"; do
            printf '%s\n' "${cmds[$i]}" >&9
            sleep "${delays[$i]}"
        done
        exec 9>&-
    ) &
    local feeder_pid=$!

    # --- QEMU ---------------------------------------------------------
    # The build/binshim qemu-system-x86_64 wrapper (installed by
    # _kernel_iso.sh, prepended to PATH) transparently turns this
    # `-kernel <elf64>` into a `-cdrom <iso>` GRUB boot.
    local qrc=0
    # shellcheck disable=SC2086
    timeout "${overall_timeout}s" qemu-system-x86_64 \
        -kernel "$kernel" \
        -smp 2 \
        -nographic \
        -no-reboot \
        -m "${HAMNIX_VM_MEM:-2G}" \
        -monitor none \
        -serial stdio \
        ${QEMU_EXTRA_ARGS:-} \
        < "$fifo" \
        > "$logfile" 2>&1 || qrc=$?

    wait "$feeder_pid" 2>/dev/null || true
    rm -f "$fifo"
    QEMU_DRIVE_RC="$qrc"
    return 0
}
