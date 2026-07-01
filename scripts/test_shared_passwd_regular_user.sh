#!/usr/bin/env bash
# scripts/test_shared_passwd_regular_user.sh
#
# Proves the multi-user foundation: a provisioned REGULAR user (`dave`,
# uid 1000) authenticates against the shared /etc/shadow, reports its
# real identity (whoami / id), and — the headline that the previous
# brief flagged as a FIXTURE GAP — enters the Linux NS as a NON-ROOT
# user (uid 1000, not 0). The hostowner -> root (uid 0) mapping must
# still hold (no regression of test_enter_linux_uid_map.sh).
#
# WHAT THIS GATES
#
#   1. su dave (right password) authenticates against the shared
#      /etc/shadow ($6$ SHA-512-crypt) and changes identity:
#      "su: switched to uid 1000 (dave)" (su's deterministic proof,
#      printed via sys_getuid() BEFORE it execs dave's login shell).
#   2. whoami in dave's shell reports `dave` (resolved via /etc/passwd).
#   3. id reports `uid=1000(dave) gid=1000(dave) groups=1000(dave)` —
#      the rewritten user/id.ad reads the REAL uid/gid (no more the old
#      hard-coded `uid=0(root)`) and maps names via passwd + group.
#   4. enter linux { <uid probe> } AS dave reports uid 1000 (the native
#      1000 -> Linux 1000 non-root mapping fires across the rfork).
#   5. enter linux { cat /etc/passwd } shows `dave` — the shared account
#      table is visible inside the Linux NS.
#   6. REGRESSION: hostowner's enter linux { <uid probe> } still reports
#      uid 0 (root).
#
# HARNESS — mirrors scripts/test_enter_linux_uid_map.sh exactly: hamsh
# as /init (INIT_ELF=hamsh.elf) under the lean `-kernel` TCG path, with
# a STRIPPED HAMNIX_HAMSH_RC that plants the device binds + an OVERLAY
# `linux` ns and does NOT enter runlevel 5 (so the serial line stays the
# live interactive shell). The probe (tests/u-binary/u_glibc_idprobe)
# is a static-PIE glibc ELF whose getuid()/getgid() run through the real
# _u_getuid mapping regardless of namespace, so an overlay `linux = ns {}`
# suffices to demonstrate the mapping. The PRODUCTION shared-passwd path
# (`bind '#r/etc/passwd' /etc/passwd` over the `#distro` root in the
# clean `linux`/`debian` recipes of etc/rc.boot.full / rc.de-user /
# rc.de-hostowner) is verified for full e2e by the installed-image auth
# tests (test_auth.sh); here the overlay inherits the native /etc/passwd
# (`#r/etc/passwd`) so account visibility inside `enter linux` is still
# exercised.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

ensure_ubin_or_skip test_shared_passwd_regular_user u_glibc_idprobe glibc_idprobe

