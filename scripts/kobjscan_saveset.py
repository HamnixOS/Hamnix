#!/usr/bin/env python3
"""kobjscan_saveset.py — WHOLE-OBJECT scan for the two --opt register-discipline
miscompile shapes that broke (and could re-break) the optimized bare-metal
kernel boot:

  (A) UNSAVED CALLEE-SAVED CLOBBER (the ab2c060d family): a callee-saved register
      (%rbx,%r12..%r15) is WRITTEN in a function body but NOT pushed in that
      function's prologue. Under the System-V ABI the callee must preserve these,
      so any such write clobbers the caller's live value with no save/restore.
      This is exactly the scratch-reservation UNDER-COUNT that stamped the raw
      _PA_CANARY into an unsaved %r14 and corrupted the page-allocator free list
      (double-fault at boot). scripts/test_opt_idxstore_saveset.sh proves this for
      ONE fixture function; this scans EVERY function in the object.

  (B) CALLER-SAVED VALUE ACROSS A CALL: a caller-saved register in the register
      allocator's extension pool (%rdi,%r8,%r9,%r10,%r11) is written, a `call`
      then executes, and the register is READ afterwards as a data operand with
      no intervening reload. The callee is free to clobber caller-saved registers,
      so this loses the value. The RA's per-value call-free-lifetime track
      (regalloc.ad ra_pool_cap_for / cfg.ad lr_spans_call) exists precisely to
      forbid this; a regression there (e.g. an un-marked call point) would show
      up here in the emitted machine code.

Both are ABI/register-discipline violations that the semantic native-vs-seed
kobjdiff (scripts/kobjdiff_normalize.py) NORMALIZES AWAY (it drops spill/register
scheduling), so they need this dedicated structural check.

The compiler's OWN safe mechanisms are NOT flagged: push/pop stack save-restore
around a call (the spill idiom), and pop-as-restore.

Usage:   python3 scripts/kobjscan_saveset.py <object.o> [<object2.o> ...]
Exit 0 = clean; 1 = at least one violation (printed per function).
Env:     KOBJSCAN_VERBOSE=1 prints the per-function offending instruction.
"""
import os
import re
import subprocess
import sys

VERBOSE = os.environ.get("KOBJSCAN_VERBOSE", "0") == "1"

CALLEE_SAVED = {"rbx", "r12", "r13", "r14", "r15"}
EXT_POOL = {"rdi", "r8", "r9", "r10", "r11"}   # RA caller-saved extension pool

# sub-register -> canonical 64-bit name
_SUB = {}
for _canon, _names in {
    "rbx": ["rbx", "ebx", "bx", "bl"],
    "r12": ["r12", "r12d", "r12w", "r12b"],
    "r13": ["r13", "r13d", "r13w", "r13b"],
    "r14": ["r14", "r14d", "r14w", "r14b"],
    "r15": ["r15", "r15d", "r15w", "r15b"],
    "rdi": ["rdi", "edi", "di", "dil"],
    "r8":  ["r8", "r8d", "r8w", "r8b"],
    "r9":  ["r9", "r9d", "r9w", "r9b"],
    "r10": ["r10", "r10d", "r10w", "r10b"],
    "r11": ["r11", "r11d", "r11w", "r11b"],
}.items():
    for _n in _names:
        _SUB[_n] = _canon

_MOV_LIKE = ("mov", "movl", "movq", "movb", "movw", "movabs", "movzbl",
             "movzbq", "movzwl", "movzwq", "movslq", "movsbl", "movsbq",
             "movswl", "movswq", "lea", "movzx", "movsx", "xchg")
_NO_WRITE = ("cmp", "cmpq", "cmpl", "cmpb", "cmpw", "test", "testq", "testl",
             "testb", "jmp", "call", "ret", "leave", "nop", "endbr64", "cqto",
             "cqo", "cdqe", "hlt", "ud2")


def _regs_in(operand):
    return set(_SUB[m] for m in re.findall(r"%(\w+)", operand) if m in _SUB)


def _top_level_ops(ops):
    depth = 0
    cur = ""
    out = []
    for ch in ops:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return [o.strip() for o in out]


