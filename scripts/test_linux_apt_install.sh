#!/usr/bin/env bash
# scripts/test_linux_apt_install.sh — marquee proof that REAL Debian
# apt/dpkg binaries run inside `enter linux { ... }`.
#
# This is the replacement for the entire scripts/test_apt_*.sh and
# scripts/test_dpkg_*.sh battery, which exercised the now-deleted
# hand-rolled Adder reimplementations (user/apt.ad, user/dpkg.ad,
# user/dpkg_deb.ad). Per the user's direction — "apt should be a
# Linux binary running in a Linux namespace" — the new design runs
# the genuine /usr/bin/apt-get and /usr/bin/dpkg out of the
# debootstrap'd debian-minbase rootfs staged at
# /var/lib/distros/default/.
#
# What this asserts:
#
#   1. `enter linux { /usr/bin/dpkg --version }` runs the REAL Debian
#      dpkg (dynamically linked against ld-linux + libc + libmd +
#      libselinux + libpcre2-8 + ...) and prints
#      "Debian 'dpkg' package management program version <X>". The
#      version-banner string proves the binary executed (not stub),
#      and the substring "Debian" pins the provenance.
#
#   2. `enter linux { /usr/bin/apt-get --version }` runs the real
#      Debian apt-get (much heavier .so closure: libapt-pkg + libapt-
#      private + libstdc++ + libsystemd + libcrypto + libxxhash + ...)
#      and prints "apt <X.Y.Z>".
#
# Skip-on-missing: if tests/distros/debian-minbase/rootfs/ is absent
# (host hasn't run BUILD.sh), exit 0 with a SKIP message — mirrors
# test_distro_debian.sh / test_u42_dynamic_elf.sh.
#
# This test does NOT exercise `apt-get update` / `apt-get install
# hello` end-to-end against a live mirror — the QEMU guest has no
# routed network to deb.debian.org in the default test environment,
# and asserting against live external infra would make the gating
# regression flaky. The "real binary executes and reports its
# version" assertion is the milestone proof; live-mirror exercises
# are an opt-in follow-on (e.g. scripts/test_apt_live.sh's
# successor, opt-in via env var) once a working network bind for
# the linux ns is layered on.
#
# PASS markers (greppable):
#   BANNER_DPKG_VERSION_START / Debian 'dpkg' package management
#   BANNER_APT_VERSION_START  / apt

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ROOTFS=tests/distros/debian-minbase/rootfs
if [ ! -f "$ROOTFS/usr/bin/dpkg" ] || [ ! -f "$ROOTFS/usr/bin/apt-get" ]; then
    echo "[test_linux_apt_install] SKIP: $ROOTFS/usr/bin/{dpkg,apt-get} not staged"
    echo "    Build with: bash tests/distros/debian-minbase/BUILD.sh"
    echo "    (see tests/distros/debian-minbase/HOWTO.md)"
    exit 0
fi

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_linux_apt_install] (1/5) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

