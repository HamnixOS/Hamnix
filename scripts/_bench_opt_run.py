#!/usr/bin/env python3
# scripts/_bench_opt_run.py — the engine behind scripts/bench_opt.sh.
#
# Produces a FAIR, repeatable performance comparison of FOUR configurations on a
# suite of compute-bound microbenchmarks (tests/bench/opt/<name>.{ad,c}):
#
#   1. Adder, optimizer OFF  — native codegen.ad, no --opt (baseline backend).
#   2. Adder, optimizer ON   — native codegen.ad WITH --opt (the 6-pass
#                              optimizer: const-fold, CSE, LICM, DCE,
#                              const-branch fold, copy-prop).
#   3. C, gcc -O0            — unoptimized C.
#   4. C, gcc -O2            — optimized C.
#
# WHY THIS IS FAIR
# ----------------
# The native Adder compiler's `x86_64-linux` host path (tests/fuzz/
# ad_codegen_host.py) runs lex -> parse -> opt -> codegen.ad and WRAPS the
# emitted machine code into a real ELF64 EM_X86_64 executable that runs
# NATIVELY on this host CPU — the SAME CPU and the SAME ELF ABI as the
# gcc-compiled C binaries. So all four configs are timed as ordinary host
# processes on one CPU; no QEMU, no Hamnix image, no cross-VM timer skew. The
# only thing that differs between (1) and (2) is whether opt.ad's passes ran;
# between Adder and C, only the compiler. That is the honest measurement the
# task asks for.
#
# CORRECTNESS BEFORE SPEED
# ------------------------
# Each kernel prints a single decimal checksum. The harness asserts the
# checksum is IDENTICAL across all four builds before timing any of them; a
# kernel that computes the wrong thing is rejected (a fast wrong answer is not a
# benchmark). The Adder-ON build additionally reports which opt passes fired.
#
# NOISE CONTROL
# -------------
# Each binary is warmed up once (discarded), then timed best-of-N (default N=7);
# we report the BEST (minimum) wall time, which is the standard way to suppress
# scheduler/IRQ noise on a shared host. Iteration counts are sized so every
# kernel runs well over 100 ms even at C -O2, dwarfing process-spawn + timer
# overhead.
#
# Usage:
#   python3 scripts/_bench_opt_run.py [--reps N] [--kernels a,b,c]
#
# Exits non-zero on any compile failure or cross-config checksum MISMATCH.

import os
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tests" / "fuzz"))
import ad_codegen_host as h  # noqa: E402

SRC = REPO_ROOT / "tests" / "bench" / "opt"
WORK = REPO_ROOT / "build" / "bench_opt"
PRELUDE = (SRC / "_prelude.ad").read_text()

# Kernel order = the suite. Each must have <name>.ad and <name>.c.
KERNELS = ["matmul", "sieve", "licm", "dcecopy", "tak", "collatz", "mandel",
           "saxpy"]  # tak (Takeuchi) REPLACED fib 2026-07-17: the recursion->
                     # iteration lever (54969cda) exact-matches fib's linear
                     # two-term recurrence and floored it to the process-spawn
                     # floor, polluting the geomean into a false "faster than C"
                     # headline. tak is genuine irreducible tree recursion (3
                     # args) that gcc does NOT transform and no single-shape
                     # matcher can game — an HONEST call-overhead metric.
                     # saxpy added 2026-06-28 (perf_2x_roadmap.md): honest
                     # array-update reduction, NO hand-hoisted scalar accumulator
                     # (matmul hand-hoists its dot-product accumulator into `s`,
                     # masking the accumulator-regalloc lever; saxpy does not).


