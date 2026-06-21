#!/usr/bin/env python3
# tests/fuzz/cutover_dryrun.py — Track-3 self-hosting CUTOVER DRY-RUN.
#
# Proves the self-hosted Adder compiler (lexer.ad + parser.ad + codegen.ad +
# elf_emit.ad), built as an x86_64-LINUX HOST BINARY by the Python seed
# toolchain, reproduces the seed's results across the fuzz corpus — the
# precondition for flipping the default build driver from the Python seed to
# the .ad binary.
#
# For each fuzzer-generated program (deterministic per seed):
#   * PYTHON SEED path: compile with `python3 -m compiler.adder compile
#     --target=x86_64-linux` (codegen_x86.py -> AT&T asm -> as/ld) and run.
#   * .AD HOST path: run the same source through the self-hosted compiler
#     pipeline built as a host binary (the established ad_codegen dump driver
#     == lexer.ad+parser.ad+codegen.ad fused to x86_64-linux by the seed),
#     wrap the emitted code+data into a runnable Linux ELF, and run.
#
# Match metric = BEHAVIORAL identity: both runs print the same g_accum and
# exit with the same status. (The two backends are NOT expected to be
# byte-identical: the seed routes through GNU `as`, while codegen.ad emits
# raw machine code directly — different-but-equivalent encodings. Behavioral
# identity over the corpus is the cutover-readiness signal.)
#
# A program the .ad compiler legitimately does not accept (outside its
# subset) is counted UNSUPPORTED, not a mismatch — the seed remains the
# fallback for those during/after cutover.
#
# HOST-ONLY: python3 + as/ld/gcc + an x86_64 host. NO QEMU, NO image build.
#
# Usage:
#   python3 tests/fuzz/cutover_dryrun.py [--count N] [--seed S]
# Exits nonzero on ANY behavioral mismatch (a genuine cutover blocker).

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))

import adder_fuzzer as fz          # noqa: E402
import ad_codegen_host as adh      # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=300)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--max-show", type=int, default=10)
    args = ap.parse_args()

    work = REPO / "build" / "cutover_dryrun"
    work.mkdir(parents=True, exist_ok=True)

    # Build the .ad compiler as a host binary (force a fresh build so any
    # codegen.ad edit is picked up — build_driver only checks the dump
    # driver's own mtime, not codegen.ad's).
    print("[cutover] building the self-hosted .ad compiler as an "
          "x86_64-linux HOST binary (Python seed compiles the .ad compiler)")
    adh.build_driver(force=True)
    print(f"[cutover]   -> {adh.DRIVER_ELF} "
          f"({adh.DRIVER_ELF.stat().st_size} bytes)")

    n_run = 0
    n_match = 0
    n_unsupported = 0
    mismatches = []
    errors = []

    for i in range(args.count):
        prog_seed = (args.seed * 1_000_003 + i) & 0x7FFFFFFF
        _p, body = fz.render_program(prog_seed)

        # PYTHON SEED path (codegen_x86.py).
        py = fz.compile_and_run(prog_seed, body)
        if py.kind != "ok":
            errors.append((prog_seed, f"seed {py.kind}: {py.detail[:120]}"))
            continue

        # .AD HOST path (self-hosted compiler host binary).
        ad = adh.run_through_codegen_ad(prog_seed, body, work)

        n_run += 1
        if ad.kind == "unsupported":
            n_unsupported += 1
            continue
        if ad.kind != "ok":
            errors.append((prog_seed, f".ad {ad.kind}: {ad.detail[:120]}"))
            continue

        # Behavioral comparison: stdout (the printed g_accum) + exit byte.
        py_exit = (py.exit & 0xFF) if py.exit is not None else None
        if ad.stdout == py.stdout and ad.exit == py_exit:
            n_match += 1
        else:
            mismatches.append(
                (prog_seed,
                 f"seed=({py.stdout!r},{py_exit}) "
                 f".ad=({ad.stdout!r},{ad.exit})"))

        if (i + 1) % 100 == 0:
            print(f"[cutover] ...{i+1}/{args.count} "
                  f"(match={n_match} unsupported={n_unsupported} "
                  f"mismatch={len(mismatches)})")

    accepted = n_run - n_unsupported
    rate = (100.0 * n_match / accepted) if accepted else 0.0
    print("\n===== CUTOVER DRY-RUN REPORT =====")
    print(f"programs run (seed OK):        {n_run}")
    print(f"  .ad accepted:                {accepted}")
    print(f"    behavioral MATCH:          {n_match}  ({rate:.1f}% of accepted)")
    print(f"    behavioral MISMATCH:       {len(mismatches)}")
    print(f"  .ad unsupported (subset):    {n_unsupported}")
    print(f"tooling/seed errors:           {len(errors)}")
    print("==================================")
    for (s, d) in mismatches[:args.max_show]:
        print(f"  [MISMATCH] seed={s}: {d}")
        print(f"             repro: python3 tests/fuzz/adder_fuzzer.py --emit {s}")
    for (s, d) in errors[:args.max_show]:
        print(f"  [ERROR] seed={s}: {d}")

    if mismatches:
        print("[cutover] FAIL — behavioral mismatch (cutover blocker)")
        return 1
    if errors:
        print("[cutover] FAIL — tooling/seed errors")
        return 1
    print("[cutover] PASS — .ad host compiler reproduces the seed across the "
          "corpus")
    return 0


if __name__ == "__main__":
    sys.exit(main())
