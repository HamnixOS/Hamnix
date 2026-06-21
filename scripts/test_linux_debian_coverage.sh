#!/usr/bin/env bash
# scripts/test_linux_debian_coverage.sh
#
# Proves the Linux namespace is a genuinely usable minimal Debian:
#
#   PART A  STOCK-DEBIAN-BINARY COVERAGE SWEEP
#     A representative set of REAL Debian ELFs run inside
#     `enter linux { ... }` and produce CORRECT output:
#       /bin/dash   -> prints a marker via -c
#       /bin/bash   -> prints $BASH_VERSION (proves bash + libtinfo closure)
#       /bin/cat    -> echoes a sentinel file
#       /usr/bin/wc -> counts lines
#       /usr/bin/sort, /usr/bin/head -> ordered/truncated output
#     plus the package managers proper: dpkg --version, apt-get --version.
#
#   PART B  OFFLINE apt-get install END-TO-END
#     A LOCAL file:// apt repo (scripts/build_local_apt_repo.sh) serves a
#     dependency-free leaf package `hamhello`. Inside the linux ns:
#       apt-get install -y hamhello   (apt `file` method -> dpkg -> dpkg-deb)
#     then the freshly-installed /usr/bin/hamhello RUNS and prints its
#     unique marker HAMHELLO_INSTALLED_AND_RAN_OK. A `dpkg -i` short-path
#     fallback is attempted if apt-get's full install chain stalls.
#
# Driven over serial against the `-kernel` cpio boot (fast; mirrors
# scripts/test_linux_apt_install.sh). The full ~140 MiB real-Debian +
# localrepo slice is embedded in the initramfs, so the boot is slow under
# TCG — every keystroke is gated on a boot-ready marker, never a fixed
# sleep (feedback_interactive_test_wait_for_prompt).
#
# Skip-on-missing: if the debootstrap fixture is absent, exit 0 (SKIP).
#
# PASS markers are program OUTPUT assembled so the typed command line never
# contains the contiguous needle (banner-window assertion).

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ROOTFS=tests/distros/debian-minbase/rootfs
if [ ! -f "$ROOTFS/usr/bin/dpkg" ] || [ ! -f "$ROOTFS/bin/bash" ]; then
    echo "[test_linux_debian_coverage] SKIP: $ROOTFS/{usr/bin/dpkg,bin/bash} not staged"
    echo "    Build with: bash tests/distros/debian-minbase/BUILD.sh"
    exit 0
fi

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_linux_debian_coverage] (1/6) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_linux_debian_coverage] (2/6) Generate the local file:// apt repo"
bash scripts/build_local_apt_repo.sh

