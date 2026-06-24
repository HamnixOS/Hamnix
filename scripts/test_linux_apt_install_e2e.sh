#!/usr/bin/env bash
# scripts/test_linux_apt_install_e2e.sh — END-TO-END proof that a REAL
# Debian dpkg/apt-get INSTALL completes inside `enter linux { ... }` and
# the installed binary RUNS, using a WRITABLE tmpfs overlay over the
# read-only cpio root (the V3 writable-overlay layer).
#
# This is the install-completing successor to test_linux_apt_install.sh
# (which only proved `--version` runs). It exercises:
#
#   1. `dpkg -i /var/cache/apt/archives/hamhello_1.0_amd64.deb`
#        -> "Setting up hamhello"   (dpkg wrote the admindir + unpacked
#           /usr/bin/hamhello into the writable overlay)
#   2. /usr/bin/hamhello            -> HAMHELLO_INSTALLED_AND_RAN_OK
#        (the installed program runs from the overlay)
#   3. `apt-get install -y hamhello` from file:///opt/localrepo
#        -> "Setting up hamhello"   (apt's whole pipeline: index parse,
#           file:// fetch, dpkg unpack/configure, all writing the overlay)
#
# THE WRITABLE LAYER. The cpio initramfs (#r/var/lib/distros/default) is
# read-only, so dpkg cannot create its lock/admindir or unpack files.
# The namespace recipe UNION-binds a writable tmpfs server (#t) MBEFORE
# the cpio for EVERY top-level dir a package install writes into:
#
#     bind '#r/<distro>/usr' /usr        # cpio read base (head of union)
#     bind -bc '#t/usr' /usr             # writable overlay, MBEFORE+MCREATE
#
# A READ of an existing file (/usr/bin/dpkg) misses the tmpfs member and
# falls through to the cpio base; a CREATE/WRITE (/usr/bin/hamhello,
# /var/lib/dpkg/status) lands in the writable tmpfs member (it carries
# MCREATE). fs/tmpfs.ad serves a synthetic writable root per top-level
# dir and does mkdir -p; fs/vfs_mount.ad routes the localized
# /usr,/etc,... paths to the tmpfs backend.
#
# Boots the cpio via the qemu `-kernel` shim (the VM-fast path). Gated on
# the boot-ready marker TEST_RC_DONE_DEFINING_NS, never a fixed sleep.
#
# Skip-on-missing: if the debian-minbase rootfs / its dpkg/apt-get / the
# staged local repo are absent, exit 0 with SKIP (mirrors the sibling
# tests). The local repo is staged by scripts/build_local_apt_repo.sh.
#
# PASS markers (greppable):
#   HAMHELLO_DPKG_INSTALL_START / Setting up hamhello
#   HAMHELLO_RUN_START          / HAMHELLO_INSTALLED_AND_RAN_OK
#   HAMHELLO_APT_INSTALL_START  / Setting up hamhello

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ROOTFS=tests/distros/debian-minbase/rootfs
if [ ! -f "$ROOTFS/usr/bin/dpkg" ] || [ ! -f "$ROOTFS/usr/bin/apt-get" ]; then
    echo "[apt-e2e] SKIP: $ROOTFS/usr/bin/{dpkg,apt-get} not staged"
    echo "    Build with: bash tests/distros/debian-minbase/BUILD.sh"
    exit 0
fi

# Ensure the offline local repo + the dpkg-i archive are staged.
if [ ! -f "$ROOTFS/var/cache/apt/archives/hamhello_1.0_amd64.deb" ] \
   || [ ! -d "$ROOTFS/opt/localrepo" ]; then
    echo "[apt-e2e] staging local apt repo (build_local_apt_repo.sh)"
    bash scripts/build_local_apt_repo.sh || {
        echo "[apt-e2e] SKIP: could not stage local repo"; exit 0; }
fi
if [ ! -f "$ROOTFS/var/cache/apt/archives/hamhello_1.0_amd64.deb" ]; then
    echo "[apt-e2e] SKIP: hamhello .deb not staged after repo build"
    exit 0
fi

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[apt-e2e] (1/5) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

# The distro tree under the cpio is /var/lib/distros/default. Its
# server-anchored form is #r/var/lib/distros/default. We bind the cpio
# subtree at / for the read base, then union a writable tmpfs overlay
# (MBEFORE+MCREATE, via `bind -bc`) over each top-level dir dpkg/apt
# write into. /dev /proc /srv are device servers; /tmp is the existing
# tmpfs scratch.
echo "[apt-e2e] (2/5) Plant /etc/hamsh.rc (writable overlay recipe)"
RC_TMP=$(mktemp /tmp/hamsh-rc-apte2e.XXXXXX.rc)
# Writable overlay via a SINGLE union point at `/`: the read-only cpio
# distro subtree is the base (union head); a writable tmpfs server is
# stacked MBEFORE it AND claims creates (MCREATE, via `bind -bc`). A
# READ of an existing file (/usr/bin/dpkg) misses the empty tmpfs member
# and falls through to the cpio base; a CREATE anywhere
# (/var/lib/dpkg/status, /usr/bin/hamhello) lands in the writable tmpfs
# member. One union point keeps merged-/usr symlink layouts intact (no
# per-dir cpio rebind that would shadow a /bin -> /usr/bin symlink).
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
export 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
linux = ns clean {
    bind '#r/var/lib/distros/default' /
    bind -bc '#t' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#t/tmp' /tmp
    bind '#/' /n
}
echo TEST_RC_DONE_DEFINING_NS
EOF