# /etc/hamsh.rc captures the same linux + debian ns templates rc.boot
# uses, with no boot-service spawns — keeps the boot deterministic and
# fast (no sshd accept-loop starving the prompt; the
# test_linux_namespace.sh playbook).
echo "[test_linux_apt_install] (2/5) Plant /etc/hamsh.rc"
RC_TMP=$(mktemp /tmp/hamsh-rc-linuxapt.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
linux = ns clean {
    bind /var/lib/distros/default /
    bind /home /home
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
    bind /tmp /tmp
}
debian = ns clean {
    bind /var/lib/distros/default /
    bind /home /home
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
    bind /tmp /tmp
}
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[test_linux_apt_install] (3/5) Build initramfs (hamsh as /init + real Debian)"
HAMNIX_DEFAULT_REAL_DEBIAN=1 HAMNIX_HAMSH_RC="$RC_TMP" \
    INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LOG=$(mktemp /tmp/test-linux-apt.XXXXXX.log)
# Preserve LOG on failure so the captured QEMU output is debuggable;
# only clean up on PASS. Re-running this test would otherwise discard
# the only diagnostic.
cleanup() {
    rm -f "$RC_TMP"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null
}
trap cleanup EXIT

echo "[test_linux_apt_install] (4/5) Build kernel"
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "[test_linux_apt_install] (5/5) Boot QEMU + drive dpkg/apt-get --version"
set +e
(
    # Wait for hamsh to source /etc/hamsh.rc + reach interactive prompt.
    sleep 8

    # PROBE 0: list the distro tree contents from inside the ns so we
    # can tell whether the bind grafted /var/lib/distros/default at /
    # vs. whether sys_spawn just couldn't find dpkg's blob. Tries the
    # standalone ls path that test_linux_namespace.sh proves works
    # (busybox applet symlinks under /var/lib/distros/default/bin).
    # If the cpio has /var/lib/distros/default/usr/bin/dpkg present
    # this `ls /usr/bin` should print "dpkg" + friends inside the ns.
    printf 'echo BANNER_PROBE_LS_USRBIN_START\n'; sleep 1
    printf 'enter linux { /bin/ls /usr/bin }\n'; sleep 3
    printf 'echo BANNER_PROBE_LS_USRBIN_END\n'; sleep 1

    # dpkg --version: the smaller binary; smoke test for "any real
    # Debian binary runs at all inside the ns". 10 s for the dynamic
    # linker to mmap ld + libc + libmd + libselinux + libpcre2-8 +
    # apply RELA + JUMP_SLOT relocs before main() runs.
    printf 'echo BANNER_DPKG_VERSION_START\n'; sleep 1
    printf 'enter linux { /usr/bin/dpkg --version }\n'; sleep 10
    printf 'echo BANNER_DPKG_VERSION_END\n'; sleep 1

    # apt-get --version: bigger binary, fatter .so closure.
    printf 'echo BANNER_APT_VERSION_START\n'; sleep 1
    printf 'enter linux { /usr/bin/apt-get --version }\n'; sleep 15
    printf 'echo BANNER_APT_VERSION_END\n'; sleep 1

    printf 'echo BANNER_DONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[test_linux_apt_install] --- captured output (tail) ---"
tail -300 "$LOG" | strings
echo "[test_linux_apt_install] --- end output ---"

fail=0

check_present() {
    local needle="$1"
    local label="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_linux_apt_install] OK: $label"
    else
        echo "[test_linux_apt_install] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Banner-window assertion (mirrors test_linux_namespace.sh).
check_banner_value() {
    local banner="$1"
    local value="$2"
    local label="$3"
    if awk -v b="$banner" -v v="$value" '
        BEGIN { armed=0; win=0; found=0 }
        index($0, "[atkbd-diag]") > 0 { next }
        index($0, b) > 0 { armed=1; win=0; next }
        armed { win++ ; if (index($0, v) > 0) { found=1; exit }
                if (win > 40) armed=0 }
        END { exit found ? 0 : 1 }
    ' "$LOG"; then
        echo "[test_linux_apt_install] OK: $label"
    else
        echo "[test_linux_apt_install] MISS: $label" \
             "(banner='$banner' value='$value')"
        fail=1
    fi
}

# Sanity: hamsh sourced the rc and defined the linux/debian ns values.
check_present "TEST_RC_DONE_DEFINING_NS" \
              "/etc/hamsh.rc captured linux + debian ns values"

# dpkg --version prints "Debian 'dpkg' package management program ..."
check_banner_value "BANNER_DPKG_VERSION_START" "Debian" \
                   "enter linux { /usr/bin/dpkg --version } printed 'Debian'"
check_banner_value "BANNER_DPKG_VERSION_START" "dpkg" \
                   "enter linux { /usr/bin/dpkg --version } printed 'dpkg'"

# apt-get --version prints "apt X.Y.Z (architecture)"
check_banner_value "BANNER_APT_VERSION_START" "apt " \
                   "enter linux { /usr/bin/apt-get --version } printed 'apt '"

if [ "$fail" -ne 0 ]; then
    echo "[test_linux_apt_install] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_linux_apt_install] PASS"
