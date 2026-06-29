#!/usr/bin/env bash
# scripts/test_opt_methodsave.sh — focused, host-only correctness + STRUCTURAL
# guard for the native optimizer's method/function callee-saved PROLOGUE SAVE-SET
# (regalloc.ad ra_pool_used, --opt).
#
# THE BUG CLASS THIS GUARDS (escalated from #508):
#   A value the regalloc parks in a CALLEE-SAVED register (e.g. %r13) that is live
#   ACROSS a (method) call inside a loop is corrupted under --opt when the callee's
#   prologue does NOT save/restore that register. The prologue save-set is derived
#   from the per-name assignment table (ra_assigned_reg) — the SAME source the body
#   reads through ra_reg_for_name — so the saved set can never desync from the
#   registers the body actually allocates. (Previously the save decision read a
#   SEPARATE bitmask, ra_used_mask; a desync between the two — inducible by source
#   perturbations that the host seed compiles into a backend with a stale mask —
#   let a method emit `mov %r13,...` in its body while pushing only {rbx,r12,...},
#   clobbering the caller's value parked in %r13.)
#
# WHAT IT PROVES (no QEMU):
#   A. VALUE CORRECTNESS: each program compiled WITH --opt produces EXACTLY the same
#      value as WITH --opt OFF (the byte-identical seed path) AND the python oracle.
#      A clobbered callee-saved value lands a wrong answer — the primary soundness
#      gate, exercised with the carried value parked across a method call in a loop,
#      varying which callee-saved register (r13/r14/r15) the allocator picks.
#   B. STRUCTURAL SAVE-SET INVARIANT: disassemble every emitted function in each
#      --opt ELF and assert its prologue's callee-saved PUSH set is a SUPERSET of
#      every callee-saved register (rbx/r12/r13/r14/r15) the body WRITES as a
#      destination. A method whose body writes %r13 but whose prologue omits the
#      `push %r13` FAILS here directly — the exact escalated defect — independent of
#      whether a given input happens to surface a wrong value. This is the permanent
#      invariant lock: any future save-set desync trips it on the affected function.
#
# HOST-ONLY: python3 + as/ld + objdump, x86_64. NO QEMU.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import sys, subprocess, re
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path

WD = Path("build/opt_methodsave"); WD.mkdir(parents=True, exist_ok=True)
PRELUDE = Path("tests/bench/opt/_prelude.ad").read_text()
U64 = (1 << 64) - 1
def u64(x): return x & U64

fails = 0

# Callee-saved x86 register names the SysV ABI requires a function to preserve.
CALLEE = {"rbx", "r12", "r13", "r14", "r15"}

# ---------------------------------------------------------------------------
# A register-pressured METHOD `step` (>=3 promoted locals + an internal call so
# those locals must live in callee-saved registers) called every loop iteration,
# while main carries an accumulator/counter across the call. The method MUST save
# every callee-saved register it allocates or the caller's carried value (parked
# by regalloc in one of them) is clobbered.
# ---------------------------------------------------------------------------
def prog(nlocals, loopn, ext_in_method):
    lv = [f"p{i}" for i in range(nlocals)]
    decls = "".join(f"        {v}: int64 = cast[int64]({i+2})\n" for i, v in enumerate(lv))
    # build a chain that keeps every local live across the internal call
    body_stmts = ""
    if ext_in_method:
        body_stmts += "        r: int64 = ext(a)\n"
    chain = " + ".join(lv + (["r", "a"] if ext_in_method else ["a"]))
    body_stmts += f"        s: int64 = {chain}\n"
    # re-touch each local AFTER the call so its interval spans the call
    body_stmts += "        s = s + " + " + ".join(lv) + "\n"
    meth = f"""
def ext(x: int64) -> int64:
    return x + cast[int64](1)
class C:
    n: int64
    def step(self, a: int64) -> int64:
{decls}{body_stmts}        self.n = self.n + s
        return self.n
"""
    main = f"""
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    o: C
    o.n = cast[int64](0)
    acc: int64 = cast[int64](0)
    k: int64 = cast[int64](0)
    while k < cast[int64]({loopn}):
        acc = acc + o.step(k)
        k = k + cast[int64](1)
    print_u64(cast[uint64](acc))
    return cast[int32](0)
"""
    return meth + main

def oracle(nlocals, loopn, ext_in_method):
    # mirror the Adder semantics exactly (modular u64)
    pl = [i + 2 for i in range(nlocals)]
    n = 0
    acc = 0
    for k in range(loopn):
        r = (k + 1) if ext_in_method else 0
        s = sum(pl) + (r + k if ext_in_method else k)
        s = s + sum(pl)
        n = u64(n + s)
        acc = u64(acc + n)
    return acc

CASES = [
    ("ms_l3", 3, 6, True),
    ("ms_l4", 4, 6, True),
    ("ms_l5", 5, 7, True),
    ("ms_l3_noext", 3, 6, False),
    ("ms_l5_noext", 5, 8, False),
]

