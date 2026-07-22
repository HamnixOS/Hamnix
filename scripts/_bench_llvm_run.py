#!/usr/bin/env python3
# scripts/_bench_llvm_run.py — engine behind scripts/bench_llvm.sh.
#
# Measures the OPTIONAL LLVM backend spike (adder/compiler/ssa_llvm.ad) against
# the native SSA backend and gcc, on the tests/bench/opt/*.ad kernels. All are
# real x86_64-linux ELFs timed as host processes on one CPU (same method as
# scripts/bench_opt.sh) after a cross-config checksum agreement gate.
#
# FOUR configs timed (the task's headline 4-way):
#   1. Adder native SSA   — codegen.ad WITH --opt (ADDER_OPT2 SSA emission path).
#   2. Adder LLVM backend  — SSA IR -> ssa_llvm.ad -> textual .ll -> clang-19 -O2.
#   3. C, gcc -O0.
#   4. C, gcc -O2.
#
# The LLVM path links a tiny C runtime (print_u64) that reproduces the prelude's
# decimal+newline output byte-for-byte, so stdout checksums are directly
# comparable. Kernels the SSA integer subset rejects (float: mandel) emit no
# `main` and are reported as LLVM-BAILED (excluded from LLVM timing).
#
# Exit: 0 all-correct; 2 results produced with >=1 LLVM correctness finding;
# 1 hard failure (compile error / baseline mismatch / missing tool).

import os
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tests" / "fuzz"))
import ad_codegen_host as h  # noqa: E402

SRC = REPO_ROOT / "tests" / "bench" / "opt"
WORK = REPO_ROOT / "build" / "bench_llvm"
PRELUDE = (SRC / "_prelude.ad").read_text()

DRIVER_SRC = REPO_ROOT / "tests" / "fuzz" / "ssa_llvm_dump_driver.ad"
DRIVER_ELF = WORK / "ssa_llvm_dump"
RUNTIME_C = WORK / "runtime.c"

KERNELS = ["matmul", "sieve", "licm", "dcecopy", "tak", "collatz", "mandel",
           "saxpy"]

CLANG = os.environ.get("BENCH_CLANG", "clang-19")

RUNTIME_SRC = r"""
/* Host C runtime for the Adder LLVM-backend spike. Provides print_u64 with the
 * exact decimal+newline output of tests/bench/opt/_prelude.ad. Returns long so
 * the LLVM `declare i64 @print_u64(i64)` ABI matches. */
#include <unistd.h>
long print_u64(unsigned long v) {
    char buf[32];
    char tmp[32];
    int n = 0, t = 0;
    if (v == 0) { buf[n++] = '0'; }
    while (v) { tmp[t++] = (char)('0' + (v % 10)); v /= 10; }
    while (t) buf[n++] = tmp[--t];
    buf[n++] = '\n';
    (void)!write(1, buf, n);
    return 0;
}
"""