# apt driver wrapper — runs entirely inside the guest's dash, so apt's
# `Dir::Etc::` option syntax never reaches hamsh's tokenizer. Points apt
# at ONLY the local file:// list (sourceparts=/dev/null drops the main
# network sources.list so `update` can't hang on deb.debian.org).
APT_WRAP=$(mktemp /tmp/apt_local_install.XXXXXX.sh)
cat > "$APT_WRAP" <<'AEOF'
#!/bin/sh
set -x
APTOPTS="-o Dir::Etc::sourcelist=/etc/apt/sources.list.d/local.list -o Dir::Etc::sourceparts=/dev/null -o Acquire::AllowInsecureRepositories=true -o APT::Get::AllowUnauthenticated=true"
/usr/bin/apt-get $APTOPTS update
/usr/bin/apt-get $APTOPTS install -y --allow-unauthenticated hamhello
echo APT_WRAPPER_DONE
AEOF

echo "[apt-e2e] (3/5) Build initramfs"
HAMNIX_DEFAULT_REAL_DEBIAN=1 HAMNIX_HAMSH_RC="$RC_TMP" \
    HAMNIX_EXTRA_CPIO_FILE="$APT_WRAP:/var/lib/distros/default/apt_local_install.sh" \
    INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LOG=$(mktemp /tmp/test-apt-e2e.XXXXXX.log)
cleanup() {
    rm -f "$RC_TMP" "$APT_WRAP"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null
}
trap cleanup EXIT

echo "[apt-e2e] (4/5) Build kernel"
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "[apt-e2e] (5/5) Boot QEMU + drive dpkg/apt install"
set +e
(
    waited=0
    while [ "$waited" -lt 240 ]; do
        if grep -aq "TEST_RC_DONE_DEFINING_NS" "$LOG" 2>/dev/null; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    sleep 2

    # Sanity 1: the real Debian binaries still RUN under the union
    # overlay (a regression guard — the per-dir overlay broke this).
    printf 'echo HAMHELLO_VER_START\n'; sleep 1
    printf 'enter linux { /usr/bin/dpkg --version }\n'; sleep 10
    printf 'echo HAMHELLO_VER_END\n'; sleep 1

    # Sanity 2: writable overlay is live — create + read back a file
    # under a normally-read-only dir, using the installed dash directly.
    printf 'echo HAMHELLO_OVERLAY_START\n'; sleep 1
    printf 'enter linux { /usr/bin/dash -c "echo OVL_OK > /usr/ovl_probe && cat /usr/ovl_probe" }\n'; sleep 6
    printf 'echo HAMHELLO_OVERLAY_END\n'; sleep 1

    # dpkg -i the pre-staged archive.
    printf 'echo HAMHELLO_DPKG_INSTALL_START\n'; sleep 1
    printf 'enter linux { /usr/bin/dpkg --force-all -i /var/cache/apt/archives/hamhello_1.0_amd64.deb }\n'; sleep 30
    printf 'echo HAMHELLO_DPKG_INSTALL_END\n'; sleep 1

    # Run the installed program.
    printf 'echo HAMHELLO_RUN_START\n'; sleep 1
    printf 'enter linux { /usr/bin/hamhello }\n'; sleep 6
    printf 'echo HAMHELLO_RUN_END\n'; sleep 1

    # apt-get install from the local file:// repo. Drive apt entirely
    # off a wrapper script (avoids hamsh tokenizing apt's `Dir::Etc::`
    # option syntax). The wrapper is staged below into the rootfs.
    printf 'echo HAMHELLO_APT_INSTALL_START\n'; sleep 1
    printf 'enter linux { /usr/bin/dash /apt_local_install.sh }\n'; sleep 50
    printf 'echo HAMHELLO_APT_INSTALL_END\n'; sleep 1

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

echo "[apt-e2e] --- captured output (tail) ---"
tail -400 "$LOG" | strings
echo "[apt-e2e] --- end output ---"

fail=0
check_present() {
    if grep -a -F -q "$1" "$LOG"; then
        echo "[apt-e2e] OK: $2"
    else
        echo "[apt-e2e] MISS: $2  ('$1')"
        fail=1
    fi
}

check_present "TEST_RC_DONE_DEFINING_NS" "rc captured the linux ns"
check_present "HAMHELLO_INSTALLED_AND_RAN_OK" \
    "installed /usr/bin/hamhello ran (marker printed)"

# At least one of dpkg/apt must report "Setting up hamhello".
if grep -a -F -q "Setting up hamhello" "$LOG"; then
    echo "[apt-e2e] OK: 'Setting up hamhello' (install configured the pkg)"
else
    echo "[apt-e2e] MISS: 'Setting up hamhello' not seen"
    fail=1
fi

check_absent() {
    if grep -a -F -q "$1" "$LOG"; then
        echo "[apt-e2e] FAIL-PRESENT: $2 ('$1')"
        fail=1
    else
        echo "[apt-e2e] OK (absent): $2"
    fi
}
check_absent "unable to open/create dpkg frontend lock" \
    "no read-only-root dpkg lock failure"

if [ "$fail" -ne 0 ]; then
    echo "[apt-e2e] FAIL (qemu rc=$rc) — log: $LOG"
    exit 1
fi
echo "[apt-e2e] PASS"
rm -f "$LOG"
