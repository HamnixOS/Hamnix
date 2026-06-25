#!/usr/bin/env python3
# tests/fuzz/iremit_coverage.py
#
# Measure IR-EMIT COVERAGE over a corpus: the fraction of ND_BINARY roots that
# codegen.ad (under --opt) emits THROUGH the value IR (IREMIT) vs falls back to
# the AST emitter (IRFALLBACK). coverage = IREMIT / (IREMIT + IRFALLBACK).
#
# The corpus is N deterministic fuzzer-generated programs (the same generator the
# differential lane uses), each compiled with the dump driver (--opt) which
# reports IREMIT/IRFALLBACK markers. This is the quantitative before/after metric
# for the Phase-6 broadening (compares + DIV/MOD/SHR).
#
# Usage: python3 tests/fuzz/iremit_coverage.py [N]   (default 200)
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(HERE))

import ad_codegen_host as host          # noqa: E402
import adder_fuzzer as af               # noqa: E402

WORK = REPO_ROOT / "build" / "fuzz_ad_codegen"


def gen_program(seed):
    """Generate one fuzzer program body (codegen.ad-compatible subset)."""
    _p, body = af.render_program(seed, subset=True)
    return host.codegen_compatible_source(body)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    host.build_driver()
    WORK.mkdir(parents=True, exist_ok=True)
    tot_iremit = 0
    tot_fallback = 0
    tot_fold = 0
    tot_reassoc = 0
    tot_float = 0
    accepted = 0
    progs_with_ir = 0
    progs_with_float = 0
    for i in range(n):
        try:
            src_text = gen_program(1000 + i)
        except Exception:
            continue
        src = WORK / f"cov_{i}.ad"
        src.write_text(src_text)
        try:
            d = host.run_dump(src, opt=True)
        except Exception:
            src.unlink(missing_ok=True)
            continue
        src.unlink(missing_ok=True)
        if d.status != "ok":
            continue
        accepted += 1
        ie = int(getattr(d, "iremit", 0) or 0)
        fb = int(getattr(d, "irfallback", 0) or 0)
        tot_iremit += ie
        tot_fallback += fb
        tot_fold += int(getattr(d, "irfold", 0) or 0)
        tot_reassoc += int(getattr(d, "irreassoc", 0) or 0)
        fl = int(getattr(d, "iremitfloat", 0) or 0)
        tot_float += fl
        if ie > 0:
            progs_with_ir += 1
        if fl > 0:
            progs_with_float += 1
    roots = tot_iremit + tot_fallback
    cov = (100.0 * tot_iremit / roots) if roots else 0.0
    print(f"corpus: {accepted} programs accepted (of {n} generated)")
    print(f"ND_BINARY roots reached: {roots}")
    print(f"  emitted via IR (IREMIT):   {tot_iremit}")
    print(f"    of which FLOAT roots:    {tot_float}")
    print(f"  fell back to AST:          {tot_fallback}")
    print(f"IR-EMIT COVERAGE: {cov:.1f}% of ND_BINARY roots")
    print(f"programs with >=1 IR-emitted root:   {progs_with_ir}/{accepted}")
    print(f"programs with >=1 FLOAT IR root:     {progs_with_float}/{accepted}")
    print(f"IR const-folds: {tot_fold}   ADD reassociations: {tot_reassoc}")


if __name__ == "__main__":
    main()
