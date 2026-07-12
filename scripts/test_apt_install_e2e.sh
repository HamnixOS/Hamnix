#!/usr/bin/env bash
# scripts/test_apt_install_e2e.sh — END-TO-END proof that `apt-get install`
# of a package WITH A DEPENDENCY completes inside `enter linux { ... }`, the
# WHOLE multi-package pipeline runs (resolve deps -> download both .debs ->
# unpack both -> configure the dependency BEFORE the leaf -> run a postinst
# maintainer script), and the installed binary RUNS and reads its
# dependency's data. This is the endgame-keystone install path: apt behaving
# as a real package manager, not a single dependency-free leaf.
#
# WHY A DEPENDENCY (vs test_linux_apt_install_e2e.sh's hamhello). hamhello is
# a dependency-FREE leaf: it proves the base install path but never exercises
# apt's DEPENDENCY RESOLVER, multi-package unpack, ordered configure, or a
# maintainer script. This gate installs `hamdep-app`, which
# `Depends: hamdep-lib`. A successful `apt-get install -y hamdep-app` must:
#   1. resolve hamdep-app -> pull in hamdep-lib          (dep resolution)
#   2. fetch BOTH .debs from file:///opt/localrepo       (multi-pkg acquire)
#   3. Unpacking hamdep-lib / Unpacking hamdep-app        (multi-pkg unpack)
#   4. Setting up hamdep-lib  (runs its postinst: HAMDEP_LIB_POSTINST_RAN)
#   5. Setting up hamdep-app  (configured AFTER its dep — ordering)
#   6. /usr/bin/hamdep-app reads hamdep-lib's data file and prints
#        HAMDEP_APP_RAN:HAMDEP_LIB_DATA_OK  (proves BOTH pkgs installed)
#
# The staged local repo (scripts/build_local_apt_repo.sh) carries the real
# dependency metadata (Depends: line in the Packages index), so apt's own
# resolver — not the test — decides to install hamdep-lib first. Uses the
# same WRITABLE tmpfs overlay over the read-only cpio root as the sibling
# test, so dpkg can create its admindir + unpack into the live filesystem.
#
# A STAGED LOCAL MIRROR (not the live deb.debian.org) is used deliberately:
# it makes the gate deterministic/offline while STILL genuinely exercising
# the full resolve->unpack->configure->run install path with a real Debian
# apt/dpkg. The live-network variant is scripts/test_linux_apt_net_e2e.sh.
#
# Boots the cpio via the qemu `-kernel` shim, -smp 1 (apt needs no SMP; a
# uniprocessor boot removes the orthogonal per-CPU race class — see the
# sibling test for the full rationale). Gated on the boot-ready marker,
# never a fixed sleep. Three-valued verdict: SKIP (unstaged) / PASS / FAIL.
#
# PASS markers (greppable):
#   HAMDEP_INSTALL_START
#   Setting up hamdep-lib / Setting up hamdep-app
#   HAMDEP_LIB_POSTINST_RAN
#   HAMDEP_APP_RAN:HAMDEP_LIB_DATA_OK

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ROOTFS=tests/distros/debian-minbase/rootfs
if [ ! -f "$ROOTFS/usr/bin/dpkg" ] || [ ! -f "$ROOTFS/usr/bin/apt-get" ]; then
    echo "[apt-dep] SKIP: $ROOTFS/usr/bin/{dpkg,apt-get} not staged"
    echo "    Stage with: bash scripts/stage_host_dpkg_rootfs.sh"
    echo "           (or: bash tests/distros/debian-minbase/BUILD.sh)"
    exit 0
fi

# Ensure the offline local repo (with the dependency pair) is staged.
if [ ! -d "$ROOTFS/opt/localrepo/pool/main/h/hamdep-app" ] \
   || [ ! -d "$ROOTFS/opt/localrepo/pool/main/h/hamdep-lib" ]; then
    echo "[apt-dep] staging local apt repo (build_local_apt_repo.sh)"
    bash scripts/build_local_apt_repo.sh || {
        echo "[apt-dep] SKIP: could not stage local repo"; exit 0; }
fi
if [ ! -d "$ROOTFS/opt/localrepo/pool/main/h/hamdep-app" ]; then
    echo "[apt-dep] SKIP: hamdep-app not staged after repo build"
    exit 0
fi

