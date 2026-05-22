#!/usr/bin/env bash
# scripts/test_distro_namespace.sh - Phase C.5 regression for
# /bin/distrorun (user/distrorun.ad). Proves the architectural shape
# of distro-shape namespaces works end-to-end on top of Phase C's
# rfork (256) + bind (257) + mount (258) primitives:
#
#   1. distrorun parses argv, opens the per-distro backing directory
#      (/var/lib/distros/<distro>/), rfork(RFNAMEG)s to privatise the
#      namespace, mount()s the backing srvfd at "/" (inert today —
#      Phase D wires the chan dispatch), binds each distro-shape
#      subdir (/etc, /usr, /lib, /var) onto backing/{etc,usr,lib,var},
#      re-binds shared paths (/home, /net, /srv, /dev, /proc), and
#      exec's the target binary.
#
#   2. From inside the namespace, /etc/debian_version reads from the
#      backing's /etc/debian_version ("12.0"), proving the bind
#      grafted the testdistro tree into the calling task's view.
#
#   3. From OUTSIDE the namespace (hamsh's own view, unaffected by
#      the child's rfork), /etc/debian_version still reads Hamnix's
#      native value ("hamnix/0.1") — the namespace mutation is per-
#      task, not global.
#
# Test backing fixture is in tests/distros/testdistro/ (etc/debian_
# version = "12.0", etc/os-release with PRETTY_NAME containing
# "Debian"). build_initramfs.py walks tests/distros/* and embeds each
# file at /var/lib/distros/<name>/<rel>.
#
# PASS markers (grepped below):
#   [distrorun] bound /etc -> backing/etc ok
#   [distrorun] entered namespace ok
#   [testdistro] /etc/debian_version=12.0
#   [native]    /etc/debian_version=hamnix/0.1
#
# Run after Phase C's regressions (test_rfork, test_p9mount) pass.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_distro_namespace] (1/4) Build userland (hamsh + distrorun)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_distro_namespace] (2/4) Plant /init = hamsh + " \
     "/var/lib/distros/testdistro/* fixture"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_distro_namespace] (3/4) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_distro_namespace] (4/4) Boot QEMU + drive via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# In-VM script: drive hamsh through (a) native read of
# /etc/debian_version, (b) distrorun-launched read inside the
# namespace, (c) a SECOND native read AFTER the namespace command
# returns. distrorun launches /bin/cat inside the namespace, which
# reads /etc/debian_version. Inside, the bind makes that resolve to
# /var/lib/distros/testdistro/etc/debian_version ("12.0"). Outside,
# hamsh's namespace is unaffected by distrorun's rfork (RFNAMEG only
# privatises the CURRENT task's view, which for distrorun is a
# spawned child of hamsh), so the native read after distrorun still
# sees Hamnix's "hamnix/0.1".
#
# Hamnix's /bin/echo doesn't support -n yet, so we emit BANNER lines
# (full line + newline) followed by a cat invocation. The grep
# assertions below look for the banner and value bytes anywhere in
# the log; the BANNER text is unique per phase so misordering would
# be caught by the post-distrorun banner check.
set +e
(
    sleep 3
    # 1) Baseline native read (before any distrorun call).
    printf '/bin/echo BANNER-NATIVE-PRE\n'
    sleep 1
    printf '/bin/cat /etc/debian_version\n'
    sleep 1
    # 2) Namespaced read via distrorun.
    printf '/bin/echo BANNER-TESTDISTRO\n'
    sleep 1
    printf '/bin/distrorun testdistro /bin/cat /etc/debian_version\n'
    sleep 2
    # 3) Native read AFTER the namespaced child returned — proves
    # hamsh's namespace is untouched.
    printf '/bin/echo BANNER-NATIVE-POST\n'
    sleep 1
    printf '/bin/cat /etc/debian_version\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_distro_namespace] --- captured output ---"
cat "$LOG"
echo "[test_distro_namespace] --- end output ---"

fail=0

# 1. distrorun ran far enough to bind /etc onto the backing.
if grep -F -q "[distrorun] bound /etc -> backing/etc ok" "$LOG"; then
    echo "[test_distro_namespace] OK: distrorun bound /etc into namespace"
else
    echo "[test_distro_namespace] MISS: distrorun didn't bind /etc"
    fail=1
fi

# 2. distrorun reached the "namespace ready" banner BEFORE exec.
if grep -F -q "[distrorun] entered namespace ok" "$LOG"; then
    echo "[test_distro_namespace] OK: distrorun reached pre-exec banner"
else
    echo "[test_distro_namespace] MISS: distrorun never reached exec"
    fail=1
fi

# Helper: assert that VALUE appears in the captured log somewhere
# within the 20 lines following the BANNER marker. This is the
# adjacency we get from `echo BANNER\ncat <file>` — Hamnix's echo
# always trails its line with \n (no -n support), and the next cat
# output lands on the following lines. The 20-line window covers
# the kernel's `elf: entry=...` / `execve: jumping ...` printk debug
# spam, hamsh's prompt redraw, AND (for the distrorun case)
# distrorun's own pre-exec banners before the child's cat output.
#
# `[atkbd-diag]` lines are an unconditional periodic kernel
# keyboard-poll diagnostic (drivers/input/atkbd.ad::atkbd_diag_tick).
# They have nothing to do with this test's subject — and when the VM
# idles between the driver's `sleep` steps the diagnostic emits
# hundreds of them, which would otherwise blow the 20-line window
# apart. Skip them entirely: they are neither program output nor a
# window-consuming line.
assert_banner_value() {
    local banner="$1"
    local value="$2"
    local label="$3"
    if awk -v b="$banner" -v v="$value" '
        BEGIN { armed=0; win=0; found=0 }
        index($0, "[atkbd-diag]") > 0 { next }
        index($0, b) > 0 { armed=1; win=0; next }
        armed { win++ ; if (index($0, v) > 0) { found=1; exit }
                if (win > 20) armed=0 }
        END { exit found ? 0 : 1 }
    ' "$LOG"; then
        echo "[test_distro_namespace] OK: $label"
    else
        echo "[test_distro_namespace] MISS: $label" \
             "(banner='$banner' value='$value')"
        fail=1
    fi
}

# 3. Inside the namespace, /etc/debian_version came from testdistro
#    ("12.0"). distrorun's own pre-exec banner shows up between the
#    BANNER-TESTDISTRO marker and the cat output; the 8-line window
#    in assert_banner_value covers that.
assert_banner_value "BANNER-TESTDISTRO" "12.0" \
    "namespaced /etc/debian_version reads testdistro backing"

# 4. Outside the namespace (hamsh's own view), /etc/debian_version
#    still reads Hamnix's native value. We check BOTH the pre-
#    distrorun and post-distrorun reads — the post one is the real
#    boundary test (proves distrorun's rfork didn't bleed into
#    hamsh's namespace).
assert_banner_value "BANNER-NATIVE-PRE" "hamnix/0.1" \
    "pre-distrorun native /etc/debian_version reads Hamnix"
assert_banner_value "BANNER-NATIVE-POST" "hamnix/0.1" \
    "post-distrorun native /etc/debian_version still reads Hamnix"

if [ "$fail" -ne 0 ]; then
    echo "[test_distro_namespace] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_distro_namespace] PASS"
