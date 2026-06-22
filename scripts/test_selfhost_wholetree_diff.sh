#!/usr/bin/env bash
# scripts/test_selfhost_wholetree_diff.sh — Track-3 self-hosting CUTOVER
# WHOLE-TREE differential (host-only, NO QEMU).
#
# The fuzz dry-run (test_selfhost_cutover_dryrun.sh) proves codegen.ad
# matches the Python seed across the FUZZ CORPUS — but the fuzzer only
# generates a narrow subset of the language. This gate asks the harder,
# real question the cutover actually depends on:
#
#   Does the self-hosted `.ad` host compiler (build/cutover/host_ac.elf)
#   ACCEPT and compile every REAL compilation unit the production build
#   feeds to the Python seed?
#
# It compiles each real userland `.ad` unit with BOTH backends:
#   * Python seed:  python3 -m compiler.adder compile --target=x86_64-adder-user
#   * .ad compiler: build/cutover/host_ac.elf <in.ad> <out.elf>
# and reports, per unit, whether each backend ACCEPTED the source.
#
# IMPORTANT — current state (see docs/subsystems/adder-compiler.md
# "Self-hosting cutover — WHOLE-TREE blocker"): the `.ad` compiler is a
# CLOSED-WORLD, single-translation-unit subset compiler. Capability #1 of
# the cutover (EXTERN LINKAGE) has LANDED: codegen.ad now synthesizes the
# `sys_*` syscall-wrapper bodies user/runtime.S provides (link_runtime_
# externs), so every single-TU unit whose only blocker was extern linkage
# now compiles + behaves identically to the seed (proven by
# test_selfhost_extern_link.sh). The `.ad` compiler still has NO import
# resolution (multi-TU = a NEXT capability) and a handful of single-TU
# units still hit unsupported constructs (reason 8) or inline `asm_volatile`
# (surfaces as reason 7 — the unresolved `asm_volatile` "callee"). This
# script is a TRACKING / REGRESSION gate: it asserts the seed still compiles
# 100% of the tree, and reports the `.ad` acceptance count + the remaining
# blocker breakdown (reason 7 = unknown callee / inline-asm; reason 8 =
# unsupported construct). It must NOT regress the `.ad`-accepted baseline
# (now 119/128 single-TU).
#
# Usage:  bash scripts/test_selfhost_wholetree_diff.sh
#
# Env:
#   WT_BASELINE_AD_OK  expected minimum .ad-accepted units (default 119,
#                      post extern-linkage). Raise this as codegen.ad/
#                      elf_emit.ad gain import resolution + missing
#                      constructs.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

BASELINE_AD_OK="${WT_BASELINE_AD_OK:-119}"

