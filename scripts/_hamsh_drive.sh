# scripts/_hamsh_drive.sh — robust, load-adaptive hamsh serial driver.
#
# WHY THIS EXISTS
#
# The dev-family gates (test_devnull/devtime/devpid/devrandom/devcons/…)
# drove hamsh like this:
#
#     ( sleep 3; printf 'cmd\n'; ... ) | timeout 15s qemu ...
#
# The fixed `sleep 3` assumed hamsh's prompt was ready 3 s after QEMU
# started. Under host load (the documented D-state-ACPI-kworker /
# high-iowait condition, or a busy CI runner) the boot takes far longer,
# so the input was shoved at the 16550 RX FIFO BEFORE hamsh was reading
# and the first command was simply dropped — the gate then MISSed its own
# marker and reported a FALSE RED. scripts/_qemu_drive.sh already fixed
# the "shove before prompt" half by waiting for a readiness marker, but it
# still paces the commands with FIXED post-command delays. Under a starved
# guest a single line-editor echo (one character at a time) can take tens
# of seconds, so those fixed delays overrun and the trailing sentinel is
# never observed within the timeout — again a false red (observed
# 2026-07-09: test_devproc reached its own PASS marker but the POST_ sentinel
# missed the 90 s wall, so the gate FAILed on pure host starvation).
#
# This driver takes the OUTPUT-ADAPTIVE approach proven in
# scripts/test_pipe.sh: after the readiness marker and a FEEDER_SYNC
# handshake (proving a live readline is consuming stdin), every command is
# sent ONCE and waited on its OWN observable effect — so it costs exactly
# as long as the guest needs and no longer. A run that never gets far
# enough to observe its assertion is reported INCONCLUSIVE
# (scripts/_verdict.sh), never a false green or a false red.
#
# HIGHER-HALF KERNEL NOTE: the kernel is a true elf64 higher-half image and
# QEMU's built-in `-kernel` multiboot1 loader REJECTS 64-bit ELFs. Sourcing
# _kernel_iso.sh installs a build/binshim/qemu-system-x86_64 wrapper on PATH
# that transparently turns `-kernel <elf64>` into a GRUB-ISO `-cdrom` boot.
#
# USAGE
#
#     . "$(dirname "$0")/_hamsh_drive.sh"
#     hamsh_boot   "$LOG" "$ELF"            # backgrounds QEMU, opens stdin
#     trap hamsh_shutdown EXIT              # kills ONLY our qemu, frees fifo
#     hamsh_wait_boot "[hamsh] M16.35 shell ready" 420 || verdict_inconclusive ...
#     hamsh_sync 120                         || verdict_inconclusive ...
#     hamsh_send_await '/bin/test_x' '[test_x] PASS' 240   # adaptive wait
#     hamsh_send 'exit'                      # fire-and-forget
#
# Then grep "$LOG" for assertions and finish with verdict_boot_gate +
# verdict_pass/verdict_fail.
#
# Tunables (env): HAMNIX_TEST_SMP (default 2), HAMNIX_VM_MEM (default 2G).

# Pull in the higher-half kernel boot shim (installs the binshim wrapper).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_kernel_iso.sh"

# hamsh_boot <logfile> <kernel-elf> — background QEMU, wire stdin FIFO.
# Sets HD_LOG, HD_QEMU_PID, HD_FIFO and opens fd 3 as the guest's stdin.
hamsh_boot() {
    HD_LOG="$1"; local kernel="$2"
    HD_FIFO="$(mktemp -u --tmpdir hamnix-hd-in.XXXXXX)"
    mkfifo "$HD_FIFO"
    local smp="${HAMNIX_TEST_SMP:-2}" mem="${HAMNIX_VM_MEM:-2G}"
    # The binshim on PATH rewrites `-kernel <elf64>` into a GRUB `-cdrom`
    # boot. No `timeout` wrapper: each wait below is individually bounded
    # and hamsh_shutdown reaps the process, so QEMU cannot outlive us.
    # QEMU_EXTRA_ARGS (space-separated, unquoted so it word-splits — same
    # convention as scripts/_qemu_drive.sh) lets a gate add machine flags
    # like `-cpu max`; it defaults to empty so existing callers are unaffected.
    # shellcheck disable=SC2086
    qemu-system-x86_64 \
        -kernel "$kernel" \
        -smp "$smp" -m "$mem" \
        -nographic -no-reboot -monitor none \
        ${QEMU_EXTRA_ARGS:-} \
        < "$HD_FIFO" > "$HD_LOG" 2>&1 &
    HD_QEMU_PID=$!
    # Hold the FIFO open for writing for the whole run so the guest's
    # reader never sees EOF between commands.
    exec 3> "$HD_FIFO"
}