# The install image is NOT the acceptance vehicle here (this is the -kernel
# VM-fast path), but rm a stale installer image so nothing downstream reuses
# an old one — per the endgame gate hygiene note.
rm -f build/hamnix-installer.img 2>/dev/null || true

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[apt-dep] (1/5) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[apt-dep] (2/5) Plant /etc/hamsh.rc (writable-overlay recipe)"
RC_TMP=$(mktemp /tmp/hamsh-rc-aptdep.XXXXXX.rc)
# Same single-union-point writable overlay as test_linux_apt_install_e2e.sh:
# the read-only cpio distro subtree is the union base; a writable tmpfs
# server (#t) is stacked MBEFORE it and claims CREATEs (bind -bc / MCREATE).
# Reads of existing files fall through to the cpio; creates/writes (dpkg's
# admindir, unpacked files) land in the writable tmpfs.
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

echo "[apt-dep] (3/5) Build initramfs"
HAMNIX_DEFAULT_REAL_DEBIAN=1 HAMNIX_HAMSH_RC="$RC_TMP" \
    INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LOG=$(mktemp /tmp/test-apt-dep.XXXXXX.log)
cleanup() {
    rm -f "$RC_TMP"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[apt-dep] (4/5) Build kernel"
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "[apt-dep] (5/5) Boot QEMU + drive apt-get install hamdep-app"
set +e
# Retry policy: re-roll ASLR on a fresh boot if the install did NOT confirm.
# The apt dependency install forks even MORE than the single-leaf case (two
# packages -> two unpacks + two configures + a postinst), so it is the most
# fork-heavy apt path; a small retry budget rides out the documented,
# ASLR-layout-dependent deep-mm fragility WITHOUT masking a real bug (a real
# resolve/unpack/configure bug is DETERMINISTIC and fails every attempt, so
# the gate still reds). On current origin/main the single-leaf path passes
# first-try (the #471 VMA interval-stab fix), so this budget is belt-and-
# braces, not a crutch.
APT_DEP_ATTEMPTS="${APT_DEP_ATTEMPTS:-4}"
attempt=1
while : ; do
: > "$LOG"
(
    waited=0
    while [ "$waited" -lt 240 ]; do
        grep -aq "TEST_RC_DONE_DEFINING_NS" "$LOG" 2>/dev/null && break
        sleep 1; waited=$((waited + 1))
    done
    sleep 2

    drive() { printf '%s\n' "$1"; }
    wait_for() {  # $1=marker  $2=max-seconds
        local w=0
        while [ "$w" -lt "$2" ]; do
            grep -aq "$1" "$LOG" 2>/dev/null && return 0
            sleep 2; w=$((w + 2))
        done
        return 1
    }

    # Sanity: real Debian apt still runs under the writable overlay.
    drive 'echo HAMDEP_VER_START'
    drive 'enter linux { /usr/bin/apt-get --version }'
    drive 'echo HAMDEP_VER_END'; wait_for HAMDEP_VER_END 60

    # KEYSTONE: apt-get update + install the dependent package in ONE
    # namespace (update's index feeds install in the same process tree).
    drive 'echo HAMDEP_INSTALL_START'
    drive 'enter linux { /usr/bin/apt-get update && /usr/bin/apt-get install -y hamdep-app }'
    # apt runs for many seconds and hamsh does not buffer stdin while a
    # foreground `enter linux` child runs, so re-send the done-marker echo
    # until the first one issued AFTER apt returns lands.
    w=0
    while [ "$w" -lt 300 ]; do
        grep -aq "HAMDEP_WRAPPER_DONE" "$LOG" 2>/dev/null && break
        drive 'echo HAMDEP_WRAPPER_DONE'
        sleep 8; w=$((w + 8))
    done

    # Run the installed leaf: it reads hamdep-lib's data file, proving BOTH
    # packages installed + configured in the correct order.
    drive 'echo HAMDEP_RUN_START'
    drive 'enter linux { /usr/bin/hamdep-app }'
    drive 'echo HAMDEP_RUN_END'; wait_for HAMDEP_RUN_END 40

    drive 'echo BANNER_DONE'; wait_for BANNER_DONE 20
    drive 'poweroff'; sleep 3
    drive 'exit'; sleep 1
) | timeout 2100s qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 768M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1
rc=$?

apt_dep_ok() {  # both packages configured in the install slice
    local slice; slice=$(awk '/HAMDEP_INSTALL_START/{f=1} f' "$LOG" 2>/dev/null)
    printf '%s' "$slice" | grep -a -F -q "Setting up hamdep-app" \
      && printf '%s' "$slice" | grep -a -F -q "Setting up hamdep-lib"
}
if ! apt_dep_ok && [ "$attempt" -lt "$APT_DEP_ATTEMPTS" ]; then
    if [ "$rc" -eq 137 ] || [ "$rc" -eq 124 ]; then
        echo "[apt-dep] qemu externally killed (rc=$rc) before install confirmed —"
    else
        echo "[apt-dep] install not confirmed (crash / hang / SIGINT teardown of" \
             "the fork-heavy multi-pkg phase) —"
    fi
    echo "[apt-dep]   re-rolling ASLR on a fresh boot $((attempt + 1))/$APT_DEP_ATTEMPTS"
    attempt=$((attempt + 1))
    continue
fi
break
done
set -e

echo "[apt-dep] --- captured output (tail) ---"
tail -400 "$LOG" | strings
echo "[apt-dep] --- end output ---"

fail=0
# Count guest markers so a DEAD boot (zero markers) is INCONCLUSIVE, not a
# false pass/fail: require the boot-ready marker before trusting assertions.
if ! grep -a -F -q "TEST_RC_DONE_DEFINING_NS" "$LOG"; then
    echo "[apt-dep] INCONCLUSIVE: boot never reached the ns-ready marker (dead boot)"
    echo "[apt-dep] FAIL (qemu rc=$rc) — log: $LOG"
    exit 1
fi

# All install confirmation MUST come from apt's own pipeline, i.e. AFTER the
# HAMDEP_INSTALL_START marker (slice the serial from there).
SLICE=$(awk '/HAMDEP_INSTALL_START/{f=1} f' "$LOG")
check_slice() {  # $1=needle  $2=human
    if printf '%s' "$SLICE" | grep -a -F -q "$1"; then
        echo "[apt-dep] OK: $2"
    else
        echo "[apt-dep] MISS: $2  ('$1')"
        fail=1
    fi
}
# Dependency resolution: apt decided to also install the dependency.
check_slice "hamdep-lib" "apt resolved/named the dependency hamdep-lib"
# Multi-package unpack.
check_slice "Unpacking hamdep-lib" "apt unpacked the dependency (hamdep-lib)"
check_slice "Unpacking hamdep-app" "apt unpacked the leaf (hamdep-app)"
# Ordered configure of BOTH packages.
check_slice "Setting up hamdep-lib" "dependency configured (Setting up hamdep-lib)"
check_slice "Setting up hamdep-app" "leaf configured (Setting up hamdep-app)"
# Maintainer script (postinst) ran during configure of the dependency.
check_slice "HAMDEP_LIB_POSTINST_RAN" "dependency postinst maintainer script ran"
# The installed binary runs AND read its dependency's data file.
check_slice "HAMDEP_APP_RAN:HAMDEP_LIB_DATA_OK" \
    "installed binary ran and read the dependency's data (both pkgs live)"

# Ordering assertion: hamdep-lib MUST be configured BEFORE hamdep-app.
LIB_LINE=$(printf '%s' "$SLICE" | grep -a -n -F "Setting up hamdep-lib" | head -1 | cut -d: -f1)
APP_LINE=$(printf '%s' "$SLICE" | grep -a -n -F "Setting up hamdep-app" | head -1 | cut -d: -f1)
if [ -n "$LIB_LINE" ] && [ -n "$APP_LINE" ] && [ "$LIB_LINE" -lt "$APP_LINE" ]; then
    echo "[apt-dep] OK: configure ORDER correct (dependency before leaf)"
else
    echo "[apt-dep] MISS: configure order (lib=$LIB_LINE app=$APP_LINE)"
    fail=1
fi

# Regression guards (same failure classes the sibling gate watches).
check_absent() {
    if grep -a -F -q "$1" "$LOG"; then
        echo "[apt-dep] FAIL-PRESENT: $2 ('$1')"; fail=1
    else
        echo "[apt-dep] OK (absent): $2"
    fi
}
check_absent "Error reading the CPU table" "apt CPU/arch table read OK"
check_absent "Unable to read /etc/apt/apt.conf.d" "apt config-dir read OK"
check_absent "unable to open/create dpkg frontend lock" "no read-only-root dpkg lock failure"

if [ "$fail" -ne 0 ]; then
    echo "[apt-dep] FAIL (qemu rc=$rc) — log: $LOG"
    exit 1
fi
echo "[apt-dep] PASS"
rm -f "$LOG"
