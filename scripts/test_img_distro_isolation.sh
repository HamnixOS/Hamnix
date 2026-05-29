#!/usr/bin/env bash
# scripts/test_img_distro_isolation.sh — ACCEPTANCE GATE for the
# native(sysroot) <-> Debian(distro) ROOT ISOLATION guarantee.
#
# Boots build/hamnix.img under OVMF (UEFI) as a DISK (virtio-blk), the
# same way scripts/test_img_uefi_boot.sh does, then proves the
# load-bearing isolation invariant:
#
#   The native root (`bind '#sysroot' /`, PID 1's ambient namespace)
#   and the Debian root (`enter debian { ... }`, a HERMETIC namespace
#   with `bind '#distro' /`) are GENUINELY separate. Entering the
#   Debian subsystem gives it `#distro` as its `/`; it cannot see — let
#   alone write — the native sysroot. A bareword command at the boot
#   prompt cannot reach the distro tree at all (the boot rc no longer
#   binds it ambiently — etc/rc.boot.full isolation invariant).
#
# WHAT IT DRIVES AT THE SHELL (in order):
#   1. native `ls /`                      — sysroot root listing
#   2. native `ls /n/distros`             — MUST FAIL / be empty: the
#                                            distro tree is NOT in the
#                                            ambient namespace anymore
#   3. `enter debian { /bin/ls / }`       — the distro (busybox+Debian)
#                                            root listing — DIFFERENT
#                                            from the native root
#   4. `enter debian { /bin/sh -c ... }`  — write a marker file inside
#                                            the Debian subsystem
#   5. native `ls /`                      — RE-listed: the distro-side
#                                            marker MUST NOT appear, and
#                                            the native `/init` MUST
#                                            still be present (sysroot
#                                            unmodified by the distro
#                                            write)
#
# ASSERTIONS:
#   A. The Debian root listing contains Debian-only top-level dirs
#      (var, lib64) that the NATIVE root listing does NOT — proving the
#      two `/`s are different file servers.
#   B. The native root carries `/init` (the boot shim) which the distro
#      root does NOT — the reverse distinguishing marker.
#   C. The native ambient `ls /n/distros` does NOT expose the distro
#      tree (no busybox/Debian content) — the ambient leak is gone.
#   D. After the distro-side write, the native root listing is UNCHANGED
#      (the write marker does NOT appear at the native root, and /init
#      is still there) — the distro write could not touch sysroot.
#
# SKIPS CLEANLY (exit 0) when /dev/kvm or OVMF firmware is unavailable,
# or when the busybox fixture needed for the Debian subsystem shell is
# not present on the host (mirrors the U-track convention).
#
# Env overrides:
#   HAMNIX_IMG         image path                (default: build/hamnix.img)
#   OVMF_FD            OVMF firmware path        (default: auto-resolved)
#   SHELL_BOOT_WAIT    seconds to wait for the   (default: 90)
#                      interactive-prompt marker
#   HAMNIX_SKIP_BUILD  1 = reuse existing image  (default: rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_IMG="${HAMNIX_IMG:-build/hamnix.img}"
SHELL_BOOT_WAIT="${SHELL_BOOT_WAIT:-90}"
KERNEL_BANNER="Hamnix kernel booting"
PROMPT_MARKER="handing off to interactive shell"

# Distinguishing markers driven into the serial stream so the assertions
# can fence each listing precisely (a bare `ls` listing is otherwise
# hard to attribute to a specific command in the interleaved log).
M_NATIVE1="HAMNIX_ISO_NATIVE_ROOT_1"
M_AMBIENT="HAMNIX_ISO_AMBIENT_DISTRO"
M_DEBIAN="HAMNIX_ISO_DEBIAN_ROOT"
M_WRITE="HAMNIX_ISO_DISTRO_WROTE"
M_NATIVE2="HAMNIX_ISO_NATIVE_ROOT_2"
# The file the Debian-side write creates. If this name ever shows up in
# a NATIVE root listing the isolation is broken.
WRITE_FILE="HAMNIX_DISTRO_ONLY_MARKER"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_img_distro_iso] SKIP: /dev/kvm absent (KVM required; boot too slow without it)" >&2
    exit 0
