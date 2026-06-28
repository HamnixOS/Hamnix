#!/usr/bin/env bash
# scripts/test_opt_nested_loops.sh — focused, host-only regression guard for the
# ADDER_OPT=1 NESTED-LOOP miscompile (docs/bench_opt_results.md, sieve/collatz/
# mandel). The bug: an inner loop sitting BETWEEN a local's def and its read
# across outer-loop iterations made the register allocator truncate the
# loop-spanning local's live range (a basic block CREATED before it was FILLED —
# a while's exit/join block — kept a stale `bb_first` snapshot that placed its
# program-point span INSIDE the loop body). A LATER value then reused the
# truncated value's callee-saved register, aliasing it, so all but the last outer
# pass's contribution was dropped. Minimal trigger printed 6 instead of 15.
#
# WHAT IT PROVES (no QEMU):
#   1. Each nested reset-and-read / break-continue / early-return / cross-level
#      shape, compiled through codegen.ad WITH --opt (regalloc + opt + IR-emit
#      armed), produces the SAME observable result as WITHOUT --opt and as the
#      hand-computed reference. The earlier defect made the --opt build diverge.
#   2. The three bench-kernel SHAPES (sieve/collatz/mandel reset-and-read,
#      shrunk to host-fast sizes) check out byte-for-byte under --opt.
#
# Complements the hardened differential fuzzer (scripts/fuzz_adder_diff.sh with
# ADDER_OPT=1), which now GENERATES this nested-loop class; here we pin a handful
# of minimal shapes to exact known answers so a regression is unambiguous.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import sys
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_nested_loops"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = Path("tests/bench/opt/_prelude.ad").read_text()

# ---- (A) exit-code cases: assert the returned int matches the reference -----
# (returned value is masked to the low byte by the ELF stub, so keep < 256)
CASES = []

# 1. THE minimal bench repro: 3 outer passes * 5 inner increments = 15, NOT 6.
CASES.append(("reset_read_min", """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    reps: int64 = 0
    while reps < 3:
        count: int64 = 0
        i: int64 = 0
        while i < 5:
            count = count + 1
            i = i + 1
        acc = acc + count
        reps = reps + 1
    return cast[int32](acc & 255)
""", 15))

# 2. reset-and-read with a nonzero re-init base each pass.
CASES.append(("reset_read_base", """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    r: int64 = 0
    while r < 4:
        cnt: int64 = 2
        i: int64 = 0
        while i < 3:
            cnt = cnt + 2
            i = i + 1
        acc = acc + cnt
        r = r + 1
    return cast[int32](acc & 255)
""", 32))  # 4 * (2 + 2*3) = 32

# 3. inner loop nested inside an if inside the outer loop.
CASES.append(("loop_in_if", """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    r: int64 = 0
    while r < 5:
        v: int64 = 1
        if r < 3:
            i: int64 = 0
            while i < 4:
                v = v + r
                i = i + 1
        acc = acc + v
        r = r + 1
    return cast[int32](acc & 255)
""", 17))  # r=0:1 r=1:5 r=2:9 r=3:1 r=4:1 => 17

# 4. break/continue inside the inner loop.
CASES.append(("break_continue", """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    r: int64 = 0
    while r < 3:
        cnt: int64 = 0
        i: int64 = 0
        while i < 8:
            i = i + 1
            if i == 2:
                continue
            if i == 6:
                break
            cnt = cnt + 1
        acc = acc + cnt
        r = r + 1
    return cast[int32](acc & 255)
""", 12))  # per pass: i=1,3,4,5 counted (skip 2, break at 6) => 4; *3 = 12

# 5. accumulator mutated across THREE nesting levels.
CASES.append(("cross_level", """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    o: int64 = 0
    while o < 3:
        tot: int64 = 0
        m: int64 = 0
        while m < 2:
            n: int64 = 0
            while n < 2:
                tot = tot + 1
                n = n + 1
            tot = tot + m
            m = m + 1
        acc = acc + tot
        o = o + 1
    return cast[int32](acc & 255)
""", 15))  # per o: (2 + 0) + (2 + 1) = 5 ; *3 = 15

# 6. collatz-shaped: branchy inner loop with parity test, read after.
CASES.append(("collatz_shape", """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    start: int64 = 1
    while start < 10:
        n: int64 = start
        steps: int64 = 0
        while n > 1:
            half: int64 = n / 2
            if n - half * 2 == 0:
                n = half
            else:
                n = 3 * n + 1
            steps = steps + 1
        acc = acc + steps
        start = start + 1
    return cast[int32](acc & 255)
""", None))  # reference computed below

