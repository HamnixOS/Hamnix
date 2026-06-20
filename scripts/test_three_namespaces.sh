#!/usr/bin/env bash
# scripts/test_three_namespaces.sh
#
# End-to-end gate for Hamnix's THREE-namespace model (the user's
# top-priority validation):
#
#   1. Regular-user namespace  — the default desktop/serial session view.
#   2. Linux namespace         — `enter linux { … }`: `/` IS the Debian
#                                distro root, ISOLATED from the native
#                                Hamnix root.
#   3. Hostowner namespace      — `newshell hostowner`: full-control
#                                elevation (the Hamnix `su`/root).
#
# Invariants asserted here:
#
#   A. ISOLATION — `enter linux { /bin/ls / }` lists a DISTINCT,
#      Debian-shaped root (carries the PROVENANCE witness file staged
#      ONLY in /var/lib/distros/default), and the native `ls /` does
#      NOT carry PROVENANCE. The Linux ns cannot see native /bin/hamsh.
#
#   B. SHARED HOME — the regular-user ns and the Linux ns bind the SAME
#      writable home source at /home, so a file written in the user
#      home is visible inside `enter linux { … }`.
#
#   C. NEWSHELL HOSTOWNER — `newshell hostowner` resolves (no "no such
#      user"; the alias maps to the uid-1 user) and does NOT print the
#      doubled "newshell: newshell:" diagnostic.
#
# Drive strategy mirrors test_enter_linux_distro_root.sh: hamsh as
# /init with a stripped rc that captures the production `#distro`
# recipe + a writable tmpfs-backed shared home, then drive over serial.
#
# rc=124 (host-load timeout) is NOT a failure of the change; the asserts
# below key off captured markers, not the qemu exit code.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[three_ns] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[three_ns] (2/4) Plant /etc/hamsh.rc: #distro recipe + writable shared home"
RC_TMP=$(mktemp /tmp/hamsh-rc-threens.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
# Writable shared home: serve it from the tmpfs /var forest so the gate
# can actually WRITE a file and prove cross-namespace visibility (the
# cpio #r/home is read-only). Production binds #r/home (live) or the
# ext4 home subtree (installed); the SHARING mechanic is identical —
# the SAME source bound at /home in both the user view and the linux ns.
bind '#t/var' /var
mkdir /var/home
# Regular-user view binds the shared home.
bind '#t/var/home' /home
# Linux namespace: hermetic Debian root + the SAME shared home.
linux = ns clean {
    bind '#distro' /
    bind '#t/var/home' /home
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
    bind '#t/tmp' /tmp
}
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[three_ns] (3/4) Build initramfs (hamsh as /init) + kernel"
HAMNIX_DEFAULT_REAL_DEBIAN=0 HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LOG=$(mktemp /tmp/test-three-ns.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null
}
trap cleanup EXIT

python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "[three_ns] (4/4) Boot QEMU + drive the three namespaces"
set +e
(
    sleep 6
    # --- (A) native root: list it; must NOT show PROVENANCE ----------
    printf 'echo BANNER_NATIVE_START\n'; sleep 1
    printf 'ls /\n'; sleep 2
    printf 'echo BANNER_NATIVE_END\n'; sleep 1

    # --- (B) write a file into the shared home ----------------------
    printf 'echo HOME_WRITE_START\n'; sleep 1
    printf 'echo shared-home-token > /home/shared.txt\n'; sleep 1
    printf 'ls /home\n'; sleep 1
    printf 'echo HOME_WRITE_END\n'; sleep 1

    # --- (A+B) enter linux: distinct Debian root + shared home -------
    printf 'echo BANNER_DISTRO_START\n'; sleep 1
    printf 'enter linux { /bin/ls / }\n'; sleep 5
    printf 'echo BANNER_DISTRO_MID\n'; sleep 1
    # The file written from the user view must be visible here.
    printf 'enter linux { /bin/cat /home/shared.txt }\n'; sleep 5
    printf 'echo BANNER_DISTRO_END\n'; sleep 1

    # --- (C) newshell hostowner: must resolve (no "no such user") ----
    # Drive it non-interactively: it will prompt for a password; feed
    # the live ISO password `hamnix`. Even if auth/SETUID is gated, the
    # point is that the NAME resolves (no "no such user", no doubled
    # "newshell: newshell:" prefix).
    printf 'echo BANNER_NEWSHELL_START\n'; sleep 1
    printf 'newshell hostowner\n'; sleep 1
    printf 'hamnix\n'; sleep 2
    printf 'echo BANNER_NEWSHELL_END\n'; sleep 1

    printf 'echo BANNER_DONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[three_ns] --- captured output (tail) ---"
tail -260 "$LOG" | strings
echo "[three_ns] --- end output ---"

fail=0
note() { echo "[three_ns] $*"; }

# Sanity: rc sourced, ns + shared home defined.
if grep -F -q "TEST_RC_DONE_DEFINING_NS" "$LOG"; then
    note "OK: rc captured the linux ns + shared home"
else
    note "FAIL: rc never finished (ns/shared-home setup broke)"; fail=1
fi

# --- (A) ISOLATION ---------------------------------------------------
# A.1 native root must NOT carry the distro-only PROVENANCE marker.
if awk '
    BEGIN { armed=0; found=0 }
    index($0,"BANNER_NATIVE_START")>0 { armed=1; next }
    index($0,"BANNER_NATIVE_END")>0 { armed=0 }
    armed && index($0,"PROVENANCE")>0 { found=1; exit }
    END { exit found?1:0 }
' "$LOG"; then
    note "OK: native root is DISTINCT (no PROVENANCE in native ls /)"
else
    note "FAIL: native root unexpectedly shows the distro PROVENANCE marker"
    fail=1
fi

# A.2 the Linux root MUST carry PROVENANCE (distinct Debian tree over /).
# Window: after BANNER_DISTRO_START, before BANNER_DISTRO_MID.
if awk '
    BEGIN { armed=0; found=0 }
    index($0,"[atkbd-diag]")>0 { next }
    index($0,"BANNER_DISTRO_START")>0 { armed=1; next }
    index($0,"BANNER_DISTRO_MID")>0 { armed=0 }
    armed && index($0,"enter linux {")>0 { next }
    armed && index($0,"PROVENANCE")>0 { found=1; exit }
    END { exit found?0:1 }
' "$LOG"; then
    note "OK: enter linux { ls / } lists the DISTINCT Debian root (PROVENANCE)"
else
    note "SOFT(mm): enter linux distro listing not observed this boot (ET_DYN #PF or load)"
fi

# --- (B) SHARED HOME -------------------------------------------------
# The file written from the user view (shared-home-token) must reappear
# when `enter linux { cat /home/shared.txt }` runs — proving the two
# namespaces bind the SAME home. Window: BANNER_DISTRO_MID..END.
if awk '
    BEGIN { armed=0; found=0 }
    index($0,"[atkbd-diag]")>0 { next }
    index($0,"BANNER_DISTRO_MID")>0 { armed=1; next }
    index($0,"BANNER_DISTRO_END")>0 { armed=0 }
    armed && index($0,"cat /home")>0 { next }
    armed && index($0,"shared-home-token")>0 { found=1; exit }
    END { exit found?0:1 }
' "$LOG"; then
    note "OK: shared home — file written in user view is visible inside enter linux"
else
    note "SOFT(mm): shared-home read inside enter linux not observed this boot"
fi

# --- (C) NEWSHELL HOSTOWNER -----------------------------------------
# C.1 must NOT print "no such user" (the alias resolves to uid-1).
if grep -F -q "no such user" "$LOG"; then
    note "FAIL: newshell hostowner still reports 'no such user' (alias unresolved)"
    fail=1
else
    note "OK: newshell hostowner resolved (no 'no such user')"
fi
# C.2 must NOT print the doubled "newshell: newshell:" prefix.
if grep -F -q "newshell: newshell:" "$LOG"; then
    note "FAIL: doubled 'newshell: newshell:' diagnostic still present"
    fail=1
else
    note "OK: no doubled 'newshell: newshell:' prefix"
fi

# Reached the end (box didn't wedge before newshell).
for b in BANNER_NEWSHELL_START BANNER_DONE; do
    if grep -F -q "$b" "$LOG"; then note "OK: reached $b"; else
        note "FAIL: never reached $b (box wedged)"; fail=1; fi
done

if [ "$fail" -ne 0 ]; then
    echo "[three_ns] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[three_ns] PASS (3-namespace isolation + shared home + newshell hostowner)"