fi

# The Debian subsystem shell is busybox, staged into distro/ from
# tests/u-binary/u_busybox_musl. Without it `enter debian { /bin/ls }`
# has no shell to run; SKIP rather than FAIL (host-built, gitignored).
if [ ! -f "$PROJ_ROOT/tests/u-binary/u_busybox_musl" ]; then
    echo "[test_img_distro_iso] SKIP: tests/u-binary/u_busybox_musl absent" >&2
    echo "[test_img_distro_iso]   (build it: make -C tests/u-binary/src/musl_busybox install)" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    if [ -f /usr/share/ovmf/OVMF.fd ]; then
        OVMF_FD=/usr/share/ovmf/OVMF.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[test_img_distro_iso] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- build the image --------------------------------------------------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_img_distro_iso] building disk image via build_img.sh"
    rm -f "$HAMNIX_IMG"
    bash "$PROJ_ROOT/scripts/build_img.sh"
fi
if [ ! -f "$HAMNIX_IMG" ]; then
    echo "[test_img_distro_iso] FAIL: $HAMNIX_IMG missing after build_img.sh." >&2
    exit 1
fi

OVMF_RW=$(mktemp --tmpdir hamnix-iso.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-iso.disk.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-iso.XXXXXX.log)
INFIFO=$(mktemp --tmpdir -u hamnix-iso-in.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$HAMNIX_IMG" "$IMG_RW"
mkfifo "$INFIFO"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$INFIFO"
}
trap cleanup EXIT

exec 4<>"$INFIFO"
exec 3>"$INFIFO"

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m 512M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

echo "[test_img_distro_iso] waiting up to ${SHELL_BOOT_WAIT}s for prompt marker..."
booted=0
for _ in $(seq 1 "$SHELL_BOOT_WAIT"); do
    if grep -a -q "$PROMPT_MARKER" "$LOG"; then
        booted=1
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "[test_img_distro_iso] FAIL: qemu exited before reaching the prompt." >&2
        echo "----- serial log tail -----" >&2
        tail -80 "$LOG" >&2
        exit 1
    fi
    sleep 1
done

if [ "$booted" -ne 1 ]; then
    echo "[test_img_distro_iso] FAIL: prompt marker '$PROMPT_MARKER' not seen in ${SHELL_BOOT_WAIT}s." >&2
    echo "----- serial log tail -----" >&2
    tail -80 "$LOG" >&2
    exit 1
fi
echo "[test_img_distro_iso] prompt reached; driving isolation probes."

type_cmd() {
    printf '%s\n' "$1" >&3
    sleep "${2:-4}"
}

# 1. Native root listing (fenced by a marker echo before + after).
type_cmd "echo $M_NATIVE1" 2
type_cmd "ls /" 4

# 2. The ambient namespace must NOT expose the distro tree anymore.
#    `ls /n/distros` should error / list nothing meaningful (the boot rc
#    no longer binds '#distro' there). The fence marker proves the REPL
#    survived the (expected) failure.
type_cmd "echo $M_AMBIENT" 2
type_cmd "ls /n/distros" 4

# 3. Enter the Debian subsystem and list ITS root (busybox /bin/ls).
type_cmd "echo $M_DEBIAN" 2
type_cmd "enter debian { /bin/ls / }" 6

# 4. Write a marker file INSIDE the Debian subsystem. busybox sh; the
#    write lands (or is rejected) on the distro file server only — it
#    must never reach sysroot. Either way the native root must be
#    unchanged afterward (assertion D).
type_cmd "echo $M_WRITE" 2
type_cmd "enter debian { /bin/sh -c \"echo distro > /$WRITE_FILE ; /bin/ls / \" }" 6

