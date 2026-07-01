#!/usr/bin/env bash
# scripts/test_installer_wizard.sh
#
# FAST regression guard (no VM / KVM) for the Debian-installer-style
# MULTI-PAGE WIZARD and its provisioning wiring:
#
#   1. user/haminstallui.ad (the wizard UI) and user/install.ad (the
#      installer it drives) COMPILE clean to user ELFs.
#   2. The wizard is genuinely MULTI-PAGE with Back/Next navigation and
#      collects: host name, install username, install-user password
#      (with confirm), and host-owner password (with confirm).
#   3. The wizard ships a PARTITION MANAGER page with guided-whole-disk
#      (default) + manual layout choices, over the disk picker.
#   4. The wizard passes EVERY collected value to `/bin/install` as a
#      flag (host name + user + both passwords + partition mode).
#   5. install.ad parses those flags and PROVISIONS the installed target:
#      it composes /etc/passwd + /etc/shadow (via sha512_crypt) +
#      /etc/hostname and writes them onto the TARGET partition through
#      the `install_file` ctl verb.
#   6. The unattended `install --auto` path is preserved: provisioning is
#      GATED on a flag being supplied, so the auto path (which the
#      test_installer_nvme_inram / build_installed_nvme harnesses drive
#      with no provisioning flags) reproduces today's behavior.
#
# These are the load-bearing invariants a later refactor could silently
# break. The heavy end-to-end proof is scripts/test_installer_nvme_inram.sh
# (OVMF boot); this is the cheap always-runs companion.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0
passed() { echo "[installer_wizard] PASS $*"; }
failed() { echo "[installer_wizard] FAIL $*" >&2; fail=1; }

UI="user/haminstallui.ad"
INST="user/install.ad"

# --- 1. Both compile clean -------------------------------------------
compile_one() {
    local name="$1" src="$2" out
    out="$(mktemp --tmpdir "hamnix-${name}.XXXXXX.elf")"
    if python3 -m compiler.adder compile --target=x86_64-adder-user \
            "$src" -o "$out" >"/tmp/installer_wizard.$name.log" 2>&1; then
        if file "$out" | grep -q ELF; then
            passed "$name compiles to an ELF"
        else
            failed "$name produced no ELF"
        fi
    else
        failed "$name did NOT compile (see /tmp/installer_wizard.$name.log)"
        tail -8 "/tmp/installer_wizard.$name.log" >&2 || true
    fi
    rm -f "$out"
}
compile_one haminstallui "$UI"
compile_one install "$INST"

want() {   # want <file> <regex> <label>
    if grep -Eq "$2" "$1"; then passed "$3"; else failed "$3 (missing: $2)"; fi
}

# --- 2. Multi-page wizard: pages + Back/Next + confirm ---------------
want "$UI" 'PAGE_HOST' "wizard: host-name page"
want "$UI" 'PAGE_USER' "wizard: username page"
want "$UI" 'PAGE_UPASS' "wizard: user-password page"
want "$UI" 'PAGE_RPASS' "wizard: hostowner-password page"
want "$UI" 'PAGE_SUMMARY' "wizard: review/summary page"
want "$UI" 'def _goto_next|def _goto_back' "wizard: Back/Next navigation"
want "$UI" 'Confirm password' "wizard: password confirmation field"
want "$UI" 'upass2_buf|rpass2_buf' "wizard: password-confirm buffers"

# --- 3. Partition manager: guided (default) + manual -----------------
want "$UI" 'PAGE_DISK' "wizard: partition-manager page"
want "$UI" 'Guided - use entire disk' "partition: guided-whole-disk option"
want "$UI" 'Manual' "partition: manual option"
want "$UI" 'part_mode' "partition: guided/manual mode state"

# --- 4. Wizard passes every value to /bin/install --------------------
want "$UI" '\-\-hostname' "wizard passes --hostname"
want "$UI" '\-\-user\b' "wizard passes --user"
want "$UI" '\-\-user-pass' "wizard passes --user-pass"
want "$UI" '\-\-root-pass' "wizard passes --root-pass"
want "$UI" '\-\-part-mode' "wizard passes --part-mode"

# --- 5. install.ad parses the flags + provisions the target ----------
want "$INST" '"--hostname"' "install parses --hostname"
want "$INST" '"--user"' "install parses --user"
want "$INST" '"--user-pass"' "install parses --user-pass"
want "$INST" '"--root-pass"' "install parses --root-pass"
want "$INST" '"--part-mode"' "install parses --part-mode"
want "$INST" 'from lib.crypt.sha512_crypt import sha512_crypt' \
     "install imports sha512_crypt for shadow hashing"
want "$INST" 'def provision_target' "install has target-provisioning path"
want "$INST" 'etc/passwd' "provision writes /etc/passwd onto target"
want "$INST" 'etc/shadow' "provision writes /etc/shadow onto target"
want "$INST" 'etc/hostname' "provision writes /etc/hostname onto target"
want "$INST" 'install_file' "provision uses the install_file ctl verb"

# --- 6. Auto path preserved: provisioning is GATED -------------------
# provision_target must run ONLY when a provisioning flag was supplied,
# so `install --auto` (no flags) reproduces today's byte-for-byte output.
if grep -Eq 'if have_hostname != 0 or have_user != 0 or have_user_pass != 0' "$INST"; then
    passed "provisioning is gated on a flag (auto path unchanged)"
else
    failed "provisioning gate absent — auto path could regress"
fi
# The unattended driver still calls install --auto with no provisioning
# flags (defaults reproduce today's behavior).
if grep -q 'install --auto --esp-mb 64 --repo file:///iso-packages' etc/install_nvme.hamsh; then
    passed "unattended install_nvme.hamsh drives the auto path (no wizard flags)"
else
    failed "install_nvme.hamsh auto invocation changed"
fi

if [ "$fail" -ne 0 ]; then
    echo "[installer_wizard] RESULT: FAIL" >&2
    exit 1
fi
echo "[installer_wizard] RESULT: ALL PASS"
exit 0