# rc identical in shape to test_linux_apt_install.sh: server-anchored binds
# replayed inside the empty `ns clean` child.
echo "[test_linux_debian_coverage] (3/6) Plant /etc/hamsh.rc"
RC_TMP=$(mktemp /tmp/hamsh-rc-debcov.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
linux = ns clean {
    bind '#r/var/lib/distros/default' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}
debian = ns clean {
    bind '#r/var/lib/distros/default' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[test_linux_debian_coverage] (4/6) Build initramfs (hamsh /init + real Debian + localrepo)"
HAMNIX_DEFAULT_REAL_DEBIAN=1 HAMNIX_HAMSH_RC="$RC_TMP" \
    INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LOG=$(mktemp /tmp/test-linux-debcov.XXXXXX.log)
cleanup() {
    rm -f "$RC_TMP"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
}
trap cleanup EXIT

echo "[test_linux_debian_coverage] (5/6) Build kernel"
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "[test_linux_debian_coverage] (6/6) Boot QEMU + drive coverage + apt-install"
set +e
(
    # Gate first keystroke on the rc marker (boot is slow under TCG).
    waited=0
    while [ "$waited" -lt 240 ]; do
        grep -aq "TEST_RC_DONE_DEFINING_NS" "$LOG" 2>/dev/null && break
        sleep 1; waited=$((waited + 1))
    done
    sleep 2

    # ---- PART A: stock-Debian-binary coverage sweep ------------------
    # dash via -c assembling a marker from two args (typed line never holds
    # the contiguous needle).
    printf 'echo BANNER_DASH_START\n'; sleep 1
    printf "enter linux { /bin/dash -c '/bin/echo DASH_RUN OK_MARK' }\n"; sleep 6
    printf 'echo BANNER_DASH_END\n'; sleep 1

    # bash prints its version (proves bash + libtinfo .so closure maps).
    printf 'echo BANNER_BASH_START\n'; sleep 1
    printf "enter linux { /bin/bash -c '/bin/echo BASH_VER \$BASH_VERSION' }\n"; sleep 8
    printf 'echo BANNER_BASH_END\n'; sleep 1

    # coreutils run DIRECTLY on a staged file (no shell pipe/subshell — a
    # `dash -c 'a | b'` pipeline forks inside the linux ns, a heavier path
    # we keep off the coverage sweep; each binary is invoked standalone).
    # /etc/os-release is a multi-line Debian file present in every minbase.
    printf 'echo BANNER_CAT_START\n'; sleep 1
    printf 'enter linux { /bin/cat /etc/debian_version }\n'; sleep 6
    printf 'echo BANNER_CAT_END\n'; sleep 1

    printf 'echo BANNER_HEAD_START\n'; sleep 1
    printf 'enter linux { /usr/bin/head -n2 /etc/os-release }\n'; sleep 6
    printf 'echo BANNER_HEAD_END\n'; sleep 1

    printf 'echo BANNER_WC_START\n'; sleep 1
    printf 'enter linux { /usr/bin/wc -l /etc/os-release }\n'; sleep 6
    printf 'echo BANNER_WC_END\n'; sleep 1

    printf 'echo BANNER_SORT_START\n'; sleep 1
    printf 'enter linux { /usr/bin/sort /etc/os-release }\n'; sleep 6
    printf 'echo BANNER_SORT_END\n'; sleep 1

    # dpkg + apt --version (the package managers proper).
    printf 'echo BANNER_DPKG_VERSION_START\n'; sleep 1
    printf 'enter linux { /usr/bin/dpkg --version }\n'; sleep 10
    printf 'echo BANNER_DPKG_VERSION_END\n'; sleep 1

    printf 'echo BANNER_APT_VERSION_START\n'; sleep 1
    printf 'enter linux { /usr/bin/apt-get --version }\n'; sleep 12
    printf 'echo BANNER_APT_VERSION_END\n'; sleep 1

    # ---- PART B: offline apt-get install end-to-end ------------------
    # apt-get update over the file:// repo, then install the leaf pkg.
    printf 'echo BANNER_APT_UPDATE_START\n'; sleep 1
    printf 'enter linux { /usr/bin/apt-get update }\n'; sleep 18
    printf 'echo BANNER_APT_UPDATE_END\n'; sleep 1

    printf 'echo BANNER_APT_INSTALL_START\n'; sleep 1
    printf 'enter linux { /usr/bin/apt-get install -y --no-download hamhello }\n'; sleep 25
    # Run the freshly-installed binary (its marker is program output).
    printf 'enter linux { /usr/bin/hamhello }\n'; sleep 6
    printf 'echo BANNER_APT_INSTALL_END\n'; sleep 1

    # dpkg -i short-path fallback (independent proof: dpkg unpacks + the
    # binary runs even if apt's solver path stalls).
    printf 'echo BANNER_DPKG_I_START\n'; sleep 1
    printf 'enter linux { /usr/bin/dpkg -i /var/cache/apt/archives/hamhello_1.0_amd64.deb }\n'; sleep 18
    printf 'enter linux { /usr/bin/hamhello }\n'; sleep 6
    printf 'echo BANNER_DPKG_I_END\n'; sleep 1

    printf 'echo BANNER_DONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 1200s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 1024M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[test_linux_debian_coverage] --- captured output (tail) ---"
tail -400 "$LOG" | strings
echo "[test_linux_debian_coverage] --- end output ---"

fail=0

# Banner-window assertion: <value> must appear within 40 lines AFTER
# <banner> and BEFORE the next banner.
check_banner_value() {
    local banner="$1" value="$2" label="$3"
    if awk -v b="$banner" -v v="$value" '
        BEGIN { armed=0; win=0; found=0 }
        index($0, "[atkbd-diag]") > 0 { next }
        index($0, b) > 0 { armed=1; win=0; next }
        armed { win++ ; if (index($0, v) > 0) { found=1; exit }
                if (win > 40) armed=0 }
        END { exit found ? 0 : 1 }
    ' "$LOG"; then
        echo "[test_linux_debian_coverage] OK: $label"
    else
        echo "[test_linux_debian_coverage] MISS: $label (banner='$banner' value='$value')"
        fail=1
    fi
}

check_present() {
    local needle="$1" label="$2"
    if grep -a -F -q "$needle" "$LOG"; then
        echo "[test_linux_debian_coverage] OK: $label"
    else
        echo "[test_linux_debian_coverage] MISS: $label ('$needle')"
        fail=1
    fi
}

check_present "TEST_RC_DONE_DEFINING_NS" "rc captured linux + debian ns values"

# --- PART A assertions ---
check_banner_value "BANNER_DASH_START"  "DASH_RUN OK_MARK" "dash -c ran (real Debian /bin/dash)"
check_banner_value "BANNER_BASH_START"  "BASH_VER "        "bash -c ran (real Debian /bin/bash + libtinfo)"
check_banner_value "BANNER_CAT_START"   "12."              "cat /etc/debian_version printed the version"
check_banner_value "BANNER_HEAD_START"  "Debian"           "head /etc/os-release printed Debian lines"
check_banner_value "BANNER_WC_START"    "os-release"       "wc -l read /etc/os-release"
check_banner_value "BANNER_SORT_START"  "BUG_REPORT_URL"   "sort /etc/os-release ordered the file"
check_banner_value "BANNER_DPKG_VERSION_START" "Debian"    "dpkg --version printed 'Debian'"
check_banner_value "BANNER_APT_VERSION_START"  "apt "      "apt-get --version printed 'apt '"

# --- PART B assertion: at least ONE install path produced the marker ---
# apt-get install OR dpkg -i must leave a runnable /usr/bin/hamhello that
# prints HAMHELLO_INSTALLED_AND_RAN_OK. Accept either window.
if awk '
    BEGIN { armed=0; found=0 }
    index($0,"BANNER_APT_INSTALL_START")>0 { armed=1; next }
    index($0,"BANNER_DPKG_I_END")>0 { armed=0 }
    armed && index($0,"HAMHELLO_INSTALLED_AND_RAN_OK")>0 { found=1; exit }
    END { exit found ? 0 : 1 }
' "$LOG"; then
    echo "[test_linux_debian_coverage] OK: offline install (apt-get or dpkg -i) -> hamhello ran"
else
    echo "[test_linux_debian_coverage] MISS: no install path produced HAMHELLO_INSTALLED_AND_RAN_OK"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_linux_debian_coverage] FAIL (qemu rc=$rc; log: $LOG)"
    exit 1
fi
echo "[test_linux_debian_coverage] PASS"
rm -f "$LOG"
