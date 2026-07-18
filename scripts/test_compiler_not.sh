#!/usr/bin/env bash
# scripts/test_compiler_not.sh — regression for the `not` unary operator
# (UNOP_NOT). `not` is parsed by both backends but was used NOWHERE in the .ad
# codebase, so its codegen path was previously unexercised. Both backends lower
# `not x` to `testq %rax,%rax; setz %al; movzbq %al,%rax` (== `(x==0)?1:0`, a
# full 64-bit register test). This gate pins that semantics across every
# position `not` can appear (value, if-condition, double-negation, `a and not
# b`, `not (a==b)`, full-register width) on BOTH backends, opt OFF and ON.
#
# The fixture (tests/test_compiler_not.ad) self-checks each case against its
# expected boolean result; run_all() returns 0 on PASS, else a nonzero failing-
# case tag.
#
# COVERAGE:
#   * Python SEED (codegen_x86.py) at -O0/-O1/-O2, linked against a C driver.
#   * Native self-hosted (codegen.ad) via the host dump harness, --opt off + on.
#
# HOST-ONLY: python3 + as/ld/cc. NO QEMU. PASS criterion:
#   "[compiler_not] PASS" on stdout.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_not"
FIXTURE="tests/test_compiler_not.ad"
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
        fprintf(stderr, "[compiler_not] FAIL: run_all()=%lld "
                        "(nonzero => a `not` case disagreed with its expected "
                        "boolean result)\n", (long long)r);
        return 1;
    }
    printf("[compiler_not] seed backend OK\n");
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
WD = Path("build/compiler_not"); WD.mkdir(parents=True, exist_ok=True)
rc = 0
for opt in (False, True):
    res = h.run_through_codegen_ad(1, body, WD, opt=opt)
    if res.kind != "ok":
        print(f"[compiler_not] FAIL native opt={opt}: "
              f"{res.kind} {res.detail}")
        rc = 1
        continue
    if res.stdout.strip() != "0":
        print(f"[compiler_not] FAIL native opt={opt}: "
              f"run_all()={res.stdout!r} (expected 0)")
        rc = 1
        continue
    print(f"[compiler_not] native opt={opt} OK")
sys.exit(rc)
PY

echo "[$TAG] PASS"
