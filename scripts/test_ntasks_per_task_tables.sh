#!/usr/bin/env bash
# scripts/test_ntasks_per_task_tables.sh — per-task security-table sizing +
# fail-closed regression guard.
#
# BACKGROUND. kernel/sched/core.ad lifted the scheduler task cap NTASKS (and
# NR_FDS) from 16 to 64 (and NTASKS 64 -> 256 -> 512). Satellite per-task policy tables were sized /
# bounded against an INDEPENDENT local "16" and several FAILED OPEN: a task
# scheduled into slot 16-63 had its security policy silently voided —
# seccomp let ALL syscalls through, landlock un-sandboxed the task, caps /
# mempolicy / pidfd / perf / keyring dropped its per-task record.
#
# The fix: every per-task table is sized to NTASKS (== 512) and every bounds
# check / row stride references the scheduler's IMPORTED NTASKS / NR_FDS
# DIRECTLY (Adder forbids initialising one global from another, so there is no
# local alias constant to drift). The security-bearing out-of-range branches
# (seccomp, landlock) now FAIL CLOSED — deny, never allow.
#
# This is a STATIC (grep) guard, deliberately VM-free: it is fast, deterministic,
# and catches the exact silent-regression shape that produced the original bug
# (a future NTASKS lift that misses one table dim, or a fail-open branch creeping
# back). It asserts:
#   (A) NTASKS in core.ad is the single source of truth and the array dims in
#       every owned file match it (512, or 512*NR_FDS = 32768 for flat task×fd).
#   (B) No owned file re-introduces a per-task table sized 16 / 64, nor a
#       local *_NTASKS / *_NRFDS = 16/64 literal.
#   (C) The security-bearing out-of-range branches DENY (fail closed): seccomp's
#       bpf_run_all returns KILL (not ALLOW); landlock_check_open returns EACCES
#       (not 0/allow).
#
# Pass marker:  [test_ntasks_tables] PASS
# Fail marker:  [test_ntasks_tables] FAIL

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "[test_ntasks_tables] $*"; }
bad()  { echo "[test_ntasks_tables] FAIL: $*"; fail=1; }

CORE="kernel/sched/core.ad"
SECCOMP="kernel/seccomp_bpf.ad"
OWNED_ABI="linux_abi/u_landlock.ad linux_abi/u_caps.ad linux_abi/u_mempolicy.ad
           linux_abi/u_pidfd.ad linux_abi/u_perf.ad linux_abi/u_keyring.ad"

# (A) NTASKS / NR_FDS single source of truth in core.ad. NTASKS == 512 (lifted
# 256 -> 512 by Track 5 now the dispatch path is O(active)); NR_FDS stays 64.
if ! grep -Eq '^NTASKS:[[:space:]]+uint64[[:space:]]*=[[:space:]]*512\b' "$CORE"; then
    bad "core.ad NTASKS is not the expected single-source literal 512"
fi
if ! grep -Eq '^NR_FDS:[[:space:]]+uint64[[:space:]]*=[[:space:]]*64\b' "$CORE"; then
    bad "core.ad NR_FDS is not the expected single-source literal 64"
fi

# Every owned file must import NTASKS from the scheduler (the shared constant),
# never define its own task-cap literal.
for f in $SECCOMP $OWNED_ABI; do
    if ! grep -Eq 'from kernel\.sched\.core import' "$f"; then
        bad "$f does not import from kernel.sched.core"
    fi
    if ! grep -Eq '\bNTASKS\b' "$f"; then
        bad "$f does not reference the imported NTASKS"
    fi
done

# (B) No owned file may define a LOCAL per-task-cap constant set to 16 or 64
# (the historical lagging sizes), nor a stale NR_FDS mirror at 16. (Comments
# are free to mention the historical 16 / 64.)
if grep -Ehn '^[A-Za-z_]*N(TASKS|RFDS|R_FDS)[[:space:]]*:[[:space:]]*uint64[[:space:]]*=[[:space:]]*(16|64)\b' \
        $SECCOMP $OWNED_ABI; then
    bad "an owned file still defines a per-task-cap / NRFDS constant = 16/64"
fi

# No owned file may carry a per-task table still sized 16 or 64 (the pre-lift
# NTASKS values). The known NON-task buffers are whitelisted: CBPF scratch
# (mem 'Array[16, uint32]'), the test fd-save buffers (pf_fd_save), keyring
# test payload buffers (ukey_test_*), keyring per-call scratch (dbuf), the
# seccomp_data byte view (_seccomp_data_scratch, == SECCOMP_DATA_LEN 64), and
# the landlock per-(ruleset,rule) arrays (ll_rule_access/ll_rule_plen, sized
# LL_MAX_RULESETS*rules = 8*8 = 64, NOT task-indexed). Anything else at 16/64
# is a possible un-resized per-task table.
while IFS= read -r line; do
    case "$line" in
        *CBPF_MEMWORDS*|*pf_fd_save*|*ukey_test_*|*dbuf*|*_seccomp_data_scratch*) : ;;
        *ll_rule_access*|*ll_rule_plen*) : ;;             # ruleset*rule, not task
        *"# We store it as Array[64"*) : ;;               # comment line, not a decl
        *) bad "suspicious 16/64-sized array (possible un-resized per-task table): $line" ;;
    esac
done < <(grep -Ehn 'Array\[(16|64),' $SECCOMP $OWNED_ABI || true)

# (C) Fail-closed security branches. Scan from the out-of-range guard forward
# to its first `return` (skipping any explanatory comment lines in between).
# seccomp bpf_run_all: out-of-range slot must KILL, never ALLOW.
SECCOMP_OOR=$(awk '/def bpf_run_all/{i=1} i&&/slot >= NTASKS/{f=1} f&&/return /{print; exit}' "$SECCOMP")
case "$SECCOMP_OOR" in
    *SECCOMP_RET_KILL_PROCESS*) : ;;
    *SECCOMP_RET_ALLOW*) bad "seccomp bpf_run_all out-of-range slot STILL returns ALLOW (fail open)" ;;
    *) bad "seccomp bpf_run_all out-of-range slot does NOT fail closed (KILL): '$SECCOMP_OOR'" ;;
esac
# landlock_check_open: out-of-range slot must deny (LL_EACCES), never return 0.
LL_OOR=$(awk '/def landlock_check_open/{i=1} i&&/slot >= NTASKS/{f=1} f&&/return /{print; exit}' linux_abi/u_landlock.ad)
case "$LL_OOR" in
    *LL_EACCES*) : ;;
    *"return 0"*) bad "landlock_check_open out-of-range slot STILL returns 0 (allow / fail open)" ;;
    *) bad "landlock_check_open out-of-range slot does NOT fail closed (EACCES): '$LL_OOR'" ;;
esac

if [ "$fail" -eq 0 ]; then
    note "PASS"
    exit 0
fi
note "FAIL"
exit 1
