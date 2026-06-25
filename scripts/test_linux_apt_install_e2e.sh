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

# SINGLE in-guest driver script — runs ENTIRELY inside the guest's dash
# so the whole dpkg/apt pipeline executes from ONE short typed hamsh
# line (`enter linux { /usr/bin/dash /drive_all.sh }`). This is
# deliberate: hamsh's line editor echoes one character per idle/readline
# tick, so a long `enter linux { ... }` command line costs ~1 tick PER
# CHARACTER. Typing the four separate multi-line install commands (each
# ~50+ chars, plus apt's `Dir::Etc::` option syntax that hamsh would
# also have to tokenize) blew past the QEMU wall-clock budget before the
# install legs even ran. Collapsing all of it into one staged script
# means the test types ~35 characters total to drive the whole install.
#
# apt is pointed at ONLY the local file:// list (sourceparts=/dev/null
# drops the network sources.list so `update` can't hang on
# deb.debian.org). set -x traces each command so the captured serial
# shows exactly which leg ran.
APT_WRAP=$(mktemp /tmp/drive_all.XXXXXX.sh)
cat > "$APT_WRAP" <<'AEOF'
#!/bin/sh
set -x
APTOPTS="-o Dir::Etc::sourcelist=/etc/apt/sources.list.d/local.list -o Dir::Etc::sourceparts=/dev/null -o Acquire::AllowInsecureRepositories=true -o APT::Get::AllowUnauthenticated=true"

# Sanity 1: real Debian dpkg still RUNS under the writable union overlay.
echo HAMHELLO_VER_START
/usr/bin/dpkg --version
echo HAMHELLO_VER_END

# Sanity 2: writable overlay is live (create + read back under a
# normally read-only dir).
echo HAMHELLO_OVERLAY_START
echo OVL_OK > /usr/ovl_probe
read L < /usr/ovl_probe
echo "OVL_READBACK=$L"
echo HAMHELLO_OVERLAY_END

# Leg A: dpkg -i the pre-staged archive, then run the installed program.
echo HAMHELLO_DPKG_INSTALL_START
/usr/bin/dpkg --force-all -i /var/cache/apt/archives/hamhello_1.0_amd64.deb
echo HAMHELLO_DPKG_INSTALL_END
echo HAMHELLO_RUN_START
/usr/bin/hamhello
echo HAMHELLO_RUN_END

# Leg B: the KEYSTONE — apt-get install from the local file:// repo.
# Remove the dpkg-installed copy first so apt's own install is what
# re-creates /usr/bin/hamhello (proves apt's whole pipeline: index
# parse, file:// fetch via /usr/lib/apt/methods/file, dpkg unpack +
# configure). If apt's CPU/arch table or apt.conf.d read were broken
# this aborts with "Error reading the CPU table" before any fetch.
echo HAMHELLO_APT_INSTALL_START
/usr/bin/dpkg --force-all -r hamhello 2>/dev/null || true
rm -f /usr/bin/hamhello
/usr/bin/apt-get $APTOPTS update
/usr/bin/apt-get $APTOPTS install -y --reinstall --allow-unauthenticated hamhello \
  || /usr/bin/apt-get $APTOPTS install -y --allow-unauthenticated hamhello
echo HAMHELLO_APT_RUN
/usr/bin/hamhello
echo APT_WRAPPER_DONE
echo HAMHELLO_APT_INSTALL_END
echo BANNER_DONE
AEOF

echo "[apt-e2e] (3/5) Build initramfs"
HAMNIX_DEFAULT_REAL_DEBIAN=1 HAMNIX_HAMSH_RC="$RC_TMP" \
    HAMNIX_EXTRA_CPIO_FILE="$APT_WRAP:/var/lib/distros/default/drive_all.sh" \
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

    # Drive the ENTIRE dpkg + apt-get install pipeline from ONE short
    # typed hamsh line. hamsh's line editor echoes ~1 char per readline
    # tick, so every typed character costs wall-clock; a handful of long
    # `enter linux { ... }` lines (esp. apt's `Dir::Etc::` options) blew
    # past the QEMU budget before the install ran. The staged
    # /drive_all.sh runs all legs in-guest and prints every marker.
    printf 'enter linux { /usr/bin/dash /drive_all.sh }\n'
    # Generous settle: file:// fetch + dpkg unpack/configure + two
    # apt-get invocations. The drive script ends by printing BANNER_DONE;
    # we wait on that marker (bounded) rather than a blind fixed sleep.
    waited=0
    while [ "$waited" -lt 300 ]; do
        if grep -aq "BANNER_DONE" "$LOG" 2>/dev/null; then break; fi
        sleep 2
        waited=$((waited + 2))
    done
    sleep 2
    printf 'exit\n'; sleep 1
) | timeout 1200s qemu-system-x86_64 \
    -enable-kvm -cpu host \
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

# The two reported apt-get blockers MUST be gone (staging gaps fixed by
# scripts/stage_host_dpkg_rootfs.sh: /usr/share/dpkg/*table for libapt's
# CPU/arch table + /etc/apt/apt.conf.d/).
check_absent "Error reading the CPU table" \
    "apt CPU/arch table read (no missing dpkg cputable/tupletable)"
check_absent "Unable to read /etc/apt/apt.conf.d" \
    "apt config-dir read (/etc/apt/apt.conf.d present)"

# The KEYSTONE leg: apt-get install (not just dpkg -i) drove a real
# install from the local file:// repo. After the HAMHELLO_APT_INSTALL
# marker, apt must report the package newly installed AND the
# apt-installed binary must run (the dpkg copy was removed first).
if grep -a -F -q "HAMHELLO_APT_INSTALL_START" "$LOG" \
   && grep -a -F -q "APT_WRAPPER_DONE" "$LOG"; then
    echo "[apt-e2e] OK: apt-get install leg ran to completion"
else
    echo "[apt-e2e] MISS: apt-get install leg did not complete"
    fail=1
fi
if grep -a -E -q "newly installed|Unpacking hamhello|Setting up hamhello" "$LOG"; then
    echo "[apt-e2e] OK: apt-get reported hamhello install (newly installed/unpack/setup)"
else
    echo "[apt-e2e] MISS: no apt-get install confirmation for hamhello"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[apt-e2e] FAIL (qemu rc=$rc) — log: $LOG"
    exit 1
fi
echo "[apt-e2e] PASS"
rm -f "$LOG"
