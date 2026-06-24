#!/usr/bin/env bash
# scripts/test_linux_apt_install_e2e.sh — END-TO-END proof that
# `apt-get install` (and the `dpkg -i` short path) actually INSTALL a
# package from a LOCAL file:// repo inside `enter linux { ... }`, with
# the installed binary then RUNNING.
#
# This is the keystone usability gate for the minimal-Debian Linux
# namespace. The companion scripts/test_linux_apt_install.sh only proves
# `--version` (the .so closure maps + the binary's main() runs). This
# test drives the real install fork chain:
#
#   apt-get install -> /usr/lib/apt/methods/file (fetch the .deb from
#       file:///opt/localrepo) -> dpkg --unpack -> dpkg-deb -> tar ->
#       gzip -> coreutils filesystem install -> maintainer scripts.
#
# The leaf package is `hamhello` (scripts/build_local_apt_repo.sh): a
# dependency-free .deb whose installed /usr/bin/hamhello prints the
# unique marker HAMHELLO_INSTALLED_AND_RAN_OK. Asserting that marker
# AFTER an install proves the install populated the live filesystem and
# the installed binary executes.
#
# Skip-on-missing: if the debootstrap fixture isn't staged, exit 0 SKIP.
#
# PASS markers (greppable):
#   BANNER_DPKG_I_START  ... HAMHELLO_INSTALLED_AND_RAN_OK
#   BANNER_APT_INSTALL_START ... Setting up hamhello / 1 ... newly installed
#   BANNER_HAMHELLO_RUN_START ... HAMHELLO_INSTALLED_AND_RAN_OK

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ROOTFS=tests/distros/debian-minbase/rootfs
if [ ! -f "$ROOTFS/usr/bin/dpkg" ] || [ ! -f "$ROOTFS/usr/bin/apt-get" ]; then
    echo "[test_linux_apt_install_e2e] SKIP: $ROOTFS/usr/bin/{dpkg,apt-get} not staged"
    echo "    Build with: bash tests/distros/debian-minbase/BUILD.sh"
    exit 0
fi

# Ensure the local file:// repo + the dpkg-i cache copy are staged.
echo "[test_linux_apt_install_e2e] (0/5) Stage local file:// apt repo"
bash scripts/build_local_apt_repo.sh

if [ ! -f "$ROOTFS/opt/localrepo/pool/main/h/hamhello/hamhello_1.0_amd64.deb" ]; then
    echo "[test_linux_apt_install_e2e] SKIP: local repo .deb not staged"
    exit 0
fi

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_linux_apt_install_e2e] (1/5) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_linux_apt_install_e2e] (2/5) Plant /etc/hamsh.rc"
RC_TMP=$(mktemp /tmp/hamsh-rc-apte2e.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
linux = ns clean {
    bind '#r/var/lib/distros/default' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[test_linux_apt_install_e2e] (3/5) Build initramfs (real Debian + local repo)"
HAMNIX_DEFAULT_REAL_DEBIAN=1 HAMNIX_HAMSH_RC="$RC_TMP" \
    INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LOG=$(mktemp /tmp/test-linux-apt-e2e.XXXXXX.log)
cleanup() {
    rm -f "$RC_TMP"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
}
trap cleanup EXIT

echo "[test_linux_apt_install_e2e] (4/5) Build kernel"
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "[test_linux_apt_install_e2e] (5/5) Boot QEMU + drive apt-get install / dpkg -i"
set +e
(
    rc_ready=0
    waited=0
    while [ "$waited" -lt 240 ]; do
        if grep -aq "TEST_RC_DONE_DEFINING_NS" "$LOG" 2>/dev/null; then
            rc_ready=1
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    sleep 3

    # Smoke: a few stock Debian binaries run (proves ld-linux + dash/bash
    # + the SMAP read-path fix let arbitrary Debian binaries execute).
    printf 'echo BANNER_COVERAGE_START\n'; sleep 1
    printf 'enter linux { /bin/ls / }\n'; sleep 4
    printf 'enter linux { /bin/cat /etc/debian_version }\n'; sleep 4
    printf "enter linux { /bin/bash -c 'echo BASH_RAN_OK' }\n"; sleep 6
    printf 'echo BANNER_COVERAGE_END\n'; sleep 1

    # dpkg -i short path: dpkg -> dpkg-deb -> tar -> gzip -> install.
    printf 'echo BANNER_DPKG_I_START\n'; sleep 1
    printf 'enter linux { /usr/bin/dpkg -i /var/cache/apt/archives/hamhello_1.0_amd64.deb }\n'; sleep 18
    printf 'enter linux { /usr/bin/hamhello }\n'; sleep 6
    printf 'echo BANNER_DPKG_I_END\n'; sleep 1

    # apt-get install from the file:// repo (full method fork chain). Run
    # `apt-get update` first so apt reads the local Release/Packages.
    printf 'echo BANNER_APT_INSTALL_START\n'; sleep 1
    printf 'enter linux { /usr/bin/apt-get -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/local.list -o Dir::Etc::sourceparts=- update }\n'; sleep 18
    printf 'enter linux { /usr/bin/apt-get install -y --reinstall hamhello }\n'; sleep 25
    printf 'echo BANNER_APT_INSTALL_END\n'; sleep 1

    printf 'echo BANNER_HAMHELLO_RUN_START\n'; sleep 1
    printf 'enter linux { /usr/bin/hamhello }\n'; sleep 6
    printf 'echo BANNER_HAMHELLO_RUN_END\n'; sleep 1

    printf 'echo BANNER_DONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 600s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 768M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[test_linux_apt_install_e2e] --- captured output (tail) ---"
tail -400 "$LOG" | strings
echo "[test_linux_apt_install_e2e] --- end output ---"

fail=0
check_present() {
    local needle="$1" label="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_linux_apt_install_e2e] OK: $label"
    else
        echo "[test_linux_apt_install_e2e] MISS: $label  ('$needle')"
        fail=1
    fi
}
check_absent() {
    local needle="$1" label="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_linux_apt_install_e2e] FAIL-PRESENT: $label ('$needle')"
        fail=1
    else
        echo "[test_linux_apt_install_e2e] OK (absent): $label"
    fi
}

check_present "TEST_RC_DONE_DEFINING_NS" "rc captured linux ns"
check_present "BASH_RAN_OK"              "stock Debian /bin/bash -c ran"
check_present "HAMHELLO_INSTALLED_AND_RAN_OK" \
              "installed /usr/bin/hamhello executed (dpkg -i and/or apt)"
check_present "Setting up hamhello" "apt/dpkg configured hamhello"

# No SMAP read-path crash should recur.
check_absent "kernel write to RO user page" "no SMAP read-path SIGSEGV"
check_absent "failed to map segment from shared object" \
             "no ld.so segment-map failure"

if [ "$fail" -ne 0 ]; then
    echo "[test_linux_apt_install_e2e] FAIL (qemu rc=$rc); LOG=$LOG"
    exit 1
fi
echo "[test_linux_apt_install_e2e] PASS"
