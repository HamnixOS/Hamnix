#!/usr/bin/env bash
# scripts/test_opt_imulimm.sh — focused, host-only correctness + firing guard for
# the IMUL-CONST-MATERIALIZE lever (codegen.ad sel_combine_into_home + the legacy
# gen_expr_ir binop arm). Armed only under --opt; byte-identical to the frozen
# seed OFF.
#
# THE LEVER: `x * C` for a non-negative imm32 constant C (C <= 0x7FFFFFFF) is
# emitted as the single x86 3-operand `imul %dst,%src,$C` (6B imm8 form for
# C<=127, else 7B imm32 form) instead of materializing C into a scratch register
# and doing a 2-operand imul (`mov $C,%scratch; imul %scratch,%r`). MUL is
# commutative, so C may be on either side. The gate C<=0x7FFFFFFF makes C
# sign-extend to itself, so the low 64 bits of the product are identical whether
# read signed or unsigned — exactly what the 2-operand imul it replaces computed.
# Hot in collatz (`n*3`) and dcecopy (`i*2`); fires in every bench kernel with a
# constant multiply.
#
# WHAT IT PROVES (no QEMU):
#   1. CORRECT + MATCHES OFF: const-multiply kernels produce EXACTLY the reference
#      value under --opt AND equal the --opt-OFF value.
#   2. THE 3-OPERAND FORM IS EMITTED: in the ON disassembly a constant multiply is
#      one `imul <reg>,<reg>,<imm>` with NO preceding `mov $C,<scratch>` const
#      materialize for that multiply.
#   3. FIRED + BYTE-INERT OFF: IMULIMM>0 under --opt; IMULIMM==0 with --opt off.
#   4. SAFETY: the differential corpus (adder_fuzzer._run_imulimm_corpus) pins the
#      emitted immediate + source operand across dst-alias (`s = s*3`), the
#      imm8/imm32 boundary (127/128), imm32-max (0x7FFFFFFF), and signed/unsigned
#      operands — a wrong immediate or wrong source operand is a value mismatch the
#      oracle catches — and asserts a var*var multiply does NOT fire the lever.
#      The DELIBERATE-BREAK for this net: change emit_imul_imm_reg to encode
#      `imm+1` (or swap the dst/src modrm fields) — the dst-alias and imm32-max
#      cases then miscompile, proving the corpus sees the bug; revert to restore.
#
# HOST-ONLY: python3 + as/ld/gcc + objdump (x86_64). NO QEMU. The cached dump
# driver under build/fuzz_ad_codegen AUTO-INVALIDATES on any compiler change.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
import adder_fuzzer as F
from pathlib import Path

WD = Path("build/opt_imulimm"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = F.PRELUDE
M = (1 << 64) - 1
fails = 0

# ---------------------------------------------------------------------------
# A collatz-shaped kernel: a hot loop with a constant multiply (n*3) — the exact
# shape the lever targets.
# ---------------------------------------------------------------------------
N = 200000
n = N
steps = 0
while n != 1:
    if n & 1:
        n = 3 * n + 1
    else:
        n = n >> 1
    steps += 1
ref = steps & M

SRC = PRELUDE + f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    n: int64 = {N}
    steps: int64 = 0
    while n != 1:
        if n % 2 == 1:
            n = 3 * n + 1
        else:
            n = n / 2
        steps = steps + 1
    print_u64(cast[uint64](steps))
    return cast[int32](steps & cast[int64](255))
"""

r_on = h.run_through_codegen_ad("imm_on", SRC, WD, opt=True, keep=True)
r_off = h.run_through_codegen_ad("imm_off", SRC, WD, opt=False, keep=True)
if r_on.kind != "ok" or r_off.kind != "ok":
    print(f"FAIL(compile) on={r_on.kind}/off={r_off.kind} "
          f"{(r_on.detail or r_off.detail)[:160]}")
    sys.exit(1)

# (1) correctness ON==OFF==ref
if r_on.stdout != str(ref) or r_off.stdout != str(ref):
    print(f"FAIL(value) ref={ref} on={r_on.stdout} off={r_off.stdout}"); fails += 1
else:
    print(f"[value] on==off==ref ({ref}) OK")

# (3) fired + byte-inert OFF
im_on = int(getattr(r_on, "imulimm", 0) or 0)
im_off = int(getattr(r_off, "imulimm", 0) or 0)
if im_on < 1:
    print(f"FAIL(no-fire) imulimm_on={im_on} (<1: the n*3 multiply did not lower "
          f"to a 3-operand imul)"); fails += 1
elif im_off != 0:
    print(f"FAIL(off-fired) imulimm_off={im_off} (must be 0 — byte-inert OFF)")
    fails += 1
else:
    print(f"[fire] imulimm_on={im_on} imulimm_off=0 OK")

# (2) DISASM: a constant multiply is one `imul <reg>,<reg>,<imm>` with NO
#     preceding `mov $C,<scratch>` const-materialize for that multiply.
def disasm(dump):
    raw = WD / "imm.code.bin"; raw.write_bytes(dump.code)
    txt = subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel",
         str(raw)], capture_output=True, text=True).stdout
    rows = []
    for ln in txt.splitlines():
        mm = re.match(r"\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*)$", ln)
        if mm:
            rows.append(mm.group(2).strip())
    return rows

try:
    dsrc = WD / "imm_dump.ad"
    dsrc.write_text(h.codegen_compatible_source(SRC))
    d_on = h.run_dump(dsrc, opt=True)
    if d_on.status != "ok":
        raise RuntimeError(f"run_dump status={d_on.status} "
                           f"{getattr(d_on, 'detail', '')[:160]}")
    rows = disasm(d_on)
    # 3-operand imul: `imul <reg>,<reg>,<imm>` (three comma-separated operands).
    three_op = 0
    for t in rows:
        if re.match(r"imul\s+\w+,\w+,0x[0-9a-f]+", t):
            three_op += 1
    if three_op < 1:
        print(f"FAIL(disasm) found {three_op} 3-operand imul (expected >=1 for "
              f"the n*3 multiply)"); fails += 1
    else:
        print(f"[disasm] {three_op} 3-operand imul-by-const emitted OK")
except Exception as ex:
    print(f"FAIL(disasm) exception: {ex}"); fails += 1

# (4) SAFETY: the differential corpus (dst-alias, imm8/imm32 boundary, imm32-max,
#     signed/unsigned; var*var fallback does not fire).
im_ok, im_total = F._run_imulimm_corpus()
if not im_ok:
    print(f"FAIL(corpus) imulimm differential corpus miscompiled / inert")
    fails += 1
else:
    print(f"[corpus] imulimm corpus OK ({im_total} imul-imm fires, fallback "
          f"var*var did not fire)")

if fails:
    print(f"\n[test_opt_imulimm] FAIL ({fails})"); sys.exit(1)
print("\n[test_opt_imulimm] PASS (const multiply -> 3-operand imul, correct, "
      "fired, byte-inert OFF, immediate/operand pinned by the corpus)")
PY