# hamsh_shutdown — kill ONLY our own QEMU (never pkill), free the FIFO.
# Idempotent; safe to call from an EXIT trap.
hamsh_shutdown() {
    exec 3>&- 2>/dev/null || true
    if [ -n "${HD_QEMU_PID:-}" ]; then
        kill "$HD_QEMU_PID" 2>/dev/null || true
        wait "$HD_QEMU_PID" 2>/dev/null || true
        HD_QEMU_PID=""
    fi
    [ -n "${HD_FIFO:-}" ] && rm -f "$HD_FIFO"
}

# hamsh_alive — is our QEMU still running?
hamsh_alive() { [ -n "${HD_QEMU_PID:-}" ] && kill -0 "$HD_QEMU_PID" 2>/dev/null; }

# hamsh_wait_boot <ready-marker> <secs> — wait (bounded) for the marker on
# the serial log. Returns 0 if seen, 1 on timeout or an early QEMU exit.
hamsh_wait_boot() {
    local marker="$1" secs="$2" i
    for i in $(seq 1 "$secs"); do
        grep -a -F -q "$marker" "$HD_LOG" 2>/dev/null && return 0
        hamsh_alive || return 1
        sleep 1
    done
    return 1
}

# hamsh_sync <secs> — prove a live readline is consuming stdin. A freshly
# booted hamsh drops the FIRST serial line it is sent and its readline only
# starts consuming stdin after rc.boot hands off, so re-send an idempotent
# probe until it echoes back. Returns 0 once FEEDER_SYNC echoes, else 1.
hamsh_sync() {
    local secs="$1" waited=0 i
    while [ "$waited" -lt "$secs" ]; do
        hamsh_alive || return 1
        printf 'echo FEEDER_SYNC\n' >&3 2>/dev/null || return 1
        for i in $(seq 1 5); do
            grep -a -F -q "FEEDER_SYNC" "$HD_LOG" 2>/dev/null && { sleep 1; return 0; }
            hamsh_alive || return 1
            sleep 1; waited=$((waited + 1))
            [ "$waited" -ge "$secs" ] && break
        done
    done
    return 1
}

# hamsh_send_await <cmd> <literal-in-log> <secs> — send <cmd> ONCE, then
# wait (bounded) for <literal> to appear anywhere in the log. After the
# sync handshake the readline is provably consuming stdin, so we send
# exactly once — a resend would splice a second copy into the line still
# being echoed one character at a time under load. Returns 0 if the effect
# was observed, 1 otherwise.
hamsh_send_await() {
    local cmd="$1" pat="$2" secs="$3" i
    hamsh_alive || return 1
    printf '%s\n' "$cmd" >&3 2>/dev/null || return 1
    for i in $(seq 1 "$secs"); do
        grep -a -F -q "$pat" "$HD_LOG" 2>/dev/null && { sleep 1; return 0; }
        hamsh_alive || return 1
        sleep 1
    done
    return 1
}

# hamsh_send <cmd> — fire-and-forget (e.g. `exit`). Never fails the caller.
hamsh_send() {
    hamsh_alive || return 0
    printf '%s\n' "$1" >&3 2>/dev/null || true
}