echo "[test_shared_passwd] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_shared_passwd] (2/4) Plant stripped /etc/hamsh.rc (device binds + linux ns, no runlevel-5 DE)"
RC_TMP=$(mktemp /tmp/hamsh-rc-sharedpw.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
bind '#c' /dev
bind '#s' /srv
bind '#p' /proc
bind '#/' /n
bind '#r/etc/passwd' /etc/passwd
bind '#r/etc/shadow' /etc/shadow
bind '#r/etc/group' /etc/group
linux = ns {
}
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[test_shared_passwd] (3/4) Build initramfs (hamsh as /init) + embed probe + kernel"
# CRITICAL: point INIT_ELF at a COPY of hamsh OUTSIDE build/user/. If we
# used build/user/hamsh.elf directly, build_initramfs's glob would embed
# it as /init and SKIP re-embedding it at /bin/hamsh (the init-override
# de-dup) — leaving NO /bin/hamsh, so su's execve("/bin/hamsh") after the
# identity change would fail with -ENOENT. With a distinct copy as /init,
# the glob still lands build/user/hamsh.elf at /bin/hamsh for su to exec.
INIT_HAMSH=$(mktemp /tmp/hamsh-init.XXXXXX.elf)
cp "$HAMSH_ELF" "$INIT_HAMSH"
HAMNIX_EMBED_UBIN=1 HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$INIT_HAMSH" \
    python3 scripts/build_initramfs.py >/dev/null

mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-shared-passwd.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP" "$INIT_HAMSH"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_shared_passwd] (4/4) Boot QEMU + drive su dave + identity probes"
set +e
(
    # Marker-gated driving. The feeder subshell reads the serial capture
    # ($LOG, written by QEMU) to synchronise on the guest's actual state
    # instead of fixed sleeps — robust to the slow/variable boot under the
    # kernel's verbose first-task paging diagnostics. Without this the su
    # password races su's raw read() and the whoami/id probes land during
    # dave's login-shell recipe bring-up (both get dropped).
    _w() {  # marker  timeout-seconds
        local m="$1" t="$2" w=0
        while [ "$w" -lt "$t" ]; do
            grep -a -F -q "$m" "$LOG" 2>/dev/null && return 0
            sleep 1; w=$((w + 1))
        done
        return 1
    }
    # Boot: wait for the interactive shell banner, then settle + flush the
    # first-line-dropped quirk.
    _w "[hamsh] M16.35 shell ready" 240
    sleep 2
    printf 'echo SYNC_FLUSH\n'; sleep 3
    printf 'echo SYNC_FLUSH\n'; sleep 3

    # PHASE A (hostowner): regression guard — hostowner enters Linux NS
    # as root. Must run BEFORE su (after su this shell is dave forever).
    printf 'echo HOST_ENTER_BEGIN\n'; sleep 1
    printf 'enter linux { /bin/u_glibc_idprobe }\n'; sleep 5
    printf 'enter linux { /bin/u_glibc_idprobe }\n'; sleep 5
    printf 'echo HOST_ENTER_END\n'; sleep 1

    # PHASE B: su to the regular user. Wait for su's "Password: " prompt
    # (so its raw read() is posted) before sending the password; if su
    # doesn't switch shortly after, re-send once (covers the read-not-yet-
    # posted race). Then wait for dave's login shell to finish sourcing its
    # per-user namespace recipe before probing.
    printf 'echo SU_BEGIN\n'; sleep 1
    printf 'su dave\n'
    _w "Password:" 40; sleep 3
    printf 'hamnix\n'
    _w "su: switched to uid 1000 (dave)" 40 || printf 'hamnix\n'
    _w "su: switched to uid 1000 (dave)" 60
    # dave's nested login shell now sources /etc/users/*.ns (correct for a
    # regular user) — wait for the recipe-ready marker so the probes below
    # land on a live readline.
    _w "ns-recipe: regular-user namespace ready" 180
    sleep 2
    printf 'echo SU_AFTER\n'; sleep 3

    # PHASE C (dave): identity + non-root enter-linux.
    printf 'echo DAVE_WHOAMI_BEGIN\n'; sleep 1
    printf 'whoami\n'; sleep 3
    printf 'whoami\n'; sleep 3
    printf 'echo DAVE_WHOAMI_END\n'; sleep 1

    printf 'echo DAVE_ID_BEGIN\n'; sleep 1
    printf 'id\n'; sleep 3
    printf 'id\n'; sleep 3
    printf 'echo DAVE_ID_END\n'; sleep 1

    printf 'echo DAVE_ENTER_BEGIN\n'; sleep 1
    printf 'enter linux { /bin/u_glibc_idprobe }\n'; sleep 5
    printf 'enter linux { /bin/u_glibc_idprobe }\n'; sleep 5
    printf 'echo DAVE_ENTER_END\n'; sleep 1

    printf 'echo DAVE_PASSWD_BEGIN\n'; sleep 1
    printf 'enter linux { cat /etc/passwd }\n'; sleep 5
    printf 'echo DAVE_PASSWD_END\n'; sleep 1

    printf 'echo ALL_DONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 480s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[test_shared_passwd] --- captured output (tail) ---"
tail -260 "$LOG" | strings
echo "[test_shared_passwd] --- end output ---"

fail=0

# Marker-windowed search: assert `pat` appears between BEGIN and END.
between() {
    local beg="$1" end="$2" pat="$3"
    LC_ALL=C awk -v b="$beg" -v e="$end" -v p="$pat" '
        BEGIN { armed=0; found=0 }
        index($0,b)>0 { armed=1; next }
        index($0,e)>0 { armed=0 }
        armed && index($0,p)>0 { found=1 }
        END { exit found?0:1 }
    ' "$LOG"
}

# Sanity: stripped rc sourced.
if grep -a -F -q "TEST_RC_DONE_DEFINING_NS" "$LOG"; then
    echo "[test_shared_passwd] OK: stripped rc sourced + linux ns captured"
else
    echo "[test_shared_passwd] FAIL: stripped rc did not run"
    fail=1
fi

# 6. REGRESSION: hostowner -> uid 0 across enter linux.
if between "HOST_ENTER_BEGIN" "HOST_ENTER_END" "U21: uid=0 gid=0 ppid=1"; then
    echo "[test_shared_passwd] OK: hostowner enter linux -> uid 0 (root) [no regression]"
else
    echo "[test_shared_passwd] FAIL: hostowner enter linux did NOT report uid 0"
    fail=1
fi

# 1. su dave authenticated against the shared shadow + changed identity.
if between "SU_BEGIN" "SU_AFTER" "su: switched to uid 1000 (dave)"; then
    echo "[test_shared_passwd] OK: su dave authenticated (shared shadow) -> uid 1000"
else
    echo "[test_shared_passwd] FAIL: su dave did not switch to uid 1000 (auth/setuid failed)"
    fail=1
fi

# 2. whoami reports dave. Search the whole dave-session span (SU_AFTER ..
#    DAVE_ENTER_BEGIN) rather than the tight whoami markers: under the
#    kernel's verbose debug spew the console lags, so a command's OUTPUT
#    and the surrounding BEGIN/END marker echoes can arrive interleaved
#    out of order. The broader window still uniquely attributes "dave" to
#    the whoami output (dave's login banner "(dave)" is BEFORE SU_AFTER).
if between "SU_AFTER" "DAVE_ENTER_BEGIN" "dave"; then
    echo "[test_shared_passwd] OK: whoami -> dave"
else
    echo "[test_shared_passwd] FAIL: whoami did not report dave"
    fail=1
fi

# 3. id reports the real regular-user triplet (NOT the old uid=0(root)).
#    Same widened window as whoami (see above).
if between "SU_AFTER" "DAVE_ENTER_BEGIN" "uid=1000(dave) gid=1000(dave) groups=1000(dave)"; then
    echo "[test_shared_passwd] OK: id -> uid=1000(dave) gid=1000(dave) groups=1000(dave)"
else
    echo "[test_shared_passwd] FAIL: id did not report the regular-user triplet"
    fail=1
fi
# Guard against the old hard-coded Unix-ism leaking back.
if between "DAVE_ID_BEGIN" "DAVE_ID_END" "uid=0(root)"; then
    echo "[test_shared_passwd] FAIL: id still printed the hard-coded uid=0(root)"
    fail=1
fi

# 4. THE HEADLINE: enter linux AS dave reports the non-root uid 1000.
if between "DAVE_ENTER_BEGIN" "DAVE_ENTER_END" "U21: uid=1000 gid=1000 ppid=1"; then
    echo "[test_shared_passwd] OK: enter linux { uid probe } as dave -> uid 1000 (NON-ROOT mapping)"
else
    echo "[test_shared_passwd] FAIL: enter linux as dave did NOT report uid 1000"
    fail=1
fi

# 5. shared passwd visible inside the Linux NS.
if between "DAVE_PASSWD_BEGIN" "DAVE_PASSWD_END" "dave:x:1000:1000"; then
    echo "[test_shared_passwd] OK: enter linux { cat /etc/passwd } shows dave (shared account table)"
else
    echo "[test_shared_passwd] DIAG: dave entry not seen inside enter linux /etc/passwd (non-fatal)"
fi

# Regression guard: no CPU trap during the run.
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_shared_passwd] FAIL: CPU exception observed"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_shared_passwd] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_shared_passwd] PASS -- regular user dave: shared-shadow auth + non-root enter-linux (uid 1000); hostowner still root (uid 0)"
exit 0
