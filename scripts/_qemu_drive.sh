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
# USAGE
#
#   . "$(dirname "$0")/_qemu_drive.sh"
#   qemu_drive <logfile> <kernel-elf> <ready-marker> <overall-timeout> \
#              -- <cmd1> <after1> <cmd2> <after2> ...
#
#   logfile         where QEMU's serial output is written (caller owns it)
#   kernel-elf      the -kernel image
#   ready-marker    a literal substring the driver waits for on the log
#                   before sending cmd1 (use hamsh's banner:
#                   "[hamsh] M16.35 shell ready")
#   overall-timeout seconds; the whole QEMU run is bounded by `timeout`
#   cmd / after     a command line to feed to hamsh's stdin, then the
#                   number of seconds to wait before the NEXT command.
#                   The newline is appended automatically.
#
# Extra QEMU args may be supplied via the QEMU_EXTRA_ARGS env var
# (space-separated). Default machine: -smp 2 -m 256M, -nographic,
# -no-reboot, serial to the logfile.
#
# Returns QEMU's exit code in the global QEMU_DRIVE_RC.

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
        while [ "$waited" -lt "$overall_timeout" ]; do
            if [ -f "$logfile" ] && grep -F -q "$ready_marker" "$logfile"; then
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
        # A short settle so hamsh has finished printing the prompt and
        # has a live SYS_READ on stdin before the first byte lands.
        sleep 1
        local i
        for i in "${!cmds[@]}"; do
            printf '%s\n' "${cmds[$i]}" >&9
            sleep "${delays[$i]}"
        done
        exec 9>&-
    ) &
    local feeder_pid=$!

    # --- QEMU ---------------------------------------------------------
    local qrc=0
    # shellcheck disable=SC2086
    timeout "${overall_timeout}s" qemu-system-x86_64 \
        -kernel "$kernel" \
        -smp 2 \
        -nographic \
        -no-reboot \
        -m 256M \
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