# 5. Re-list the native root: the distro-side marker must NOT be here,
#    and /init must still be present (sysroot untouched).
type_cmd "echo $M_NATIVE2" 2
type_cmd "ls /" 4

type_cmd "echo HAMNIX_ISO_DONE_99" 2

sleep 3
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
exec 3>&-
exec 4>&-

echo "[test_img_distro_iso] --- captured serial log ---"
cat "$LOG"
echo "[test_img_distro_iso] --- end serial log ---"

# Sanitize the serial log before slicing/asserting. The guest console
# emits per-keystroke echo, carriage returns, cursor-column escapes, and
# (critically) busybox `ls` colorizes directory names with SGR escapes
# (`\e[1;34msbin\e[m`). Left in place those wrap each dir name in
# non-space bytes, so the (^|space|/)NAME(space|/|$) word-boundary
# assertions below never match. Strip CRs + all CSI/SGR escapes into a
# clean copy and run every slice + grep against THAT.
CLEAN=$(mktemp --tmpdir hamnix-iso.clean.XXXXXX.log)
sed -e 's/\r//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$LOG" > "$CLEAN"
trap 'cleanup; rm -f "$CLEAN"' EXIT

# --- helpers to slice the log between fence markers -------------------
# Extract the lines strictly BETWEEN two fence markers (the output of
# the command run after $1 and before $2). Operates on the sanitized
# copy so dir-name word boundaries are real spaces, not SGR escapes.
slice() {
    awk -v a="$1" -v b="$2" '
        $0 ~ a { grab=1; next }
        $0 ~ b { grab=0 }
        grab   { print }
    ' "$CLEAN"
}

NATIVE1=$(slice "$M_NATIVE1" "$M_AMBIENT")
AMBIENT=$(slice "$M_AMBIENT" "$M_DEBIAN")
DEBIAN=$(slice "$M_DEBIAN" "$M_WRITE")
NATIVE2=$(slice "$M_NATIVE2" "HAMNIX_ISO_DONE_99")

# --- assertions -------------------------------------------------------
fail=0

# Sanity: kernel + shell came up.
grep -a -q "$KERNEL_BANNER" "$LOG" || { echo "[test_img_distro_iso] FAIL: kernel banner absent." >&2; fail=1; }
grep -a -q "$PROMPT_MARKER" "$LOG" || { echo "[test_img_distro_iso] FAIL: shell-ready marker absent." >&2; fail=1; }

# Sanity: the Debian subsystem actually ran a busybox shell (the listing
# must contain SOMETHING — if `enter debian` produced no output the test
# below would vacuously "pass"). Require a Debian-shape dir name.
if [ -z "$(printf '%s' "$DEBIAN" | tr -d '[:space:]')" ]; then
    echo "[test_img_distro_iso] FAIL: enter debian { /bin/ls / } produced NO output — the Debian subsystem did not run." >&2
    echo "[test_img_distro_iso]   (busybox may have failed to exec off ext4 #distro)" >&2
    fail=1
fi

# A. The Debian root has Debian-only top-level dirs the native root does
#    NOT. distro/ carries var + lib64 (Debian closure); sysroot/ does
#    not. Require at least one such marker present in DEBIAN and absent
#    from NATIVE1 — that is the "different file server" proof.
distro_only_hit=0
for d in var lib64 sbin; do
    if printf '%s\n' "$DEBIAN" | grep -a -q -E "(^|[[:space:]/])${d}([[:space:]/]|\$)"; then
        if ! printf '%s\n' "$NATIVE1" | grep -a -q -E "(^|[[:space:]/])${d}([[:space:]/]|\$)"; then
            echo "[test_img_distro_iso] PASS (A): '${d}' present in Debian root, absent from native root."
            distro_only_hit=$((distro_only_hit + 1))
        fi
    fi