# Fixed shapes (name, body, oracle). ms_carry is the canonical escalation repro:
# main carries the loop counter k in a callee-saved register across o.step(k,...),
# while step is pressured to allocate the full callee-saved set incl. that register.
# Sum 0..9 = 45; a step that clobbers the carried register lands a wrong sum.
FIXED = [
    ("ms_carry", """
def helper(x: int64) -> int64:
    return x + cast[int64](1)

class Box:
    n: int64
    def step(self, a: int64, b: int64) -> int64:
        p: int64 = a + b
        q: int64 = a * cast[int64](3)
        r: int64 = b * cast[int64](5)
        t: int64 = a + b + cast[int64](7)
        u: int64 = helper(a)
        v: int64 = p + q + r + t + u
        self.n = self.n + v
        return self.n

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    o: Box
    o.n = cast[int64](0)
    acc: int64 = cast[int64](0)
    k: int64 = cast[int64](0)
    while k < cast[int64](10):
        o.step(k, k + cast[int64](2))
        acc = acc + k
        k = k + cast[int64](1)
    print_u64(cast[uint64](acc))
    return cast[int32](0)
""", 45),
]

def disasm_functions(elf_path):
    """Return list of functions; each is a list of (addr, mnemonic-text). Splits
    the code segment at each endbr64 (every function prologue starts with one)."""
    rl = subprocess.run(["readelf", "-l", str(elf_path)], capture_output=True, text=True).stdout
    filesz = None
    for ln in rl.splitlines():
        m = re.search(r"LOAD\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x[0-9a-f]+\s+0x([0-9a-f]+)\s+0x[0-9a-f]+\s+R E", ln)
        if m:
            filesz = int(m.group(1), 16); break
    if filesz is None:
        filesz = elf_path.stat().st_size
    raw = elf_path.read_bytes()[:filesz]
    binf = elf_path.with_suffix(".code.bin"); binf.write_bytes(raw)
    dis = subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", "-M", "intel", str(binf)],
        capture_output=True, text=True).stdout
    funcs = []; cur = None
    for ln in dis.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+(?:[0-9a-f]{2} )+\s*(.*)", ln)
        if not m:
            continue
        addr = int(m.group(1), 16); txt = m.group(2).strip()
        if "endbr64" in txt:
            cur = {"start": addr, "insns": []}; funcs.append(cur)
        if cur is not None:
            cur["insns"].append((addr, txt))
    return funcs

def check_structural(elf_path):
    """Assert every function's callee-saved push-set ⊇ callee-saved body writes."""
    problems = []
    for f in disasm_functions(elf_path):
        pushed = set()
        writes = set()
        in_prologue = True
        for addr, txt in f["insns"]:
            pm = re.match(r"push\s+(\w+)$", txt)
            if in_prologue and pm and pm.group(1) in CALLEE:
                pushed.add(pm.group(1)); continue
            if re.match(r"mov\s+rbp,rsp$", txt):
                in_prologue = False; continue
            # destination is the FIRST operand of a 2-operand write, or push/pop reg
            wm = re.match(r"(?:mov|add|sub|imul|and|or|xor|lea|sar|shl|shr|neg|not|inc|dec)\s+(\w+)\b", txt)
            if (not in_prologue) and wm and wm.group(1) in CALLEE:
                writes.add(wm.group(1))
            pp = re.match(r"pop\s+(\w+)$", txt)
            if (not in_prologue) and pp and pp.group(1) in CALLEE:
                # pop into a callee-saved reg also writes it (epilogue pops excluded:
                # those are restores at function end — but they pop INTO the reg as a
                # restore, which is fine; only flag mid-body pops that aren't matched
                # by a push. Conservatively require it be pushed.)
                writes.add(pp.group(1))
        missing = writes - pushed
        if missing:
            problems.append(f"fn@0x{f['start']:x}: writes {sorted(writes)} but prologue pushes {sorted(pushed)} (MISSING {sorted(missing)})")
    return problems

PROGRAMS = [(name, PRELUDE + prog(nl, ln, ex), oracle(nl, ln, ex))
            for (name, nl, ln, ex) in CASES]
PROGRAMS += [(name, PRELUDE + src, ref) for (name, src, ref) in FIXED]

for name, body, ref in PROGRAMS:
    r_on = h.run_through_codegen_ad(name + "_on", body, WD, opt=True, keep=True)
    r_off = h.run_through_codegen_ad(name + "_off", body, WD, opt=False)
    if r_on.kind != "ok" or r_off.kind != "ok":
        print(f"[{name}] FAIL(compile) on={r_on.kind} off={r_off.kind} "
              f"detail={r_on.detail or r_off.detail}")
        fails += 1
        continue
    got_on = u64(int(r_on.stdout.strip() or "0"))
    got_off = u64(int(r_off.stdout.strip() or "0"))
    status = "OK"
    if not (got_on == ref and got_off == ref):
        status = f"FAIL(value ref={ref} on={got_on} off={got_off})"
        fails += 1
    # B. structural save-set invariant on the --opt ELF
    elf = WD / f"ad_{name}_on.elf"
    probs = check_structural(elf)
    if probs:
        status = "FAIL(save-set)"
        fails += 1
        for p in probs:
            print(f"[{name}]   SAVE-SET VIOLATION: {p}")
    print(f"[{name}] {status}  value={got_on} (ref {ref})  funcs-checked-clean={not probs}")

print("=" * 56)
if fails == 0:
    print("[opt_methodsave] PASS — callee-saved value survives method call; "
          "every prologue save-set ⊇ body callee-saved writes")
    sys.exit(0)
else:
    print(f"[opt_methodsave] FAIL — {fails} problem(s)")
    sys.exit(1)
PY
