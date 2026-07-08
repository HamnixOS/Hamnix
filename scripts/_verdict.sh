# scripts/_verdict.sh — the three-valued test verdict vocabulary.
#
# THE PROBLEM THIS SOLVES
#
# A test harness that only knows PASS and FAIL is forced to lie when a
# run never got far enough to observe its own assertion. Historically
# scripts/test_hamsh_heartbeat.sh did exactly that:
#
#     PASS (inconclusive: 0 heartbeats but stage-07 reached AND qemu
#           rc=124 — guest timer likely starved by concurrent host load)
#     $ echo $?
#     0
#
# Zero heartbeats observed. The entire point of that canary is to
# observe heartbeat cadence, and it observed none — yet a human, an
# agent, or CI reading exit 0 concludes "the kernel is healthy". That
# is a false green, and this project has repeatedly been burned by it.
#
# There are THREE outcomes, not two:
#
#   PASS         the assertion was actually OBSERVED to hold.
#   FAIL         the assertion was actually OBSERVED to be violated.
#   INCONCLUSIVE the run never got far enough to observe the assertion
#                (QEMU timeout, starved guest timer, missing OVMF/socat,
#                image absent, daemon never came up, screendump empty).
#                This is NOT a pass and NOT a code failure. It is the
#                absence of evidence, and it must be reported as such.
#
# THE EXIT-STATUS CONVENTION  (single source of truth — documented here
# and nowhere else; see also docs/TEST_VERDICTS.md)
#
#     0    PASS
#     1    FAIL
#   125    INCONCLUSIVE
#
# Why 125:
#   * 124 is owned by timeout(1) ("the command timed out"). A gate must
#     be able to distinguish "my QEMU timed out" (an input) from "I am
#     reporting inconclusive" (an output), so 124 is unavailable.
#   * 126 ("found but not executable") and 127 ("command not found")
#     are reserved by POSIX shells.
#   * 128+n is reserved for death-by-signal.
#   * 125 already means exactly this in the most widely deployed piece
#     of software that needs the concept: `git bisect` uses exit 125 for
#     "this commit cannot be tested — skip it", i.e. inconclusive. We
#     borrow the established meaning rather than invent one.
#   * Caveat, deliberately accepted: timeout(1) itself exits 125 if
#     timeout *internally* fails (e.g. cannot fork). Gates never
#     propagate a raw timeout(1) status as their own exit status —
#     they capture it into `rc` and then decide a verdict — so the two
#     125s never meet. Do not `exit $?` straight out of a timeout call.
#
# USAGE
#
#     . "$(dirname "$0")/_verdict.sh"
#
#     verdict_pass         mytag "42 heartbeats, 12 distinct ticks"
#     verdict_fail         mytag "heartbeat emitted but never rearmed"
#     verdict_inconclusive mytag "0 heartbeats; qemu rc=124 (host-starved)"
#
# Each prints a single machine-greppable line and EXITS with the
# corresponding status. They exit the whole script even when called
# from inside a shell function — which is the intent: a gate that
# cannot observe its assertion has nothing further to say.
#
# The emitted line always has the shape
#
#     [<tag>] <VERDICT>: <reason>
#
# so `grep -E '^\[[^]]+\] (PASS|FAIL|INCONCLUSIVE):'` recovers the
# verdict of any gate from its log.

VERDICT_PASS_RC=0
VERDICT_FAIL_RC=1
VERDICT_INCONCLUSIVE_RC=125

# verdict_pass <tag> <reason...>
# The assertion was observed to hold.
verdict_pass() {
    local tag="$1"; shift
    echo "[$tag] PASS: $*"
    exit "$VERDICT_PASS_RC"
}

# verdict_fail <tag> <reason...>
# The assertion was observed to be violated. Real, actionable red.
verdict_fail() {
    local tag="$1"; shift
    echo "[$tag] FAIL: $*" >&2
    exit "$VERDICT_FAIL_RC"
}

# verdict_inconclusive <tag> <reason...>
# The assertion was never observed. Absence of evidence. NOT a pass.
#
# Reach for this when: QEMU hit its timeout before the marker could
# print; the guest timer was starved by host load; OVMF/socat/kvm or a
# required disk image is missing; the daemon under test never came up;
# a screendump came back empty. In every one of those cases the code
# under test may be perfectly fine or catastrophically broken — this
# run cannot tell you which, and it must not pretend otherwise.
verdict_inconclusive() {
    local tag="$1"; shift
    echo "[$tag] INCONCLUSIVE: $*" >&2
    echo "[$tag] INCONCLUSIVE is NOT a pass — the assertion was never" \
         "observed. Re-run on a quiet host, or install the missing" \
         "dependency, before believing anything about this code." >&2
    exit "$VERDICT_INCONCLUSIVE_RC"
}

# verdict_pass_structural <tag> <what-was-actually-checked>
# A PASS that is honest about being a STRUCTURAL check only: it grepped
# source or log text and proved that the code says the right thing. It
# did NOT render a pixel, drive a mouse, or otherwise observe the
# runtime behaviour it is named after.
#
# Exits 0 (the check it does perform genuinely passed) but brands the
# line so nobody mistakes it for end-to-end proof. Per the arch audit,
# the whole test_de_*.sh family is in this category.
verdict_pass_structural() {
    local tag="$1"; shift
    echo "[$tag] PASS (STRUCTURAL-ONLY): $*"
    echo "[$tag] NOTE: this gate proves the SOURCE/LOG says the right" \
         "thing. It does NOT prove anything renders. Do not cite it as" \
         "evidence that the feature works." >&2
    exit "$VERDICT_PASS_RC"
}

# verdict_name <rc> — human name for a verdict exit status.
verdict_name() {
    case "$1" in
        0)   echo "PASS" ;;
        125) echo "INCONCLUSIVE" ;;
        *)   echo "FAIL" ;;
    esac
}
