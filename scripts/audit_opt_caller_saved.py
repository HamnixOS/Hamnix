#!/usr/bin/env python3
# scripts/audit_opt_caller_saved.py
#
# SOUNDNESS AUDIT for the Adder --opt register allocator (adder/compiler/
# regalloc.ad + the per-instruction call analysis ci_has_call/lr_spans_call in
# adder/compiler/cfg.ad).
#
# INVARIANT: no value the allocator parks in a CALLER-SAVED register may be LIVE
# ACROSS a `call`. Per the System-V ABI a `call` clobbers rax/rcx/rdx/rsi/rdi/
# r8/r9/r10/r11 and every xmm; the allocator's caller-saved extension pool is
# exactly {rdi,r8,r9,r10,r11} (regalloc.ad ra_pool_enc[5..9]) and its float
# homes are xmm8..15 (all caller-saved). If lr_spans_call (which reads the
# per-instruction ci_has_call flag) ever MISSED a call spanned by such a value,
# the callee would clobber it -> garbage -> corruption. This audit disassembles
# an --opt object and flags any caller-saved GPR/xmm that is WRITTEN, then read
# AFTER an intervening `call` with no rewrite (i.e. held live across the call).
#
# It is the disassembly-level converse of scripts/fuzz_adder_diff.sh (which runs
# --opt programs and compares OUTPUT): this proves the register-residency
# soundness net directly on emitted machine code, including the KERNEL target
# the userspace fuzzer cannot reach.
#
# Usage:
#   python3 scripts/audit_opt_caller_saved.py <objfile.o|elf> [...]
# Exit 0 iff zero violations. Reads `objdump -d` (binutils).
#
# Build an --opt kernel object to audit with:
#   source scripts/_adder_cc.sh; adder_cc_bootstrap
#   build/cutover/host_ac.elf --opt --target=x86_64-bare-metal init/main.ad k.o
#   python3 scripts/audit_opt_caller_saved.py k.o
import subprocess, sys, re

GPR_POOL = {'rdi', 'r8', 'r9', 'r10', 'r11'}   # regalloc caller-saved extension
_GPR_ALIAS = {}
for base, als in {
    'rdi': ['edi', 'di', 'dil'],
    'r8':  ['r8d', 'r8w', 'r8b'],
    'r9':  ['r9d', 'r9w', 'r9b'],
    'r10': ['r10d', 'r10w', 'r10b'],
    'r11': ['r11d', 'r11w', 'r11b'],
}.items():
    _GPR_ALIAS[base] = base
    for a in als:
        _GPR_ALIAS[a] = base
XMM_POOL = {f'xmm{i}' for i in range(8, 16)}    # caller-saved float homes

CALL = re.compile(r'^callq?$')
GPR_PUREMOV = re.compile(r'^(mov[a-z]*|lea|pop)$')
XMM_PUREMOV = re.compile(r'^(movsd|movss|movaps|movapd|movq|movd|movdqa|movdqu|movups|movupd)$')


def norm_gpr(r):
    return _GPR_ALIAS.get(r)


def parse_functions(obj):
    out = subprocess.run(['objdump', '-d', obj], capture_output=True, text=True).stdout
    funcs = []
    cur = None
    for line in out.splitlines():
        m = re.match(r'^[0-9a-f]+ <([^>]+)>:', line)
        if m:
            cur = (m.group(1), [])
            funcs.append(cur)
            continue
        m = re.match(r'^\s+([0-9a-f]+):\t[0-9a-f ]+\t(\S+)\s*(.*?)\s*$', line)
        if m and cur is not None:
            cur[1].append((int(m.group(1), 16), m.group(2), m.group(3)))
    return funcs


def split_ops(ops):
    parts, depth, s = [], 0, ''
    for ch in ops:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(s)
            s = ''
        else:
            s += ch
    if s.strip():
        parts.append(s)
    return [p.strip() for p in parts if p.strip()]


def scan(funcs, pool, puremov, extract):
    """Generic linear per-function live-across-call scan for a register class.
    `extract(token)` maps a raw '%reg' token to a canonical pool name or None."""
    reports = []
    for name, ins in funcs:
        last_write, clobbered = {}, set()
        for addr, mnem, ops in ins:
            if CALL.match(mnem):
                clobbered.update(last_write.keys())
                continue
            parts = split_ops(ops)
            read, written = set(), None
            if len(parts) >= 2:
                dst = parts[-1]
                md = re.fullmatch(r'%([a-z0-9]+)', dst)
                rd = extract(md.group(1)) if md else None
                if rd is not None:
                    written = rd
                    if not puremov.match(mnem):
                        read.add(rd)          # arith reads its dst too
                else:
                    for tok in re.findall(r'%([a-z0-9]+)', dst):
                        r = extract(tok)
                        if r:
                            read.add(r)
                for srcs in parts[:-1]:
                    for tok in re.findall(r'%([a-z0-9]+)', srcs):
                        r = extract(tok)
                        if r:
                            read.add(r)
            elif len(parts) == 1:
                md = re.fullmatch(r'%([a-z0-9]+)', parts[0])
                r1 = extract(md.group(1)) if md else None
                if mnem.startswith('pop') and r1:
                    written = r1              # pop writes, does not read
                else:
                    for tok in re.findall(r'%([a-z0-9]+)', parts[0]):
                        r = extract(tok)
                        if r:
                            read.add(r)
                    if r1 and mnem in ('inc', 'dec', 'neg', 'not'):
                        written = r1
            for r in read:
                if r in clobbered:
                    reports.append((name, addr, mnem, ops, r, last_write.get(r, 0)))
            if written is not None:
                last_write[written] = addr
                clobbered.discard(written)
    return reports


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    total = 0
    for obj in argv:
        funcs = parse_functions(obj)
        gpr = scan(funcs, GPR_POOL, GPR_PUREMOV,
                   lambda t: norm_gpr(t) if norm_gpr(t) in GPR_POOL else None)
        xmm = scan(funcs, XMM_POOL, XMM_PUREMOV,
                   lambda t: t if t in XMM_POOL else None)
        for tag, rep in (("GPR", gpr), ("XMM", xmm)):
            for r in rep:
                print(f"[{tag}] {obj}: {r[0]} @0x{r[1]:x}  {r[2]} {r[3]}   "
                      f"[%{r[4]} written@0x{r[5]:x}, clobbered by intervening call]")
        n = len(gpr) + len(xmm)
        total += n
        print(f"{obj}: {len(funcs)} funcs, {n} caller-saved-across-call violations "
              f"(GPR={len(gpr)} XMM={len(xmm)})")
    if total:
        print(f"AUDIT FAIL: {total} violation(s) — an --opt value is live across a "
              f"call in a caller-saved register (lr_spans_call/ci_has_call gap).")
        return 1
    print("AUDIT PASS: no caller-saved register held live across any call.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