fail() { echo "[wholetree] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v as  >/dev/null 2>&1 || fail "as not found (binutils)"
command -v ld  >/dev/null 2>&1 || fail "ld not found (binutils)"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64"

WT="build/cutover/wt"
mkdir -p "$WT" build/cutover

# --- (1) Build host_ac.elf via the Python seed (the bootstrap/trust root).
echo "[wholetree] (1/2) build the .ad host compiler (host_ac.elf) via the Python seed"
python3 - <<'PY' || fail "concat host compiler source failed"
import importlib.util
spec = importlib.util.spec_from_file_location("ccs", "scripts/concat_compiler_source.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.DRIVER_MAIN = "fused_driver_host_main.ad"
raise SystemExit(m.main(["concat", "-o", "build/cutover/host_compiler.ad", "--with-driver"]))
PY
python3 -m compiler.adder compile --target=x86_64-linux \
    build/cutover/host_compiler.ad -o build/cutover/host_ac.elf \
    >/dev/null 2>build/cutover/host_ac.cerr \
    || { cat build/cutover/host_ac.cerr; fail "host_ac.elf failed to build"; }
[ -x build/cutover/host_ac.elf ] || fail "no host_ac.elf produced"
echo "[wholetree]   host_ac.elf OK: $(stat -c%s build/cutover/host_ac.elf) bytes"

# --- (2) Whole-tree differential over real userland units.
echo "[wholetree] (2/2) compile every real userland .ad unit with BOTH backends"

units="$(grep 'build_adder_user ' scripts/build_user.sh | awk '{print $2}')"

total=0; single_tu=0; multi_tu=0
seed_ok=0; seed_fail=0
ad_ok=0; ad_fail=0
r7=0; r8=0; rparse=0; rother=0
ad_ok_names=""

for f in $units; do
    src="user/$f.ad"
    [ -f "$src" ] || src="tests/$f.ad"
    [ -f "$src" ] || continue
    total=$((total + 1))

    imp="$(grep -c '^from \|^import ' "$src")"
    if [ "$imp" != "0" ]; then
        multi_tu=$((multi_tu + 1))
        continue   # .ad compiler has no import resolution; skip (a known blocker)
    fi
    single_tu=$((single_tu + 1))

    # Python seed (the oracle): MUST accept every real unit.
    if python3 -m compiler.adder compile --target=x86_64-adder-user "$src" \
            -o "$WT/${f}.seed.elf" >/dev/null 2>"$WT/${f}.seed.err"; then
        seed_ok=$((seed_ok + 1))
    else
        seed_fail=$((seed_fail + 1))
        echo "[wholetree]   SEED REJECTED $src — oracle must accept the real tree"
    fi

    # .ad host compiler.
    if build/cutover/host_ac.elf "$src" "$WT/${f}.ad.elf" \
            >"$WT/${f}.ad.err" 2>&1; then
        ad_ok=$((ad_ok + 1))
        ad_ok_names="$ad_ok_names $f"
    else
        ad_fail=$((ad_fail + 1))
        err="$(cat "$WT/${f}.ad.err")"
        case "$err" in
            *"reason=7"*) r7=$((r7 + 1)) ;;
            *"reason=8"*) r8=$((r8 + 1)) ;;
            *"parse error"*) rparse=$((rparse + 1)) ;;
            *) rother=$((rother + 1)) ;;
        esac
    fi
done

echo
echo "===== WHOLE-TREE DIFFERENTIAL REPORT ====="
echo "real userland .ad units:        $total"
echo "  single-TU (0 imports):        $single_tu"
echo "  multi-TU (imports; .ad skip): $multi_tu"
echo "Python seed (oracle):"
echo "  accepted:                     $seed_ok"
echo "  REJECTED:                     $seed_fail"
echo ".ad host compiler (host_ac.elf):"
echo "  accepted:                     $ad_ok    [$ad_ok_names ]"
echo "  rejected:                     $ad_fail"
echo "    reason 7 (no extern link):  $r7"
echo "    reason 8 (unsup construct): $r8"
echo "    parse error:                $rparse"
echo "    other:                      $rother"
echo "=========================================="

# The Python seed is the oracle: it MUST compile 100% of the real tree.
[ "$seed_fail" -eq 0 ] || fail "Python seed rejected $seed_fail real unit(s) — oracle broken"

# Guard the .ad baseline against REGRESSION (it should only ever grow as
# codegen.ad/elf_emit.ad gain extern linkage + import resolution).
if [ "$ad_ok" -lt "$BASELINE_AD_OK" ]; then
    fail ".ad accepted $ad_ok < baseline $BASELINE_AD_OK — codegen.ad regressed"
fi

if [ "$ad_ok" -lt "$single_tu" ]; then
    echo "[wholetree] PASS (TRACKING) — seed compiles 100%; .ad compiles" \
         "$ad_ok/$single_tu single-TU units. Cutover BLOCKED on extern" \
         "linkage + import resolution (see docs/subsystems/adder-compiler.md)."
    exit 0
fi

echo "[wholetree] PASS — .ad compiler accepts ALL single-TU real units."
exit 0
