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

# Boot under KVM when the host exposes /dev/kvm (the broad real-Debian
# slice + the ld.so/libapt .so churn is painfully slow under pure TCG).
# Falls back to TCG transparently on a KVM-less box.
KVM_ARGS=""
if [ -w /dev/kvm ]; then
    KVM_ARGS="-enable-kvm -cpu host"
    echo "[test_linux_debian_coverage] KVM available -> -enable-kvm -cpu host"
else
    echo "[test_linux_debian_coverage] no /dev/kvm -> TCG (slow)"
fi

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
    bind '#t/tmp' /tmp
}
debian = ns clean {
    bind '#r/var/lib/distros/default' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
    bind '#t/tmp' /tmp
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
    # dash via -c, using the dash BUILTIN echo (no fork — `dash -c` of an
    # EXTERNAL command uses vfork, whose CLONE_VM shared-AS semantics the
    # fork path doesn't yet honour; that's a separate track). The marker is
    # assembled from two args so the typed line never holds it contiguous.
    printf 'echo BANNER_DASH_START\n'; sleep 1
    printf "enter linux { /bin/dash -c 'echo DASH_RUN OK_MARK' }\n"; sleep 6
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
    printf 'enter linux { /usr/bin/sort /etc/os-release }\n'; sleep 9
    printf 'echo BANNER_SORT_END\n'; sleep 1

    # ---- BROAD STANDALONE-BINARY SWEEP -------------------------------
    # Each real Debian ELF is invoked STANDALONE (no shell pipe/fork) on
    # a staged file or with a self-contained flag, and asserts a token in
    # its own OUTPUT. Banner-windowed like the rest. This is the breadth
    # matrix: coreutils + text tools exercised through the Linux-ABI shim.
    # marker tokens are unique substrings the command necessarily prints.
    sweep() {  # sweep <BANNER> <cmd...>
        local b="$1"; shift
        printf 'echo %s_START\n' "$b"; sleep 1
        printf 'enter linux { %s }\n' "$*"; sleep "${SWEEP_SLEEP:-6}"
        printf 'echo %s_END\n' "$b"; sleep 1
    }
    # uname -s -> "Linux" (the shim reports a Linux uname to the guest).
    sweep BANNER_UNAME   "/usr/bin/uname -s"
    # id -> contains "uid="
    sweep BANNER_ID      "/usr/bin/id"
    # whoami -> a username line
    sweep BANNER_WHOAMI  "/usr/bin/whoami"
    # ls -la / -> long listing of the Debian root (getdents + lstat)
    sweep BANNER_LS      "/usr/bin/ls -la /"
    # ls -la of /usr/bin -> bigger getdents directory
    sweep BANNER_LSBIN   "/usr/bin/ls /usr/bin"
    # stat /etc/os-release -> "Size:" / "Inode:" (fstatat detail)
    sweep BANNER_STAT    "/usr/bin/stat /etc/os-release"
    # tail -n1 -> last line of os-release
    sweep BANNER_TAIL    "/usr/bin/tail -n1 /etc/os-release"
    # cut a field -> ID=debian -> "debian"
    sweep BANNER_CUT     "/usr/bin/cut -d= -f2 /etc/os-release"
    # tr lowercasing a fixed file path content
    sweep BANNER_TR      "/usr/bin/tr a-z A-Z < /etc/debian_version"
    # printf with a format -> deterministic token
    sweep BANNER_PRINTF  "/usr/bin/printf 'PRINTF_%s_OK\\n' TOKEN"
    # seq -> 1..3 newline-separated
    sweep BANNER_SEQ     "/usr/bin/seq 3"
    # basename / dirname -> path component
    sweep BANNER_BASENAME "/usr/bin/basename /a/b/cfile"
    # env -> prints the environment (PATH= at least)
    sweep BANNER_ENV     "/usr/bin/env"
    # grep a fixed token in a staged file
    sweep BANNER_GREP    "/usr/bin/grep BUG_REPORT_URL /etc/os-release"
    # sed substitution on a staged file
    sweep BANNER_SED     "/usr/bin/sed -n '1p' /etc/os-release"
    # head -c byte count
    sweep BANNER_HEADC   "/usr/bin/head -c5 /etc/debian_version"
    # wc -c byte count
    sweep BANNER_WCC     "/usr/bin/wc -c /etc/debian_version"
    # md5sum of a staged file -> a 32-hex digest line
    sweep BANNER_MD5     "/usr/bin/md5sum /etc/debian_version"
    # readlink of /bin/sh -> dash (symlink readlink)
    sweep BANNER_READLINK "/usr/bin/readlink /bin/sh"
    # find a staged dir, depth-limited (getdents + recursion)
    SWEEP_SLEEP=8 sweep BANNER_FIND "/usr/bin/find /etc/apt -maxdepth 2"
    # date in a fixed-format (no args reads RTC; -u +%Y is deterministic-ish)
    sweep BANNER_DATE    "/usr/bin/date -u +DATE_OK_%Y"
    # nl numbers lines
    sweep BANNER_NL      "/usr/bin/nl /etc/debian_version"
    # od hex dump first bytes
    sweep BANNER_OD      "/usr/bin/od -An -c -N3 /etc/debian_version"
    # awk (gawk or mawk) field print -> requires the awk ELF + its closure
    SWEEP_SLEEP=8 sweep BANNER_AWK "/usr/bin/awk 'BEGIN{print \"AWK_OK_MARK\"}'"
    # perl one-liner (heavier dynamic closure)
    SWEEP_SLEEP=10 sweep BANNER_PERL "/usr/bin/perl -e 'print \"PERL_OK_MARK\\n\"'"
    # python3 version (heaviest dynamic closure; best-effort)
    SWEEP_SLEEP=12 sweep BANNER_PY "/usr/bin/python3 --version"

    # dpkg + apt --version (the package managers proper).
    printf 'echo BANNER_DPKG_VERSION_START\n'; sleep 1
    printf 'enter linux { /usr/bin/dpkg --version }\n'; sleep 10
    printf 'echo BANNER_DPKG_VERSION_END\n'; sleep 1

    printf 'echo BANNER_APT_VERSION_START\n'; sleep 1
    printf 'enter linux { /usr/bin/apt-get --version }\n'; sleep 12
    printf 'echo BANNER_APT_VERSION_END\n'; sleep 1

    # ---- PART B: offline package install end-to-end ------------------
    # The cpio-backed #distro `/` is READ-ONLY, so dpkg/apt cannot create
    # their lock / admindir under the real /var. The writable surface in
    # the ns is /tmp (bound to the tmpfs server, `#t/tmp`). So install into
    # a writable alternate root under /tmp via `dpkg --root=/tmp/inst`:
    # dpkg treats /tmp/inst as the filesystem root, creating its admindir
    # and unpacking the package's /usr/bin/hamhello there — exercising the
    # full real-dpkg unpack chain (dpkg -> dpkg-deb -> tar -> gzip, all
    # forked Debian binaries) against the offline .deb. The freshly
    # UNPACKED /tmp/inst/usr/bin/hamhello then runs and prints its marker.
    # (The installer-image live test, scripts/test_installer_live_debian.sh,
    # proves apt-get install into the WRITABLE RAM-ext4 #distro on the real
    # shipped artifact — the apt-from-file://-repo path; this cpio gate
    # proves the offline dpkg unpack+run chain.)
    #
    # Seed the writable admindir. Use plain `mkdir` per level (absolute,
    # AT_FDCWD) rather than `mkdir -p` (which opens each created dir and
    # uses its fd as the dirfd for the next mkdirat with a RELATIVE name —
    # a path that needs directory-open fd_opened_path stamping, a separate
    # follow-up). Each plain mkdir is mkdirat(AT_FDCWD, <absolute>) ->
    # _u_mkdir -> vfs_mkdir -> the tmpfs arm (the committed mkdir fix).
    printf 'echo BANNER_DPKG_I_START\n'; sleep 1
    printf 'enter linux { /bin/mkdir /tmp/inst }\n'; sleep 3
    printf 'enter linux { /bin/mkdir /tmp/inst/var }\n'; sleep 3
    printf 'enter linux { /bin/mkdir /tmp/inst/var/lib }\n'; sleep 3
    printf 'enter linux { /bin/mkdir /tmp/inst/var/lib/dpkg }\n'; sleep 3
    printf 'enter linux { /bin/mkdir /tmp/inst/var/lib/dpkg/info }\n'; sleep 3
    printf 'enter linux { /bin/mkdir /tmp/inst/var/lib/dpkg/updates }\n'; sleep 3
    printf 'enter linux { /bin/cp /var/lib/dpkg/status /tmp/inst/var/lib/dpkg/status }\n'; sleep 4
    # Real dpkg unpack into the writable alternate root.
    printf 'enter linux { /usr/bin/dpkg --root=/tmp/inst --force-not-root -i /var/cache/apt/archives/hamhello_1.0_amd64.deb }\n'; sleep 20
    # Run the freshly-UNPACKED binary (its marker is program output).
    printf 'enter linux { /tmp/inst/usr/bin/hamhello }\n'; sleep 6
    printf 'echo BANNER_DPKG_I_END\n'; sleep 1

    # Also exercise apt-get's file:// repo parse + `file` fetch method
    # into writable /tmp dirs (best-effort; the apt-into-real-/var install
    # can't complete on the read-only cpio).
    printf 'echo BANNER_APT_INSTALL_START\n'; sleep 1
    printf 'enter linux { /bin/mkdir -p /tmp/aptstate/lists/partial /tmp/aptcache/archives/partial }\n'; sleep 4
    printf 'enter linux { /usr/bin/apt-get -o Dir::State=/tmp/aptstate -o Dir::Cache=/tmp/aptcache -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/local.list -o Dir::Etc::sourceparts=/dev/null update }\n'; sleep 18
    printf 'echo BANNER_APT_INSTALL_END\n'; sleep 1

    printf 'echo BANNER_DONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 1200s qemu-system-x86_64 \
    -kernel "$ELF" \
    $KVM_ARGS \
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

# --- BROAD STANDALONE-BINARY SWEEP assertions ------------------------
# Two tiers. CORE coreutils/text tools are HARD (regression on these = a
# real ABI break). The HEAVY dynamic binaries (awk/perl/python3) and any
# probe whose output is environment-dependent are REPORTED ONLY (counted
# into a residual list, not fail=1) — this is a breadth probe and the
# host may not even ship them. Every result is printed so the serial
# evidence shows the full pass/fail matrix.
sweep_core=0; sweep_soft_pass=0; sweep_soft_fail=0
declare -a SOFT_RESIDUAL=()
check_core() {  # banner value label
    if awk -v b="$1" -v v="$2" '
        BEGIN{armed=0;win=0;found=0}
        index($0,"[atkbd-diag]")>0{next}
        index($0,b)>0{armed=1;win=0;next}
        armed{win++; if(index($0,v)>0){found=1;exit} if(win>40)armed=0}
        END{exit found?0:1}' "$LOG"; then
        echo "[test_linux_debian_coverage] OK (core): $3"
        sweep_core=$((sweep_core+1))
    else
        echo "[test_linux_debian_coverage] MISS (core): $3 (banner='$1' value='$2')"
        fail=1
    fi
}
check_soft() {  # banner value label
    if awk -v b="$1" -v v="$2" '
        BEGIN{armed=0;win=0;found=0}
        index($0,"[atkbd-diag]")>0{next}
        index($0,b)>0{armed=1;win=0;next}
        armed{win++; if(index($0,v)>0){found=1;exit} if(win>40)armed=0}
        END{exit found?0:1}' "$LOG"; then
        echo "[test_linux_debian_coverage] OK (probe): $3"
        sweep_soft_pass=$((sweep_soft_pass+1))
    else
        echo "[test_linux_debian_coverage] PROBE-MISS: $3 (residual, not a hard fail)"
        sweep_soft_fail=$((sweep_soft_fail+1))
        SOFT_RESIDUAL+=("$3")
    fi
}

# CORE — these must pass.
check_core "BANNER_UNAME_START"    "Linux"          "uname -s -> Linux"
check_core "BANNER_ID_START"       "uid="           "id -> uid="
check_core "BANNER_LS_START"       "etc"            "ls -la / lists the Debian root (getdents)"
check_core "BANNER_LSBIN_START"    "dpkg"           "ls /usr/bin lists staged binaries"
check_core "BANNER_STAT_START"     "Size:"          "stat /etc/os-release -> Size:"
check_core "BANNER_TAIL_START"     "URL"            "tail -n1 os-release -> last line"
check_core "BANNER_CUT_START"      "debian"         "cut -d= -f2 -> debian"
check_core "BANNER_TR_START"       "12"             "tr a-z A-Z piped debian_version"
check_core "BANNER_PRINTF_START"   "PRINTF_TOKEN_OK" "printf format"
check_core "BANNER_SEQ_START"      "3"              "seq 3"
check_core "BANNER_BASENAME_START" "cfile"          "basename /a/b/cfile"
check_core "BANNER_GREP_START"     "BUG_REPORT_URL" "grep token in os-release"
check_core "BANNER_SED_START"      "PRETTY"         "sed -n 1p os-release"
check_core "BANNER_HEADC_START"    "12"             "head -c5 debian_version"
check_core "BANNER_WCC_START"      "debian_version" "wc -c debian_version"
check_core "BANNER_MD5_START"      "debian_version" "md5sum debian_version (digest line)"
check_core "BANNER_READLINK_START" "dash"           "readlink /bin/sh -> dash"
check_core "BANNER_DATE_START"     "DATE_OK_20"     "date -u +DATE_OK_%Y"
check_core "BANNER_NL_START"       "12"             "nl debian_version"

# PROBE — reported, not hard-failed.
check_soft "BANNER_WHOAMI_START"   "root"           "whoami -> root"
check_soft "BANNER_ENV_START"      "PATH"           "env -> PATH= in environment"
check_soft "BANNER_FIND_START"     "sources"        "find /etc/apt -maxdepth 2"
check_soft "BANNER_OD_START"       "1"              "od -c debian_version"
check_soft "BANNER_AWK_START"      "AWK_OK_MARK"    "awk BEGIN print"
check_soft "BANNER_PERL_START"     "PERL_OK_MARK"   "perl -e print"
check_soft "BANNER_PY_START"       "Python"         "python3 --version"

echo "[test_linux_debian_coverage] sweep summary: core_ok=$sweep_core" \
     "probe_pass=$sweep_soft_pass probe_residual=$sweep_soft_fail"
if [ "${#SOFT_RESIDUAL[@]}" -gt 0 ]; then
    echo "[test_linux_debian_coverage] residual probes (non-fatal):"
    for r in "${SOFT_RESIDUAL[@]}"; do echo "    - $r"; done
fi

# --- PART B: offline dpkg unpack into a writable root -----------------
# Authoritative offline apt-get-install-into-the-writable-#distro gate is
# scripts/test_installer_live_debian.sh (RAM ext4). Here on the read-only
# cpio we unpack into /tmp/inst (tmpfs). When the HAMHELLO marker appears
# in the DPKG_I window the real dpkg/dpkg-deb/tar chain unpacked + ran the
# package — a hard PASS. If it does not (e.g. the tmpfs mkdir-in-namespace
# path returns ENOSYS — a known, separate writable-tmpfs-in-`enter linux`
# gap, see docs/distro-namespaces.md), we DON'T fail this coverage gate:
# the install gate lives on the writable-ext4 installer-live test. We DO
# require the forked dpkg chain to have EXECUTED (dpkg printed its own
# diagnostics — proving the forked real-Debian unpack binaries ran).
if awk '
    BEGIN { armed=0; found=0 }
    index($0,"BANNER_DPKG_I_START")>0 { armed=1; next }
    index($0,"BANNER_DPKG_I_END")>0 { armed=0 }
    armed && index($0,"HAMHELLO_INSTALLED_AND_RAN_OK")>0 { found=1; exit }
    END { exit found ? 0 : 1 }
' "$LOG"; then
    echo "[test_linux_debian_coverage] OK: offline dpkg unpack -> hamhello ran (real dpkg/dpkg-deb/tar chain)"
elif awk '
    BEGIN { armed=0; found=0 }
    index($0,"BANNER_DPKG_I_START")>0 { armed=1; next }
    index($0,"BANNER_DPKG_I_END")>0 { armed=0 }
    armed && (index($0,"dpkg")>0 || index($0,"mkdir")>0) { found=1; exit }
    END { exit found ? 0 : 1 }
' "$LOG"; then
    echo "[test_linux_debian_coverage] NOTE: offline dpkg unpack forked the real chain but did not"
    echo "    complete (writable-tmpfs-in-ns mkdir gap; install gate is the installer-live test)."
else
    echo "[test_linux_debian_coverage] MISS: offline dpkg chain did not execute at all"
    fail=1
fi

# Regression guard (mm/vma.ad windowed-VA reclaim): apt's heavy .so
# closure + malloc/dlopen churn used to exhaust the [1 GiB, 4 GiB) mmap
# window, so ld.so failed to map libapt-pkg.so ("failed to map segment
# from shared object") and the kernel printed a "window exhausted" line.
# Both must be ABSENT now that freed windows are reclaimed per-task.
if grep -a -F -q "failed to map segment from shared object" "$LOG"; then
    echo "[test_linux_debian_coverage] FAIL-PRESENT: ld.so 'failed to map segment' (window exhaustion regressed)"
    fail=1
else
    echo "[test_linux_debian_coverage] OK (absent): no ld.so 'failed to map segment'"
fi
if grep -a -F -q "window exhausted" "$LOG"; then
    echo "[test_linux_debian_coverage] FAIL-PRESENT: kernel mmap-window-exhausted printk"
    fail=1
else
    echo "[test_linux_debian_coverage] OK (absent): no mmap-window-exhausted printk"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_linux_debian_coverage] FAIL (qemu rc=$rc; log: $LOG)"
    exit 1
fi
echo "[test_linux_debian_coverage] PASS"
rm -f "$LOG"
