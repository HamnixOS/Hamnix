#!/usr/bin/env bash
# scripts/test_de_first_term_prewarm_guard.sh — static guards for the
# FIRST-TERMINAL COLD-START LATENCY fix (perf D1) so it does not silently
# regress. Cheap grep/compile assertions only — no QEMU. The live proof is a
# DE boot where the auto-launched terminal emits "[hamterm] COLD_START
# jiffies=<N>" to /dev/cons (scripts/test_de_term_enter_linux.sh boots the DE
# and the marker rides its serial log).
#
# SYMPTOM the fix targets: the first DE terminal opened after boot is laggy
# (2nd keystroke ~0.2s late, `pwd`/first command ~0.5s); a second terminal is
# fast. ROOT CAUSE: the first terminal's /bin/hamsh + /etc/rc.de-user + first
# external commands (/bin/ls, /bin/pwd) are read COLD off the root fs, missing
# the block buffer cache (kernel/block/blk.ad) and ext4 page cache
# (fs/fcache.ad). The second terminal reuses the now-cached pages.
#
# FIXES guarded here:
#   (1) rc.5 pre-warms those caches ONCE, synchronously, BEFORE launching the
#       scene terminal, by running the SAME read set the terminal will.
#   (2) `pwd` is a hamsh BUILTIN (no /bin/pwd cold-exec), registered in both
#       the dispatch table and the is-builtin kind check.
#   (3) hamtermscene reports the cold-start cost so a boot gate can measure it.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0
pass() { echo "[prewarm_guard] PASS $1"; }
failf() { echo "[prewarm_guard] FAIL $1" >&2; fail=1; }
need() { grep -q -- "$2" "$1" && pass "$3" || failf "$3"; }

RC5="etc/rc.d/rc.5"; SH="user/hamsh.ad"; TS="user/hamtermscene.ad"

echo "[prewarm_guard] --- (1) rc.5 pre-warms before the terminal launch ---"
need "$RC5" "pre-warming shell + command cache" "rc.5 has a pre-warm marker"
need "$RC5" "/bin/hamsh /etc/rc.de-user /bin/ls /" "rc.5 pre-warm runs the terminal's cold read set"
# The pre-warm MUST come BEFORE the terminal launch or the first terminal is
# still cold. Compare line numbers of the pre-warm and the terminal spawn.
pw_ln=$(grep -n "pre-warming shell + command cache" "$RC5" | head -1 | cut -d: -f1)
tm_ln=$(grep -n "/bin/hamtermscene" "$RC5" | head -1 | cut -d: -f1)
if [ -n "$pw_ln" ] && [ -n "$tm_ln" ] && [ "$pw_ln" -lt "$tm_ln" ]; then
    pass "pre-warm (line $pw_ln) precedes terminal launch (line $tm_ln)"
else
    failf "pre-warm does not precede the terminal launch (pw=$pw_ln tm=$tm_ln)"
fi
# It must be a SYNCHRONOUS command (blocks rc.5), NOT a detached spawn, so the
# cache is hot before the terminal execs.
if grep -q "spawn detached.*rc.de-user.*ls" "$RC5"; then
    failf "pre-warm is detached — cache may not be hot when the terminal execs"
else
    pass "pre-warm is synchronous (blocks rc.5 until the cache is hot)"
fi

echo "[prewarm_guard] --- (2) pwd is a hamsh builtin ---"
need "$SH" "def builtin_pwd" "hamsh defines builtin_pwd"
need "$SH" 'cstr_eq(cmd, "pwd")' "hamsh registers pwd in the builtin dispatch/kind tables"
# Registered in BOTH tables: _builtin_dispatch (calls it) AND the kind check
# (so its redirects are wired). Expect exactly two matches.
n_pwd=$(grep -c 'cstr_eq(cmd, "pwd")' "$SH")
if [ "$n_pwd" -ge 2 ]; then
    pass "pwd registered in both dispatch + kind-check tables ($n_pwd sites)"
else
    failf "pwd registered in only $n_pwd table(s) (need dispatch + kind check)"
fi
need "$SH" "sys_getcwd(&pwd_buf\[0\]" "builtin_pwd reports via SYS_GETCWD (no /bin/pwd exec)"

echo "[prewarm_guard] --- (3) hamtermscene reports cold-start cost ---"
need "$TS" "t_cold0: uint64 = sys_get_jiffies()" "terminal stamps time before the shell spawn"
need "$TS" '\[hamterm\] COLD_START jiffies=' "terminal emits a COLD_START timing marker"

echo "[prewarm_guard] --- compile the touched user binaries ---"
# shellcheck source=_adder_cc.sh
source "$PROJ_ROOT/scripts/_adder_cc.sh"
mkdir -p build/user
for n in hamsh hamtermscene; do
    if adder_cc_compile compile --target=x86_64-adder-user "user/${n}.ad" \
            -o "build/user/${n}.elf" >/dev/null 2>&1; then
        pass "user/${n}.ad compiles"
    else
        failf "user/${n}.ad failed to compile"
    fi
done

echo "[prewarm_guard] --- result ---"
if [ "$fail" = 0 ]; then echo "[prewarm_guard] RESULT: PASS"; exit 0
else echo "[prewarm_guard] RESULT: FAIL"; exit 1; fi
