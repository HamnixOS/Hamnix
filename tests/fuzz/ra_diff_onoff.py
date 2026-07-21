#!/usr/bin/env python3
# tests/fuzz/ra_diff_onoff.py
#
# ORACLE-FREE register-allocator differential. For each fuzzer-generated program
# it compiles + runs the SAME program twice through codegen.ad on the host (no
# QEMU):
#     * regalloc OFF  -- ADDER_OPT_DISABLE lists ALL 16 --opt transforms, so the
#                        emitted code is byte-identical to -O0 (verified: with
#                        every transform disabled the --opt pipeline is inert).
#     * regalloc ON   -- ADDER_OPT_DISABLE lists the 15 OTHER transforms, so ONLY
#                        the linear-scan register allocator (regalloc.ad, armed by
#                        ra_enable) rewrites the code.
# and compares (stdout, exit). Because BOTH runs use the same trusted codegen.ad
# and the OFF run is the -O0 reference, ANY divergence is a genuine regalloc
# miscompile -- with NO dependence on a hand-written oracle (which is exactly the
# class of bug the by-construction differential can mask if the oracle itself is
# wrong). This complements adder_fuzzer's oracle differential: it is strictly a
# regalloc isolation, and it is the sharpest tool for bisecting a suspected
# regalloc miscompile (e.g. the --opt blank-desktop investigation).
#
# It reuses adder_fuzzer.render_program (subset=True) so it exercises the full
# generator incl. the kernel-shape FUZZ_FEATURES (fnptr/manyglobals/loopcond/
# callgraph). Exits nonzero on ANY divergence.
#
# Usage:
#   python3 tests/fuzz/ra_diff_onoff.py                 # 500 programs, seed base 1
#   RA_ONOFF_COUNT=2000 RA_ONOFF_BASE=1 python3 tests/fuzz/ra_diff_onoff.py
#
# HOST-ONLY: python3 + as/ld/gcc + x86_64. No QEMU, no image build.
import sys, os
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJ = HERE.parent.parent
os.chdir(PROJ)
sys.path.insert(0, str(HERE))
import ad_codegen_host as h
import adder_fuzzer as F

WORK = PROJ / "build" / "fuzz_ad_codegen"

# The 16 --opt transform names (10 opt_run AST passes + 6 codegen levers).
_ALL16 = "rec2iter,constfold,constbranch,xcse,cse,licm,ivsr,copyprop,paritymod,dce,regalloc,iremit,strengthreduce,isel,vec,cmpjcc"
# Same list MINUS regalloc -> only the register allocator transforms the code.
_ONLY_RA = "rec2iter,constfold,constbranch,xcse,cse,licm,ivsr,copyprop,paritymod,dce,iremit,strengthreduce,isel,vec,cmpjcc"


def _run(body, disable, tag):
    os.environ["ADDER_OPT_DISABLE"] = disable
    return h.run_through_codegen_ad(tag, body, WORK, opt=True)


def main():
    count = int(os.environ.get("RA_ONOFF_COUNT", "500"))
    base = int(os.environ.get("RA_ONOFF_BASE", "1"))
    # Kernel-shape generators on by default (matches fuzz_adder_diff.sh).
    F.FUZZ_FEATURES = ("fnptr", "manyglobals", "loopcond", "callgraph")

    both_ok = diverge = unsupported = err = 0
    for i in range(base, base + count):
        p, body = F.render_program(i, subset=True)
        off = _run(body, _ALL16, f"raoff_{i}")     # -O0 reference
        on = _run(body, _ONLY_RA, f"raon_{i}")      # regalloc only
        if off.kind == "unsupported" or on.kind == "unsupported":
            unsupported += 1
            continue
        if off.kind != "ok" or on.kind != "ok":
            err += 1
            if err <= 5:
                print(f"[seed {i}] tooling error off={off.kind} on={on.kind}")
            continue
        both_ok += 1
        if (off.stdout, off.exit) != (on.stdout, on.exit):
            diverge += 1
            print(f"[seed {i}] *** REGALLOC DIVERGENCE *** "
                  f"regOFF=({off.stdout.strip()[-48:]},{off.exit}) "
                  f"regON=({on.stdout.strip()[-48:]},{on.exit})")
            repro = PROJ / "build" / f"ra_onoff_repro_{i}.ad"
            repro.write_text(h.codegen_compatible_source(body))
            print(f"           repro written to {repro}")
            if diverge >= 10:
                break

    print(f"[ra_diff_onoff] both_ok={both_ok} diverge={diverge} "
          f"unsupported={unsupported} err={err}")
    if diverge != 0:
        print("[ra_diff_onoff] FAIL: register allocator changed program behaviour")
        sys.exit(1)
    print("[ra_diff_onoff] PASS: regalloc byte-behaviour-identical to -O0")


if __name__ == "__main__":
    main()
