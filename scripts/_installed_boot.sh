# scripts/_installed_boot.sh — SOURCEABLE helper: boot the INSTALLED Hamnix
# system (ext4-on-NVMe) the way the retired build/hamnix.img used to be
# booted, so feature tests keep their coverage after the baked image was
# retired.
#
# It boots a fresh COPY of the golden installed disk
# (build/hamnix-installed.qcow2, produced by scripts/build_installed_nvme.sh
# via the REAL installer path) under OVMF/KVM, reaching an interactive shell
# on the ext4-on-NVMe root. A sourcing test then drives commands over the
# serial console and asserts on the captured log — exactly the old
# build/hamnix.img model, just booting the installed disk instead.
#
# CONTRACT — a test sources this file, then calls:
#     source "$PROJ_ROOT/scripts/_installed_boot.sh"   # gates + builds golden + defines fns
#     installed_boot_start            # boots a fresh copy; sets QEMU_PID, INSTALLED_LOG
#     installed_boot_wait [secs]      # blocks until the shell prompt (default 200s); returns 1 on failure
#     installed_type "cmd" [settle]   # feed one line to the guest (default settle 4s)
#     installed_boot_stop             # kill qemu, close fds
#     # ... then grep "$INSTALLED_LOG" for your assertions ...
#
# This file SKIPS THE WHOLE TEST CLEANLY (echo + `exit 0` in the sourcing
# shell) when /dev/kvm, OVMF, mksquashfs, or the golden disk is unavailable —
# `exit` in a sourced script exits the caller, matching how every OVMF-boot
# test gates itself.
#
# Env overrides:
#   GOLDEN_NVME        golden disk path  (default: build/hamnix-installed.qcow2)
#   OVMF_FD            OVMF firmware     (auto-resolved)
#   INSTALLED_BOOT_MEM guest RAM         (default: 1024M)
#   SHELL_BOOT_WAIT    default prompt wait seconds (default: 200)
#   HAMNIX_SKIP_BUILD  1 = do not (re)build the golden disk; require it present

# Resolve the project root from THIS file's location (works regardless of the
# sourcing test's own PROJ_ROOT).
_IB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GOLDEN_NVME="${GOLDEN_NVME:-build/hamnix-installed.qcow2}"
INSTALLED_BOOT_MEM="${INSTALLED_BOOT_MEM:-1024M}"
SHELL_BOOT_WAIT="${SHELL_BOOT_WAIT:-200}"
INSTALLED_KERNEL_BANNER="Hamnix kernel booting"
INSTALLED_PROMPT_MARKER="handing off to interactive shell"

_ib_skip() { echo "[installed_boot] SKIP: $1" >&2; exit 0; }

# --- environment gates ------------------------------------------------
[ -e /dev/kvm ] || _ib_skip "/dev/kvm absent (KVM required; OVMF boot too slow without it)"
if [ -z "${OVMF_FD:-}" ]; then
    if [ -f /usr/share/ovmf/OVMF.fd ]; then
        OVMF_FD=/usr/share/ovmf/OVMF.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
{ [ -n "${OVMF_FD:-}" ] && [ -f "$OVMF_FD" ]; } || _ib_skip "OVMF firmware not found (apt install ovmf)"
command -v mksquashfs >/dev/null 2>&1 || _ib_skip "mksquashfs not found (apt install squashfs-tools)"

# --- ensure the golden installed disk exists --------------------------
if [ ! -f "$_IB_ROOT/$GOLDEN_NVME" ] && [ ! -f "$GOLDEN_NVME" ]; then
    if [ "${HAMNIX_SKIP_BUILD:-0}" = "1" ]; then
        _ib_skip "golden disk $GOLDEN_NVME absent and HAMNIX_SKIP_BUILD=1"
    fi
    echo "[installed_boot] golden disk absent; building it via build_installed_nvme.sh (installs once)"
    bash "$_IB_ROOT/scripts/build_installed_nvme.sh"
fi
# Resolve the golden disk to an absolute path.
if [ -f "$_IB_ROOT/$GOLDEN_NVME" ]; then
    GOLDEN_NVME="$_IB_ROOT/$GOLDEN_NVME"
fi
[ -f "$GOLDEN_NVME" ] || _ib_skip "golden installed disk could not be built (see build_installed_nvme.sh output)"

# --- per-boot scratch state -------------------------------------------
INSTALLED_LOG=""
_IB_OVMF_RW=""
_IB_DISK_RW=""
_IB_INFIFO=""
QEMU_PID=""

_ib_cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$_IB_OVMF_RW" "$_IB_DISK_RW" "$_IB_INFIFO"
}
trap _ib_cleanup EXIT

# installed_boot_start — boot a FRESH copy of the golden disk; opens fd 3 as
# the guest's serial stdin and captures the console to $INSTALLED_LOG.
installed_boot_start() {
    _IB_OVMF_RW=$(mktemp --tmpdir hamnix-ib.ovmf.XXXXXX.fd)
    _IB_DISK_RW=$(mktemp --tmpdir hamnix-ib.disk.XXXXXX.qcow2)
    INSTALLED_LOG=$(mktemp --tmpdir hamnix-ib.boot.XXXXXX.log)
    _IB_INFIFO=$(mktemp --tmpdir -u hamnix-ib-in.XXXXXX)
    cp "$OVMF_FD" "$_IB_OVMF_RW"
    # Fresh writable copy so state-mutating tests never poison the golden disk.
    cp "$GOLDEN_NVME" "$_IB_DISK_RW"
    mkfifo "$_IB_INFIFO"

    exec 4<>"$_IB_INFIFO"
    exec 3>"$_IB_INFIFO"

    qemu-system-x86_64 \
        -enable-kvm -cpu host \
        -bios "$_IB_OVMF_RW" \
        -drive file="$_IB_DISK_RW",format=qcow2,if=none,id=nvmeroot \
        -device nvme,drive=nvmeroot,serial=hamnvme01,bootindex=0 \
        -m "$INSTALLED_BOOT_MEM" \
        -nographic -no-reboot -monitor none \
        -serial stdio \
        <&4 > "$INSTALLED_LOG" 2>&1 &
    QEMU_PID=$!
}

# installed_boot_wait [secs] — block until the interactive-prompt marker.
# Returns 0 on success, 1 if qemu died or the marker never appeared.
installed_boot_wait() {
    local secs="${1:-$SHELL_BOOT_WAIT}"
    local i
    for i in $(seq 1 "$secs"); do
        if grep -a -q "$INSTALLED_PROMPT_MARKER" "$INSTALLED_LOG"; then
            return 0
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            echo "[installed_boot] qemu exited before reaching the prompt." >&2
            tail -80 "$INSTALLED_LOG" >&2
            return 1
        fi
        sleep 1
    done
    echo "[installed_boot] prompt marker not seen in ${secs}s." >&2
    tail -80 "$INSTALLED_LOG" >&2
    return 1
}

# installed_type "cmd" [settle] — feed one line to the guest serial console.
installed_type() {
    printf '%s\n' "$1" >&3
    sleep "${2:-4}"
}

# installed_boot_stop — stop the guest and close the serial fds.
installed_boot_stop() {
    kill "$QEMU_PID" 2>/dev/null
    wait "$QEMU_PID" 2>/dev/null
    exec 3>&- 2>/dev/null || true
    exec 4>&- 2>/dev/null || true
}