done
if [ "$distro_only_hit" -lt 1 ]; then
    echo "[test_img_distro_iso] FAIL (A): no Debian-only top-level dir distinguishes the two roots." >&2
    echo "[test_img_distro_iso]   Debian root listing:" >&2
    printf '%s\n' "$DEBIAN"  | sed 's/^/      /' >&2
    echo "[test_img_distro_iso]   native root listing:" >&2
    printf '%s\n' "$NATIVE1" | sed 's/^/      /' >&2
    fail=1
fi

# B. The native root carries /init (the boot shim); the distro root does
#    NOT. Reverse distinguishing marker — proves NATIVE1 really is
#    sysroot, not accidentally the distro tree.
if printf '%s\n' "$NATIVE1" | grep -a -q -E "(^|[[:space:]/])init([[:space:]/]|\$)"; then
    if printf '%s\n' "$DEBIAN" | grep -a -q -E "(^|[[:space:]/])init([[:space:]/]|\$)"; then
        echo "[test_img_distro_iso] FAIL (B): 'init' appears in BOTH roots — they are not distinct." >&2
        fail=1
    else
        echo "[test_img_distro_iso] PASS (B): native root has /init; Debian root does not."
    fi
else
    echo "[test_img_distro_iso] FAIL (B): native root listing has no 'init' — is it really sysroot?" >&2
    printf '%s\n' "$NATIVE1" | sed 's/^/      /' >&2
    fail=1
fi

# C. The ambient `ls /n/distros` must NOT expose the distro tree. With
#    the ambient bind removed, /n/distros is empty/absent, so a busybox
#    or Debian content marker must NOT appear in its listing. (We accept
#    an error / empty listing — the key is the distro content is gone.)
if printf '%s\n' "$AMBIENT" | grep -a -q -E "(^|[[:space:]/])(busybox|var|lib64|dpkg)([[:space:]/]|\$)"; then
    echo "[test_img_distro_iso] FAIL (C): ambient /n/distros STILL exposes the distro tree (ambient leak not closed):" >&2
    printf '%s\n' "$AMBIENT" | sed 's/^/      /' >&2
    fail=1
else
    echo "[test_img_distro_iso] PASS (C): ambient namespace does NOT expose the distro tree."
fi

# D. After the distro-side write, the native root is UNCHANGED: the
#    write marker file must NOT appear at the native root, and /init must
#    still be present. This is the load-bearing "apt can't corrupt
#    sysroot" guarantee.
if printf '%s\n' "$NATIVE2" | grep -a -q -F "$WRITE_FILE"; then
    echo "[test_img_distro_iso] FAIL (D): distro-side write '$WRITE_FILE' LEAKED into the native root — isolation broken." >&2
    printf '%s\n' "$NATIVE2" | sed 's/^/      /' >&2
    fail=1
else
    echo "[test_img_distro_iso] PASS (D): distro-side write did NOT appear in the native root."
fi
if printf '%s\n' "$NATIVE2" | grep -a -q -E "(^|[[:space:]/])init([[:space:]/]|\$)"; then
    echo "[test_img_distro_iso] PASS (D'): native /init still present after the distro-side write."
else
    echo "[test_img_distro_iso] FAIL (D'): native /init missing after the distro-side write — sysroot mutated." >&2
    fail=1
fi

# No CPU trap during any of the enter-debian probes.
if grep -a -q -E "TRAP: vector|page fault" "$LOG"; then
    echo "[test_img_distro_iso] FAIL: CPU exception observed during the run:" >&2
    grep -a -E "TRAP: vector|page fault" "$LOG" | head -5 >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_img_distro_iso] PASS — native(sysroot) and Debian(distro) roots are isolated."
    rm -f "$LOG"
    exit 0
else
    echo "[test_img_distro_iso] FAIL (serial log: $LOG)" >&2
    exit 1
fi
