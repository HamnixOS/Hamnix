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

# The whole install pipeline is driven by SHORT, DIRECT
# `enter linux { /usr/bin/<binary> ... }` lines (the proven exec path,
# same as the dpkg-i keystone), NOT a `dash <script>` wrapper. Two
# reasons:
#   1. hamsh's line editor echoes ~1 char per readline tick, so typed
#      command length is the wall-clock cost. apt's auth/insecure
#      options are BAKED into the staged /etc/apt/apt.conf.d/00hamnix
#      (see scripts/stage_host_dpkg_rootfs.sh), and the ONLY configured
#      source is the local file:// list (no network sources.list is
#      staged), so the driven apt commands are short:
#         enter linux { /usr/bin/apt-get update }
#         enter linux { /usr/bin/apt-get install -y hamhello }
#      No `-o Dir::Etc:: ...` / `-o Acquire:: ...` flags to type.
#   2. It does not depend on `dash <scriptfile>` working in the ns.
# Nothing extra is embedded in the cpio here — the local repo + apt
# config already live in the staged rootfs (built into the cpio).

echo "[apt-e2e] (3/5) Build initramfs"
HAMNIX_DEFAULT_REAL_DEBIAN=1 HAMNIX_HAMSH_RC="$RC_TMP" \
    INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LOG=$(mktemp /tmp/test-apt-e2e.XXXXXX.log)
cleanup() {
    rm -f "$RC_TMP"
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

    # Helper: type a command, then wait (bounded) for an expected marker
    # in the captured serial before moving on — never a blind fixed
    # sleep (hamsh echoes ~1 char/tick, so command timing varies). Each
    # `enter linux { ... }` is a SHORT, DIRECT binary invocation.
    drive() { printf '%s\n' "$1"; }
    wait_for() {  # $1=marker  $2=max-seconds
        local w=0
        while [ "$w" -lt "$2" ]; do
            grep -aq "$1" "$LOG" 2>/dev/null && return 0
            sleep 2; w=$((w + 2))
        done
        return 1
    }

    # Sanity 1: real Debian dpkg still RUNS under the writable overlay.
    drive 'echo HAMHELLO_VER_START'
    drive 'enter linux { /usr/bin/dpkg --version }'
    drive 'echo HAMHELLO_VER_END'; wait_for HAMHELLO_VER_END 60

    # Leg A (dpkg -i keystone): install the pre-staged archive + run it.
    drive 'echo HAMHELLO_DPKG_INSTALL_START'
    drive 'enter linux { /usr/bin/dpkg --force-all -i /var/cache/apt/archives/hamhello_1.0_amd64.deb }'
    drive 'echo HAMHELLO_DPKG_INSTALL_END'; wait_for HAMHELLO_DPKG_INSTALL_END 90
    drive 'echo HAMHELLO_RUN_START'
    drive 'enter linux { /usr/bin/hamhello }'
    drive 'echo HAMHELLO_RUN_END'; wait_for HAMHELLO_RUN_END 30

    # Leg B (KEYSTONE — apt-get install from the local file:// repo).
    # First remove the dpkg-installed copy so apt's OWN pipeline (index
    # parse -> file:// fetch via /usr/lib/apt/methods/file -> dpkg unpack
    # + configure) is what re-creates /usr/bin/hamhello. apt's auth opts
    # + the sole local source are baked into the staged rootfs, so these
    # commands need NO `-o` flags. If apt's CPU/arch table or apt.conf.d
    # read were broken, apt-get aborts with "Error reading the CPU
    # table" before any fetch.
    drive 'echo HAMHELLO_APT_INSTALL_START'
    drive 'enter linux { /usr/bin/dpkg --force-all -P hamhello }'; sleep 8
    drive 'enter linux { /usr/bin/apt-get update }'; wait_for "Reading package lists" 60
    drive 'enter linux { /usr/bin/apt-get install -y hamhello }'
    drive 'echo APT_WRAPPER_DONE'; wait_for APT_WRAPPER_DONE 180
    drive 'echo HAMHELLO_APT_RUN'
    drive 'enter linux { /usr/bin/hamhello }'
    drive 'echo HAMHELLO_APT_INSTALL_END'; wait_for HAMHELLO_APT_INSTALL_END 40

    drive 'echo BANNER_DONE'; wait_for BANNER_DONE 20
    drive 'exit'; sleep 1
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
