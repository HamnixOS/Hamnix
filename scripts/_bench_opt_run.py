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
KERNELS = ["matmul", "sieve", "licm", "dcecopy", "fib", "collatz", "mandel",
           "saxpy"]  # saxpy added 2026-06-28 (perf_2x_roadmap.md): honest
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


def build_adder(name, opt):
    """Compile <name>.ad (prelude + kernel) through native codegen.ad, opt on/off.
    Returns (elf_path, checksum_stdout, passes_dict). Raises on unsupported/fail."""
    body = PRELUDE + "\n" + (SRC / f"{name}.ad").read_text()
    tag = f"{name}_{'on' if opt else 'off'}"
    r = h.run_through_codegen_ad(tag, body, WORK, keep=True, opt=opt)
    if r.kind != "ok":
        die(f"adder({'ON' if opt else 'OFF'}) {name}: {r.kind} {r.detail[:300]}")
    elf = WORK / f"ad_{tag}.elf"
    if not elf.exists():
        die(f"adder({'ON' if opt else 'OFF'}) {name}: no ELF produced")
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
    print("[bench_opt] compiling all four configs + cross-config checksum check")

    built = {}        # name -> dict(...)  (only kernels valid under ALL configs)
    miscompiled = []  # names whose ADDER_OPT=1 build computes the wrong checksum
    for name in kernels:
        elf_off, chk_off, _ = build_adder(name, opt=False)
        elf_on, chk_on, passes = build_adder(name, opt=True)
        c0, chk_c0 = build_c(name, 0)
        c2, chk_c2 = build_c(name, 2)
        checks = {
            "adder-off": chk_off, "adder-on": chk_on,
            "c-O0": chk_c0, "c-O2": chk_c2,
        }
        # The baseline (Adder-OFF) and both C builds MUST agree — that pins the
        # reference answer. A disagreement there is a hard error (bad kernel).
        ref = {"adder-off": chk_off, "c-O0": chk_c0, "c-O2": chk_c2}
        if len(set(ref.values())) != 1:
            die(f"{name} BASELINE CHECKSUM MISMATCH (bad kernel): {ref}")
        fired = ",".join(f"{k}={v}" for k, v in passes.items() if v)
        if chk_on != chk_off:
            # ADDER_OPT=1 miscompiled this kernel. Per the task: this is a
            # FINDING, not a license to retune. Report it and exclude the
            # kernel from the speed comparison (a wrong answer is not timeable).
            miscompiled.append((name, chk_off, chk_on))
            print(f"  {name:9s} checksum={chk_off:>22s}  *** ADDER_OPT=1 "
                  f"MISCOMPILE: got {chk_on} (excluded from timing) ***")
            continue
        print(f"  {name:9s} checksum={chk_off:>22s}  AGREE  "
              f"opt-passes-fired[{fired or 'none'}]")
        built[name] = dict(elf_off=elf_off, elf_on=elf_on, c0=c0, c2=c2,
                           checksum=chk_off, passes=passes)
    timed = [k for k in kernels if k in built]
    if miscompiled:
        print(f"[bench_opt] WARNING: {len(miscompiled)} kernel(s) MISCOMPILE "
              f"under ADDER_OPT=1: {[m[0] for m in miscompiled]} — see the doc.")
    print(f"[bench_opt] timing {len(timed)} correct kernel(s) across all four "
          f"configs\n")

    # --- timing ---
    rows = []
    for name in timed:
        b = built[name]
        t_off, _, _ = besttime(reps, [str(b["elf_off"])])
        t_on, _, _ = besttime(reps, [str(b["elf_on"])])
        t_c0, _, _ = besttime(reps, [str(b["c0"])])
        t_c2, _, _ = besttime(reps, [str(b["c2"])])
        rows.append((name, t_off, t_on, t_c0, t_c2))

    # headline ratios
    hdr = ("kernel", "Adder-OFF", "Adder-ON", "C-O0", "C-O2",
           "ON/OFF", "ON/C-O2", "ON/C-O0")
    print(f"{hdr[0]:9s} {hdr[1]:>10s} {hdr[2]:>10s} {hdr[3]:>10s} "
          f"{hdr[4]:>10s} {hdr[5]:>8s} {hdr[6]:>9s} {hdr[7]:>9s}")
    print("-" * 80)
    if not rows:
        print("(no correct kernels to time)")
    speedups, on_vs_c2, on_vs_c0 = [], [], []
    md_rows = []
    for (name, t_off, t_on, t_c0, t_c2) in rows:
        su = t_off / t_on            # >1 means ON is faster
        r_c2 = t_on / t_c2           # how many x slower than C -O2
        r_c0 = t_on / t_c0           # how many x slower than C -O0
        speedups.append(su); on_vs_c2.append(r_c2); on_vs_c0.append(r_c0)
        print(f"{name:9s} {t_off:9.4f}s {t_on:9.4f}s {t_c0:9.4f}s "
              f"{t_c2:9.4f}s {su:7.2f}x {r_c2:8.2f}x {r_c0:8.2f}x")
        md_rows.append((name, t_off, t_on, t_c0, t_c2, su, r_c2, r_c0))
    print("-" * 80)
    g_su = geomean(speedups)
    g_c2 = geomean(on_vs_c2)
    g_c0 = geomean(on_vs_c0)
    print(f"{'geomean':9s} {'':>10s} {'':>10s} {'':>10s} {'':>10s} "
          f"{g_su:7.2f}x {g_c2:8.2f}x {g_c0:8.2f}x")
    print()
    print(f"[bench_opt] HEADLINE: optimizer ON is {g_su:.2f}x faster than OFF "
          f"(geomean); Adder-ON is {g_c2:.2f}x C-O2 and {g_c0:.2f}x C-O0 (geomean).")

    # emit a machine-readable block the .sh wrapper turns into the md doc
    print("=== BENCH_OPT_MD_BEGIN ===")
    print(f"REPS {reps}")
    for (name, t_off, t_on, t_c0, t_c2, su, r_c2, r_c0) in md_rows:
        p = built[name]["passes"]
        fired = ";".join(f"{k}={v}" for k, v in p.items() if v) or "none"
        print(f"ROW {name} {t_off:.4f} {t_on:.4f} {t_c0:.4f} {t_c2:.4f} "
              f"{su:.2f} {r_c2:.2f} {r_c0:.2f} {built[name]['checksum']} {fired}")
    if md_rows:
        print(f"GEOMEAN {g_su:.2f} {g_c2:.2f} {g_c0:.2f}")
    for (name, ref, got) in miscompiled:
        print(f"MISCOMPILE {name} ref={ref} adder_opt1_got={got}")
    print("=== BENCH_OPT_MD_END ===")

    if miscompiled:
        # Non-fatal exit code 2: results produced, but a correctness finding
        # exists. The .sh wrapper surfaces it.
        sys.exit(2)


if __name__ == "__main__":
    main()