def _dst_srcs(insn):
    """Return (dst_regs, src_regs, mnemonic). pop = write(restore); push = save
    (neutral)."""
    parts = insn.split(None, 1)
    mn = parts[0] if parts else ""
    if mn.startswith("pop"):
        return (_regs_in(parts[1]) if len(parts) > 1 else set()), set(), mn
    if mn.startswith("push"):
        return set(), set(), mn
    if len(parts) < 2:
        return set(), set(), mn
    ops = _top_level_ops(parts[1])
    dst, srcs = set(), set()
    last = ops[-1]
    m = re.match(r"^%(\w+)$", last)
    writes = mn not in _NO_WRITE and not mn.startswith("j")
    if m and m.group(1) in _SUB and writes:
        dst.add(_SUB[m.group(1)])
        for o in ops[:-1]:
            srcs |= _regs_in(o)
        if mn not in _MOV_LIKE:            # read-modify-write also reads dst
            srcs.add(_SUB[m.group(1)])
    else:
        for o in ops:
            srcs |= _regs_in(o)
    return dst, srcs, mn


def _functions(obj):
    dis = subprocess.run(["objdump", "-d", "--no-show-raw-insn", obj],
                         capture_output=True, text=True).stdout.splitlines()
    fre = re.compile(r"^[0-9a-f]+ <(.+)>:$")
    ire = re.compile(r"^\s+[0-9a-f]+:\s+(.*)$")
    cur, insns, out = None, [], []
    for ln in dis:
        m = fre.match(ln)
        if m:
            if cur is not None:
                out.append((cur, insns))
            cur, insns = m.group(1), []
            continue
        m = ire.match(ln)
        if m and cur is not None:
            insns.append(m.group(1).strip())
    if cur is not None:
        out.append((cur, insns))
    return out


def _scan(obj):
    problems = []
    nfunc = 0
    for name, insns in _functions(obj):
        nfunc += 1
        # Skip functions that embed hardware-register inline asm (cpuid/rd/wr-msr,
        # etc.): those instructions write fixed architectural registers (e.g.
        # `cpuid` clobbers %rbx by hardware, saved by a hand-rolled spill outside
        # the compiler's allocator model) and are not compiler register-allocation
        # decisions — flagging them is a false positive (they appear identically
        # in the trusted --no-opt baseline).
        if any(re.match(r"(cpuid|rdmsr|wrmsr|rdtsc|xgetbv|cmpxchg)", i)
               for i in insns):
            continue
        # (A) prologue push-set vs body writes of callee-saved regs. The prologue
        # is the run of instructions up to the frame setup `mov %rsp,%rbp`
        # (mirrors scripts/test_opt_idxstore_saveset.sh); every callee-saved reg
        # PUSHed there is saved/restored. `endbr64` precedes the pushes, so a
        # simple "leading push run" would miss them — gate on the frame setup.
        # (If a function never sets up %rbp, fall back to the leading push run
        # after any endbr64.)
        pushed = set()
        has_frame = any(re.match(r"mov\s+%rsp,%rbp", i) for i in insns)
        if has_frame:
            for insn in insns:
                if re.match(r"mov\s+%rsp,%rbp", insn):
                    break
                if insn.startswith("push"):
                    pushed |= (_regs_in(insn) & CALLEE_SAVED)
        else:
            for insn in insns:
                if insn.startswith("endbr64") or insn.startswith("nop"):
                    continue
                if insn.startswith("push"):
                    pushed |= (_regs_in(insn) & CALLEE_SAVED)
                else:
                    break
        # (B) caller-saved across-call state
        crossed = set()
        held = set()
        for insn in insns:
            mn = insn.split(None, 1)[0] if insn else ""
            if mn == "call" or mn.startswith("call"):
                crossed |= held
                held = set()
                continue
            dst, srcs, _ = _dst_srcs(insn)
            # (A) a body write to an unsaved callee-saved reg
            for r in dst:
                if r in CALLEE_SAVED and r not in pushed:
                    problems.append((name, "A", r,
                                     "callee-saved %%%s written, not pushed" % r,
                                     insn))
            # (B) a read of a caller-saved reg that survived a call
            hit = crossed & (srcs & EXT_POOL)
            for r in sorted(hit):
                problems.append((name, "B", r,
                                 "caller-saved %%%s read after call" % r, insn))
            crossed -= hit
            for r in dst:
                held.add(r)
                crossed.discard(r)
            for r in srcs:
                held.discard(r)
    return problems, nfunc


def main():
    if len(sys.argv) < 2:
        print("usage: kobjscan_saveset.py <object.o> [...]", file=sys.stderr)
        return 2
    total = 0
    for obj in sys.argv[1:]:
        problems, nfunc = _scan(obj)
        for name, cls, reg, why, insn in problems:
            line = "[kobjscan] %s: %s" % (name, why)
            if VERBOSE:
                line += "   ::  " + insn
            print(line)
        tag = "CLEAN" if not problems else "VIOLATIONS=%d" % len(problems)
        print("[kobjscan] %s: %s (%d functions)" % (obj, tag, nfunc))
        total += len(problems)
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
