#!/usr/bin/env bash
# scripts/test_compiler_bool_xor.sh — regression for issue #114: a boolean XOR /
# inequality of two PARENTHESISED comparisons, `(a < 0) != (b < 0)`, miscompiled
# to the wrong value on BOTH backends because the chained-comparison detector
# folded it into `a<0 and 0 != (b<0)` (parentheses were dropped by the parser,
# so it could not tell `(a<0) != (b<0)` from the bare chain `a<0 != (b<0)`).
#
# FIX: the parser records explicit parenthesisation (BinaryExpr.paren in the
# seed; nd_num=1 on the ND_BINARY natively) and the chain detector treats a
# parenthesised left comparison as a boolean atom. A bare `a<b<c` still chains.
#
# The fixture (tests/test_compiler_bool_xor.ad) self-checks each XOR / equality
# against an explicit-sign-test reference AND asserts a genuine `a<b<c` chain
# still works; run_all() returns 0 on PASS, else a nonzero failing-case tag.
#
# COVERAGE — both backends, opt OFF and ON:
#   * Python SEED (codegen_x86.py) at -O0/-O1/-O2, linked against a C driver.
#   * Native self-hosted (codegen.ad) via the host dump harness, --opt off + on.
#
# HOST-ONLY: python3 + as/ld/cc. NO QEMU. PASS criterion:
#   "[compiler_bool_xor] PASS" on stdout.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_bool_xor"
FIXTURE="tests/test_compiler_bool_xor.ad"
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
        fprintf(stderr, "[compiler_bool_xor] FAIL: run_all()=%lld "
                        "(nonzero => a (a<0)!=(b<0)-class result disagreed with "
                        "its explicit-sign-test reference)\n", (long long)r);
        return 1;
    }
    printf("[compiler_bool_xor] seed backend OK\n");
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
echo "[$TAG] (native codegen.ad) run through host dump harness, --opt off + on"
FIXTURE="$FIXTURE" python3 - <<'PY'
import os, sys
sys.path.insert(0, "tests/fuzz")
import adder_fuzzer as F
import ad_codegen_host as h
from pathlib import Path

fixture_src = Path(os.environ["FIXTURE"]).read_text()
body = F.PRELUDE + fixture_src + '''
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    print_u64(cast[uint64](run_all()))
    return 0
'''
WD = Path("build/compiler_bool_xor"); WD.mkdir(parents=True, exist_ok=True)
rc = 0
for opt in (False, True):
    res = h.run_through_codegen_ad(1, body, WD, opt=opt)
    if res.kind != "ok":
        print(f"[compiler_bool_xor] FAIL native opt={opt}: "
              f"{res.kind} {res.detail}")
        rc = 1
        continue
    if res.stdout.strip() != "0":
        print(f"[compiler_bool_xor] FAIL native opt={opt}: "
              f"run_all()={res.stdout!r} (expected 0)")
        rc = 1
        continue
    print(f"[compiler_bool_xor] native opt={opt} OK")
sys.exit(rc)
PY

echo "[$TAG] PASS"
