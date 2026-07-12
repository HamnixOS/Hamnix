#!/usr/bin/env bash
# scripts/test_compiler_signed_pow2_div.sh — regression for issue #102: a SIGNED
# int64 divided (or %) by a CONSTANT power of two whose DIVIDEND is a computed
# sub-expression (e.g. `(a - b)`) was miscompiled as an UNSIGNED op (divq /
# logical shrq / bias-free strength-reduced shift) instead of a round-toward-zero
# signed idiv, so e.g. `-4003 / 1024` returned 18014398509481980 (~2^54) instead
# of -3. ONLY a computed dividend was bitten (a plain identifier/cast already
# worked), which is why lib/svg.ad + lib/jpeg.ad worked around it with `_sdiv`.
#
# ROOT CAUSE (fixed): the div/mod signedness decision resolved the operand's
# static type SHALLOWLY (unknown for an integer sub-expression) and fell back to
# the unsigned default. Fixed in BOTH backends to resolve operand signedness
# STRUCTURALLY (seed codegen_x86._binop_signed_op via _shr_value_unsigned; native
# codegen.ad div_use_signed via shr_value_signedness).
#
# The fixture (tests/test_compiler_signed_pow2_div.ad) self-checks: each
# constant-divisor quotient/remainder is compared to the SAME division done with
# a VARIABLE divisor (a real signed idiv — exactly the `_sdiv` reference). It
# also asserts positives are unchanged and a computed UNSIGNED pow2 divide stays
# unsigned. run_all() returns 0 on PASS, else a nonzero failing-case tag.
#
# COVERAGE — both backends, strength reduction OFF and ON:
#   * Python SEED (codegen_x86.py) at -O0/-O1/-O2, linked against a C driver.
#   * Native self-hosted (codegen.ad) via the host dump harness, --opt off + on.
#
# HOST-ONLY: python3 + as/ld/cc. NO QEMU. PASS criterion:
#   "[compiler_signed_pow2_div] PASS" on stdout.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_signed_pow2_div"
FIXTURE="tests/test_compiler_signed_pow2_div.ad"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- Part A: Python SEED backend (codegen_x86.py) at every -O level -------
DRIVER="$WORK/driver.c"
cat > "$DRIVER" <<'EOF'
#include <stdio.h>
#include <stdint.h>
extern int64_t run_all(void);
int main(void) {
    int64_t r = run_all();
    if (r != 0) {
        fprintf(stderr, "[compiler_signed_pow2_div] FAIL: run_all()=%lld "
                        "(nonzero => a signed const div/mod disagreed with its "
                        "idiv reference)\n", (long long)r);
        return 1;
    }
    printf("[compiler_signed_pow2_div] seed backend OK\n");
    return 0;
}
EOF

CC="${CC:-cc}"
for O in 0 1 2; do
    echo "[$TAG] (seed -O$O) compile $FIXTURE -> asm + link C driver"
    ASM="$WORK/fixture_O$O.s"
    BIN="$WORK/run_O$O"
    python3 -m compiler.adder asm \
        --target=x86_64-adder-user -O"$O" \
        "$FIXTURE" -o "$ASM"
    "$CC" -no-pie -O0 "$ASM" "$DRIVER" -o "$BIN"
    "$BIN"
done

# ---- Part B: native self-hosted backend (codegen.ad) via host harness -----
# Run the SAME fixture through the codegen.ad pipeline on the host (no QEMU),
# with strength reduction OFF and ON; assert run_all() prints 0.
echo "[$TAG] (native codegen.ad) run through host dump harness, --opt off + on"
FIXTURE="$FIXTURE" python3 - <<'PY'
import os, sys
sys.path.insert(0, "tests/fuzz")
import adder_fuzzer as F
import ad_codegen_host as h
from pathlib import Path

fixture_src = Path(os.environ["FIXTURE"]).read_text()
# A main that observes run_all() as decimal on stdout (0 == PASS).
body = F.PRELUDE + fixture_src + '''
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    print_u64(cast[uint64](run_all()))
    return 0
'''
WD = Path("build/compiler_signed_pow2_div"); WD.mkdir(parents=True, exist_ok=True)
rc = 0
for opt in (False, True):
    res = h.run_through_codegen_ad(1, body, WD, opt=opt)
    if res.kind != "ok":
        print(f"[compiler_signed_pow2_div] FAIL native opt={opt}: "
              f"{res.kind} {res.detail}")
        rc = 1
        continue
    if res.stdout.strip() != "0":
        print(f"[compiler_signed_pow2_div] FAIL native opt={opt}: "
              f"run_all()={res.stdout!r} (expected 0); strengthred={res.strengthred}")
        rc = 1
        continue
    print(f"[compiler_signed_pow2_div] native opt={opt} OK "
          f"(strengthred fired={res.strengthred})")
sys.exit(rc)
PY

echo "[$TAG] PASS"