# ---- (B) print-checksum cases: bench kernels shrunk to host-fast sizes -------
# Each prepends the prelude (print_u64) and asserts stdout under --opt == OFF.
PRINT_CASES = []

# sieve shrunk: re-clear flags each pass, count primes, sum over passes.
PRINT_CASES.append(("sieve_shape", PRELUDE + """
flags: Array[2001, uint8]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    N: int64 = 2000
    acc: int64 = 0
    reps: int64 = 0
    while reps < 4:
        z: int64 = 0
        while z <= N:
            flags[cast[int64](z)] = cast[uint8](0)
            z = z + 1
        i: int64 = 2
        while i * i <= N:
            if flags[cast[int64](i)] == cast[uint8](0):
                j: int64 = i * i
                while j <= N:
                    flags[cast[int64](j)] = cast[uint8](1)
                    j = j + i
            i = i + 1
        count: int64 = 0
        i = 2
        while i <= N:
            if flags[cast[int64](i)] == cast[uint8](0):
                count = count + 1
            i = i + 1
        acc = acc + count
        reps = reps + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & 255)
"""))

# mandel shrunk: float-heavy inner escape loop, sum of iteration counts.
PRINT_CASES.append(("mandel_shape", PRELUDE + """
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    W: int64 = 40
    H: int64 = 30
    maxit: int64 = 50
    four: float64 = cast[float64](4)
    acc: int64 = 0
    py: int64 = 0
    while py < H:
        cy: float64 = cast[float64](py) / cast[float64](H) * cast[float64](2) - cast[float64](1)
        px: int64 = 0
        while px < W:
            cx: float64 = cast[float64](px) / cast[float64](W) * cast[float64](3) - cast[float64](2)
            zx: float64 = cast[float64](0)
            zy: float64 = cast[float64](0)
            it: int64 = 0
            result: int64 = maxit
            while it < maxit:
                xx: float64 = zx * zx
                yy: float64 = zy * zy
                if xx + yy > four:
                    result = it
                    it = maxit
                else:
                    ny: float64 = cast[float64](2) * zx * zy + cy
                    zx = xx - yy + cx
                    zy = ny
                    it = it + 1
            acc = acc + result
            px = px + 1
        py = py + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & 255)
"""))

# reference for collatz_shape (steps to reach 1 over starts 1..9)
def collatz_ref():
    acc = 0
    for start in range(1, 10):
        n = start; steps = 0
        while n > 1:
            n = n // 2 if n % 2 == 0 else 3 * n + 1
            steps += 1
        acc += steps
    return acc & 255

fails = 0

for name, src, expected in CASES:
    if expected is None and name == "collatz_shape":
        expected = collatz_ref()
    r_on = h.run_through_codegen_ad(name, src, WD, opt=True)
    r_off = h.run_through_codegen_ad(name, src, WD, opt=False)
    ok = (r_on.kind == "ok" and r_off.kind == "ok"
          and r_on.exit == expected and r_off.exit == expected
          and r_on.exit == r_off.exit)
    status = "OK" if ok else "FAIL"
    if not ok:
        fails += 1
    print(f"[{name}] {status}  on_exit={getattr(r_on,'exit',None)} "
          f"off_exit={getattr(r_off,'exit',None)} expected={expected} "
          f"kind_on={r_on.kind} kind_off={r_off.kind}")

for name, src in PRINT_CASES:
    r_on = h.run_through_codegen_ad(name, src, WD, opt=True)
    r_off = h.run_through_codegen_ad(name, src, WD, opt=False)
    ok = (r_on.kind == "ok" and r_off.kind == "ok"
          and r_on.stdout == r_off.stdout and r_on.stdout != "")
    status = "OK" if ok else "FAIL"
    if not ok:
        fails += 1
    print(f"[{name}] {status}  on={r_on.stdout!r} off={r_off.stdout!r} "
          f"kind_on={r_on.kind} kind_off={r_off.kind}")

print("=" * 56)
if fails == 0:
    print("[opt_nested_loops] PASS — nested reset-and-read loops compile "
          "correctly under --opt (regalloc live-range fix holds)")
    sys.exit(0)
else:
    print(f"[opt_nested_loops] FAIL — {fails} nested-loop case(s) diverged "
          "under --opt")
    sys.exit(1)
PY