def die(msg):
    print(f"[bench_opt] FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def besttime(reps, argv):
    """Best-of-`reps` wall time (seconds) of running `argv`, after one warm-up.
    Returns (best_seconds, stdout_of_last_run, returncode_of_last_run)."""
    # warm-up (discarded)
    subprocess.run(argv, capture_output=True, text=True)
    best = None
    last_out = ""
    last_rc = 0
    for _ in range(reps):
        t0 = time.perf_counter()
        cp = subprocess.run(argv, capture_output=True, text=True)
        t1 = time.perf_counter()
        dt = t1 - t0
        if best is None or dt < best:
            best = dt
        last_out = cp.stdout.strip()
        last_rc = cp.returncode
    return best, last_out, last_rc


# The AST-only lane: --opt ON (the 10 high-level AST passes fire) but the six
# sibling CODEGEN levers are turned OFF via ADDER_OPT_DISABLE. This isolates the
# speedup the AST passes alone deliver — the config we can SHIP TODAY, because
# the register-allocator lever (the largest codegen lever) has a kernel-target
# miscompile that blanks the desktop. Userspace microbenchmarks are unaffected
# by that kernel-specific regalloc bug, so AST-only is expected to be CORRECT on
# every kernel here; a miscompile under AST-only would itself be a finding.
AST_ONLY_DISABLE = "regalloc,iremit,strengthreduce,isel,vec,cmpjcc"


def build_adder(name, mode):
    """Compile <name>.ad (prelude + kernel) through native codegen.ad.
    mode: "off"     — no --opt (baseline backend),
          "on"      — full --opt (all 10 AST passes + 6 codegen levers),
          "astonly" — --opt with ADDER_OPT_DISABLE=<6 codegen levers>, so only
                      the 10 AST passes run (shippable-today config).
    ADDER_OPT_DISABLE is read from the ENVIRONMENT by the codegen driver ELF at
    compile time; run_dump inherits os.environ, so we set/clear it here around
    the compile. Returns (elf_path, checksum_stdout, passes_dict)."""
    body = PRELUDE + "\n" + (SRC / f"{name}.ad").read_text()
    opt = (mode != "off")
    tag = f"{name}_{mode}"
    prev = os.environ.get("ADDER_OPT_DISABLE")
    if mode == "astonly":
        os.environ["ADDER_OPT_DISABLE"] = AST_ONLY_DISABLE
    else:
        os.environ.pop("ADDER_OPT_DISABLE", None)
    try:
        r = h.run_through_codegen_ad(tag, body, WORK, keep=True, opt=opt)
    finally:
        if prev is None:
            os.environ.pop("ADDER_OPT_DISABLE", None)
        else:
            os.environ["ADDER_OPT_DISABLE"] = prev
    if r.kind != "ok":
        die(f"adder({mode}) {name}: {r.kind} {r.detail[:300]}")
    elf = WORK / f"ad_{tag}.elf"
    if not elf.exists():
        die(f"adder({mode}) {name}: no ELF produced")
    passes = {
        "fold": r.folds, "ffold": r.ffold, "cse": r.cse, "licm": r.licm,
        "dce": getattr(r, "dce", 0), "constbranch": getattr(r, "constbranch", 0),
        "copyprop": getattr(r, "copyprop", 0),
        "strengthred": getattr(r, "strengthred", 0),
    }
    return elf, r.stdout.strip(), passes


def build_c(name, level):
    out = WORK / f"c_{name}_O{level}"
    src = SRC / f"{name}.c"
    cp = subprocess.run(["gcc", f"-O{level}", str(src), "-o", str(out)],
                        capture_output=True, text=True)
    if cp.returncode != 0:
        die(f"gcc -O{level} {name}: {cp.stderr[:300]}")
    chk = subprocess.run([str(out)], capture_output=True, text=True)
    return out, chk.stdout.strip()


def geomean(xs):
    if not xs:
        return float("nan")
    p = 1.0
    for x in xs:
        p *= x
    return p ** (1.0 / len(xs))


def main():
    reps = 7
    kernels = KERNELS
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--reps":
            reps = int(args[i + 1]); i += 2
        elif args[i] == "--kernels":
            kernels = args[i + 1].split(","); i += 2
        else:
            die(f"unknown arg {args[i]}")

    for tool in ("gcc",):
        if subprocess.run(["which", tool], capture_output=True).returncode != 0:
            die(f"{tool} not found")
    if subprocess.run(["uname", "-m"], capture_output=True, text=True
                      ).stdout.strip() != "x86_64":
        die("host is not x86_64 — cannot run the produced ELFs natively")

    WORK.mkdir(parents=True, exist_ok=True)
    h.build_driver()  # ensure the codegen.ad dump driver is built once

    print(f"[bench_opt] suite={kernels} reps(best-of)={reps}")
    print("[bench_opt] compiling all five configs + cross-config checksum check")

    built = {}        # name -> dict(...)  (only kernels valid under ALL configs)
    miscompiled = []      # names whose full ADDER_OPT=1 build is wrong
    ast_miscompiled = []  # names whose AST-only build is wrong (would be a finding)
    for name in kernels:
        elf_off, chk_off, _ = build_adder(name, "off")
        elf_ast, chk_ast, _ = build_adder(name, "astonly")
        elf_on, chk_on, passes = build_adder(name, "on")
        c0, chk_c0 = build_c(name, 0)
        c2, chk_c2 = build_c(name, 2)
        # The baseline (Adder-OFF) and both C builds MUST agree — that pins the
        # reference answer. A disagreement there is a hard error (bad kernel).
        ref = {"adder-off": chk_off, "c-O0": chk_c0, "c-O2": chk_c2}
        if len(set(ref.values())) != 1:
            die(f"{name} BASELINE CHECKSUM MISMATCH (bad kernel): {ref}")
        fired = ",".join(f"{k}={v}" for k, v in passes.items() if v)
        # AST-only correctness: it is expected to AGREE with the baseline (the
        # regalloc bug is kernel-target-specific). A disagreement is a finding.
        ast_ok = (chk_ast == chk_off)
        if not ast_ok:
            ast_miscompiled.append((name, chk_off, chk_ast))
        if chk_on != chk_off:
            # ADDER_OPT=1 miscompiled this kernel. Per the task: this is a
            # FINDING, not a license to retune. Report it and exclude the
            # kernel from the speed comparison (a wrong answer is not timeable).
            miscompiled.append((name, chk_off, chk_on))
            print(f"  {name:9s} checksum={chk_off:>22s}  *** ADDER_OPT=1 "
                  f"MISCOMPILE: got {chk_on} (excluded from timing) ***")
            continue
        ast_tag = "AST-only=AGREE" if ast_ok else f"AST-only=WRONG({chk_ast})"
        print(f"  {name:9s} checksum={chk_off:>22s}  AGREE  {ast_tag}  "
              f"opt-passes-fired[{fired or 'none'}]")
        if not ast_ok:
            # AST-only is wrong here: exclude from the AST timing/ratios (its
            # time is not comparable) but keep the full-opt row intact.
            built[name] = dict(elf_off=elf_off, elf_ast=None, elf_on=elf_on,
                               c0=c0, c2=c2, checksum=chk_off, passes=passes)
            continue
        built[name] = dict(elf_off=elf_off, elf_ast=elf_ast, elf_on=elf_on,
                           c0=c0, c2=c2, checksum=chk_off, passes=passes)
    timed = [k for k in kernels if k in built]
    if miscompiled:
        print(f"[bench_opt] WARNING: {len(miscompiled)} kernel(s) MISCOMPILE "
              f"under ADDER_OPT=1: {[m[0] for m in miscompiled]} — see the doc.")
    if ast_miscompiled:
        print(f"[bench_opt] WARNING: {len(ast_miscompiled)} kernel(s) MISCOMPILE "
              f"under AST-only: {[m[0] for m in ast_miscompiled]} — see the doc.")
    print(f"[bench_opt] timing {len(timed)} correct kernel(s) across five "
          f"configs\n")

    # --- timing (Adder-OFF, AST-only, full-ON, C-O0, C-O2) ---
    rows = []
    for name in timed:
        b = built[name]
        t_off, _, _ = besttime(reps, [str(b["elf_off"])])
        t_on, _, _ = besttime(reps, [str(b["elf_on"])])
        t_c0, _, _ = besttime(reps, [str(b["c0"])])
        t_c2, _, _ = besttime(reps, [str(b["c2"])])
        # AST-only may be excluded (miscompile finding) — time it only if kept.
        t_ast = None
        if b["elf_ast"] is not None:
            t_ast, _, _ = besttime(reps, [str(b["elf_ast"])])
        rows.append((name, t_off, t_ast, t_on, t_c0, t_c2))

    # headline ratios. su_full = OFF/ON (full speedup vs O0); su_ast = OFF/AST;
    # frac = fraction of the wall-time reduction AST-only captures; ast_c2 /
    # full_c2 = each vs gcc-O2 (x slower).
    hdr = ("kernel", "Adder-O0", "AST-only", "full-ON", "C-O2",
           "full/O0", "AST/O0", "AST%", "AST/O2", "full/O2")
    print(f"{hdr[0]:9s} {hdr[1]:>10s} {hdr[2]:>10s} {hdr[3]:>10s} "
          f"{hdr[4]:>10s} {hdr[5]:>8s} {hdr[6]:>8s} {hdr[7]:>6s} "
          f"{hdr[8]:>8s} {hdr[9]:>8s}")
    print("-" * 96)
    if not rows:
        print("(no correct kernels to time)")
    su_full_l, su_ast_l, ast_c2_l, full_c2_l = [], [], [], []
    md_rows = []
    for (name, t_off, t_ast, t_on, t_c0, t_c2) in rows:
        su_full = t_off / t_on            # >1 means full-opt is faster than O0
        r_full_c2 = t_on / t_c2           # full-opt: x slower than C -O2
        r_full_c0 = t_on / t_c0
        su_full_l.append(su_full); full_c2_l.append(r_full_c2)
        if t_ast is not None:
            su_ast = t_off / t_ast
            r_ast_c2 = t_ast / t_c2
            # fraction of the wall-time REDUCTION AST-only captures vs full:
            # (t_off - t_ast) / (t_off - t_on). Guard tiny/negative denominators.
            denom = t_off - t_on
            frac = ((t_off - t_ast) / denom) if denom > 1e-9 else float("nan")
            su_ast_l.append(su_ast); ast_c2_l.append(r_ast_c2)
            print(f"{name:9s} {t_off:9.4f}s {t_ast:9.4f}s {t_on:9.4f}s "
                  f"{t_c2:9.4f}s {su_full:7.2f}x {su_ast:7.2f}x "
                  f"{frac*100:5.0f}% {r_ast_c2:7.2f}x {r_full_c2:7.2f}x")
            md_rows.append((name, t_off, t_ast, t_on, t_c0, t_c2, su_full,
                            su_ast, frac, r_ast_c2, r_full_c2, r_full_c0))
        else:
            print(f"{name:9s} {t_off:9.4f}s {'  MISCOMP':>10s} {t_on:9.4f}s "
                  f"{t_c2:9.4f}s {su_full:7.2f}x {'   n/a':>8s} "
                  f"{'n/a':>6s} {'   n/a':>8s} {r_full_c2:7.2f}x")
            md_rows.append((name, t_off, None, t_on, t_c0, t_c2, su_full,
                            None, None, None, r_full_c2, r_full_c0))
    print("-" * 96)
    g_full = geomean(su_full_l)
    g_ast = geomean(su_ast_l)
    g_ast_c2 = geomean(ast_c2_l)
    g_full_c2 = geomean(full_c2_l)
    # Fraction of the SPEEDUP captured (linear excess over 1x, from geomeans):
    # (g_ast - 1) / (g_full - 1). This is the headline "% of the win".
    g_frac = ((g_ast - 1.0) / (g_full - 1.0)) if g_full > 1.0 + 1e-9 else float("nan")
    print(f"{'geomean':9s} {'':>10s} {'':>10s} {'':>10s} {'':>10s} "
          f"{g_full:7.2f}x {g_ast:7.2f}x {g_frac*100:5.0f}% "
          f"{g_ast_c2:7.2f}x {g_full_c2:7.2f}x")
    print()
    # "x gcc-O2" == the ON/C-O2 slower-than ratio (the project's convention:
    # full --opt has historically held ~1.83x gcc-O2; lower is better, <1 = faster).
    print(f"[bench_opt] HEADLINE: AST-only captures {g_frac*100:.0f}% of the "
          f"full --opt speedup ({g_ast:.2f}x vs {g_full:.2f}x over O0); "
          f"AST-only is {g_ast_c2:.2f}x gcc-O2 vs full's {g_full_c2:.2f}x gcc-O2.")

    # emit a machine-readable block the .sh wrapper turns into the md doc
    print("=== BENCH_OPT_MD_BEGIN ===")
    print(f"REPS {reps}")
    for r in md_rows:
        (name, t_off, t_ast, t_on, t_c0, t_c2, su_full,
         su_ast, frac, r_ast_c2, r_full_c2, r_full_c0) = r
        p = built[name]["passes"]
        fired = ";".join(f"{k}={v}" for k, v in p.items() if v) or "none"
        astf = f"{t_ast:.4f}" if t_ast is not None else "NA"
        su_astf = f"{su_ast:.2f}" if su_ast is not None else "NA"
        fracf = f"{frac*100:.0f}" if (frac is not None and frac == frac) else "NA"
        ac2f = f"{r_ast_c2:.2f}" if r_ast_c2 is not None else "NA"
        print(f"ROW {name} {t_off:.4f} {astf} {t_on:.4f} {t_c0:.4f} {t_c2:.4f} "
              f"{su_full:.2f} {su_astf} {fracf} {ac2f} {r_full_c2:.2f} "
              f"{r_full_c0:.2f} {built[name]['checksum']} {fired}")
    if md_rows:
        gfrac_s = f"{g_frac*100:.0f}" if g_frac == g_frac else "NA"
        print(f"GEOMEAN {g_full:.2f} {g_ast:.2f} {gfrac_s} "
              f"{g_ast_c2:.2f} {g_full_c2:.2f}")
    for (name, ref, got) in miscompiled:
        print(f"MISCOMPILE {name} ref={ref} adder_opt1_got={got}")
    for (name, ref, got) in ast_miscompiled:
        print(f"ASTMISCOMPILE {name} ref={ref} astonly_got={got}")
    print("=== BENCH_OPT_MD_END ===")

    if miscompiled or ast_miscompiled:
        # Non-fatal exit code 2: results produced, but a correctness finding
        # exists (full-opt and/or AST-only miscompile). The .sh wrapper surfaces it.
        sys.exit(2)


if __name__ == "__main__":
    main()