def die(msg):
    print(f"[bench_llvm] FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def besttime(reps, argv):
    subprocess.run(argv, capture_output=True, text=True)  # warm-up
    best = None
    last_out = ""
    for _ in range(reps):
        t0 = time.perf_counter()
        cp = subprocess.run(argv, capture_output=True, text=True)
        t1 = time.perf_counter()
        dt = t1 - t0
        if best is None or dt < best:
            best = dt
        last_out = cp.stdout.strip()
    return best, last_out


def build_llvm_driver():
    """Compile the .ad LLVM-dump driver to a host x86_64-linux ELF."""
    WORK.mkdir(parents=True, exist_ok=True)
    rel_src = DRIVER_SRC.relative_to(REPO_ROOT)
    rel_elf = DRIVER_ELF.relative_to(REPO_ROOT)
    cp = subprocess.run(
        [sys.executable, "-m", "compiler.adder", "compile",
         "--target=x86_64-linux", str(rel_src), "-o", str(rel_elf)],
        cwd=str(REPO_ROOT), capture_output=True, text=True)
    if cp.returncode != 0 or not DRIVER_ELF.exists():
        die("failed to build ssa_llvm_dump driver:\n" + (cp.stderr or cp.stdout))
    RUNTIME_C.write_text(RUNTIME_SRC)


def build_llvm(name, body):
    """Emit .ll via ssa_llvm.ad, then clang -O2 it + the C runtime.
    Returns (elf_path_or_None, checksum_or_None, stat_line)."""
    ad = WORK / f"{name}.ad"
    ad.write_text(body)
    ll = WORK / f"{name}.ll"
    cp = subprocess.run([str(DRIVER_ELF), str(ad)], capture_output=True,
                        text=True)
    ll.write_text(cp.stdout)
    stat = ""
    for line in cp.stdout.splitlines():
        if line.startswith("; ADDER_STAT"):
            stat = line[2:].strip()
    if "define i64 @main(" not in cp.stdout:
        return None, None, stat or "no-main"
    elf = WORK / f"{name}_llvm"
    ce = subprocess.run([CLANG, "-O2", str(ll), str(RUNTIME_C), "-o", str(elf)],
                        capture_output=True, text=True)
    if ce.returncode != 0 or not elf.exists():
        return None, None, (stat + " CLANGFAIL:" +
                            (ce.stderr.splitlines()[0] if ce.stderr else "?"))
    run = subprocess.run([str(elf)], capture_output=True, text=True)
    return elf, run.stdout.strip(), stat


def build_adder(name, body, opt):
    tag = f"{name}_{'on' if opt else 'off'}"
    r = h.run_through_codegen_ad(tag, body, WORK, keep=True, opt=opt)
    if r.kind != "ok":
        die(f"adder({'on' if opt else 'off'}) {name}: {r.kind} "
            f"{r.detail[:200]}")
    elf = WORK / f"ad_{tag}.elf"
    if not elf.exists():
        die(f"adder {name}: no ELF")
    return elf, r.stdout.strip()


def build_c(name, level):
    out = WORK / f"c_{name}_O{level}"
    cp = subprocess.run(["gcc", f"-O{level}", str(SRC / f"{name}.c"), "-o",
                        str(out)], capture_output=True, text=True)
    if cp.returncode != 0:
        die(f"gcc -O{level} {name}: {cp.stderr[:200]}")
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

    for tool in ("gcc", CLANG):
        if subprocess.run(["which", tool], capture_output=True).returncode != 0:
            die(f"{tool} not found")
    if subprocess.run(["uname", "-m"], capture_output=True, text=True
                      ).stdout.strip() != "x86_64":
        die("host is not x86_64")

    WORK.mkdir(parents=True, exist_ok=True)
    h.build_driver()          # native codegen.ad dump driver
    build_llvm_driver()       # ssa_llvm.ad dump driver

    print(f"[bench_llvm] suite={kernels} reps(best-of)={reps} clang={CLANG}")
    print("[bench_llvm] compiling configs + cross-config checksum gate\n")

    built = {}
    llvm_bailed = []          # (name, stat)
    llvm_wrong = []           # (name, ref, got)
    for name in kernels:
        body = PRELUDE + "\n" + (SRC / f"{name}.ad").read_text()
        elf_off, chk_off = build_adder(name, body, False)
        elf_on, chk_on = build_adder(name, body, True)
        c0, chk_c0 = build_c(name, 0)
        c2, chk_c2 = build_c(name, 2)
        ref = {"adder-off": chk_off, "c-O0": chk_c0, "c-O2": chk_c2}
        if len(set(ref.values())) != 1:
            die(f"{name} BASELINE CHECKSUM MISMATCH: {ref}")
        elf_llvm, chk_llvm, stat = build_llvm(name, body)
        on_ok = (chk_on == chk_off)
        if elf_llvm is None:
            llvm_bailed.append((name, stat))
            print(f"  {name:9s} checksum={chk_off:>22s}  "
                  f"LLVM-BAILED [{stat}]")
            built[name] = dict(elf_on=elf_on, elf_llvm=None, c0=c0, c2=c2,
                               on_ok=on_ok)
            continue
        if chk_llvm != chk_off:
            llvm_wrong.append((name, chk_off, chk_llvm))
            print(f"  {name:9s} checksum={chk_off:>22s}  "
                  f"*** LLVM WRONG: {chk_llvm} *** [{stat}]")
            built[name] = dict(elf_on=elf_on, elf_llvm=None, c0=c0, c2=c2,
                               on_ok=on_ok)
            continue
        tag = "" if on_ok else "  (native-SSA MISCOMPILE)"
        print(f"  {name:9s} checksum={chk_off:>22s}  AGREE  LLVM=OK [{stat}]{tag}")
        built[name] = dict(elf_on=elf_on, elf_llvm=elf_llvm, c0=c0, c2=c2,
                           on_ok=on_ok)

    print(f"\n[bench_llvm] timing (best-of-{reps})\n")
    hdr = ("kernel", "nat-SSA", "LLVM", "gcc-O0", "gcc-O2",
           "LLVM/O2", "natSSA/O2", "LLVM/O0")
    print(f"{hdr[0]:9s} {hdr[1]:>9s} {hdr[2]:>9s} {hdr[3]:>9s} {hdr[4]:>9s} "
          f"{hdr[5]:>9s} {hdr[6]:>10s} {hdr[7]:>9s}")
    print("-" * 82)
    llvm_c2, nat_c2, llvm_c0 = [], [], []
    md_rows = []
    for name in kernels:
        b = built.get(name)
        if b is None:
            continue
        t_on, _ = besttime(reps, [str(b["elf_on"])])
        t_c0, _ = besttime(reps, [str(b["c0"])])
        t_c2, _ = besttime(reps, [str(b["c2"])])
        if b["elf_llvm"] is None:
            print(f"{name:9s} {t_on:8.4f}s {'  BAILED':>9s} {t_c0:8.4f}s "
                  f"{t_c2:8.4f}s {'   n/a':>9s} {t_on/t_c2:9.2f}x {'  n/a':>9s}")
            md_rows.append((name, t_on, None, t_c0, t_c2))
            continue
        t_ll, _ = besttime(reps, [str(b["elf_llvm"])])
        r_ll_c2 = t_ll / t_c2
        r_nat_c2 = t_on / t_c2
        r_ll_c0 = t_ll / t_c0
        llvm_c2.append(r_ll_c2); nat_c2.append(r_nat_c2); llvm_c0.append(r_ll_c0)
        print(f"{name:9s} {t_on:8.4f}s {t_ll:8.4f}s {t_c0:8.4f}s {t_c2:8.4f}s "
              f"{r_ll_c2:8.2f}x {r_nat_c2:9.2f}x {r_ll_c0:8.2f}x")
        md_rows.append((name, t_on, t_ll, t_c0, t_c2))
    print("-" * 82)
    g_ll_c2 = geomean(llvm_c2)
    g_nat_c2 = geomean(nat_c2)
    g_ll_c0 = geomean(llvm_c0)
    print(f"{'geomean':9s} {'':>9s} {'':>9s} {'':>9s} {'':>9s} "
          f"{g_ll_c2:8.2f}x {g_nat_c2:9.2f}x {g_ll_c0:8.2f}x")
    print()
    print(f"[bench_llvm] HEADLINE: Adder-LLVM-backend geomean {g_ll_c2:.2f}x "
          f"gcc-O2 (lower=better, <1 faster); native-SSA {g_nat_c2:.2f}x gcc-O2. "
          f"LLVM is {g_ll_c0:.2f}x gcc-O0.")
    print(f"[bench_llvm] LLVM compiled {len(llvm_c2)}/{len(kernels)} kernels; "
          f"bailed: {[b[0] for b in llvm_bailed]}; "
          f"wrong: {[w[0] for w in llvm_wrong]}")

    print("=== BENCH_LLVM_MD_BEGIN ===")
    print(f"REPS {reps}")
    for (name, t_on, t_ll, t_c0, t_c2) in md_rows:
        llf = f"{t_ll:.4f}" if t_ll is not None else "NA"
        r1 = f"{t_ll/t_c2:.2f}" if t_ll is not None else "NA"
        r2 = f"{t_on/t_c2:.2f}"
        r3 = f"{t_ll/t_c0:.2f}" if t_ll is not None else "NA"
        print(f"ROW {name} {t_on:.4f} {llf} {t_c0:.4f} {t_c2:.4f} {r1} {r2} {r3}")
    print(f"GEOMEAN {g_ll_c2:.2f} {g_nat_c2:.2f} {g_ll_c0:.2f}")
    for (name, stat) in llvm_bailed:
        print(f"LLVMBAILED {name} {stat}")
    for (name, ref, got) in llvm_wrong:
        print(f"LLVMWRONG {name} ref={ref} got={got}")
    print("=== BENCH_LLVM_MD_END ===")

    if llvm_wrong:
        sys.exit(2)


if __name__ == "__main__":
    main()
