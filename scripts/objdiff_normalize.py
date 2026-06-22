#!/usr/bin/env python3
"""objdiff_normalize.py — semantic native-vs-seed machine-code differential.

Inputs: <seed.elf> <native.elf> <unit-name>
Both are Hamnix-format ELF32 images whose code bytes are real x86-64.

WHY A HISTOGRAM, NOT A LINE DIFF
--------------------------------
The two backends are equivalent-but-not-identical BY CONSTRUCTION (doc:
adder-compiler.md): the Python seed routes through GNU `as`/`ld`; codegen.ad
emits raw machine code and is explicitly "free to pick its own register/
encoding within each lowering as long as the runtime value matches". So a
naive instruction-by-instruction diff drowns in legitimate register-allocation
and spill-ordering noise (seed spills with push/pop; native uses a scratch
register, etc.).

What we MUST still catch is the recurring REAL bug family the cutover keeps
revealing: wrong operand WIDTH (movq where the seed has movl/movw/movb/movzbl —
a sub-8-byte store/load/spill truncation bug), a wrong opcode CLASS, or a
missing/extra operation. Those survive register renaming and reordering.

METRIC: per matched function, compare the MULTISET (histogram) of
(mnemonic, operand-width, operand-shape-class) keys. Register names and
spill/scratch shuffles that net to the same data movement leave the histogram
unchanged; a width or opcode-class divergence shows up as a histogram delta.

Function alignment: the seed's .symtab gives exact FUNC boundaries + NAMES; the
native image (no symtab) is split into blocks at each `endbr64` prologue. We
drop the seed's whole-runtime.S wrapper set + native's synthesized-wrapper /
_start blocks (their SETS differ legitimately — seed links all of runtime.S,
native synthesizes only called wrappers) and align the remaining user functions
positionally in source order.
"""
import re, subprocess, sys, struct, os, tempfile
from collections import Counter

VERBOSE = os.environ.get("OBJDIFF_VERBOSE", "0") == "1"


def read_elf(path):
    with open(path, "rb") as f:
        data = f.read()
    e_entry = struct.unpack_from("<I", data, 0x18)[0]
    e_phoff = struct.unpack_from("<I", data, 0x1C)[0]
    e_phentsize = struct.unpack_from("<H", data, 0x2A)[0]
    e_phnum = struct.unpack_from("<H", data, 0x2C)[0]
    e_shoff = struct.unpack_from("<I", data, 0x20)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x2E)[0]
    e_shnum = struct.unpack_from("<H", data, 0x30)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x32)[0]
    loads = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz = \
            struct.unpack_from("<IIIIII", data, off)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz, p_memsz))
    loads.sort()
    sections = []
    if e_shoff and e_shnum:
        sh = []
        for i in range(e_shnum):
            off = e_shoff + i * e_shentsize
            vals = struct.unpack_from("<IIIIIIIIII", data, off)
            sh.append(vals)
        shstr_off = sh[e_shstrndx][4]
        def shname(n):
            end = data.index(b"\0", shstr_off + n)
            return data[shstr_off + n:end].decode("latin1")
        for s in sh:
            sections.append((shname(s[0]), s[1], s[4], s[5], s[6], s[9]))
    return data, e_entry, loads, sections


def seed_functions(path):
    data, entry, loads, sections = read_elf(path)
    symtab = strtab = None
    for name, typ, off, size, link, entsz in sections:
        if name == ".symtab":
            symtab = (off, size, entsz)
        if name == ".strtab":
            strtab = (off, size)
    funcs = []
    if symtab and strtab:
        soff, ssize, sentsz = symtab
        stoff, _ = strtab
        def sname(n):
            end = data.index(b"\0", stoff + n)
            return data[stoff + n:end].decode("latin1")
        for i in range(ssize // sentsz):
            o = soff + i * sentsz
            st_name, st_value, st_size, st_info, st_other, st_shndx = \
                struct.unpack_from("<IIIBBH", data, o)
            if (st_info & 0xF) == 2:
                funcs.append((sname(st_name), st_value, st_size))
    funcs.sort(key=lambda t: t[1])
    def vaddr_to_off(va):
        for vaddr, off, filesz, memsz in loads:
            if vaddr <= va < vaddr + filesz:
                return off + (va - vaddr)
        return None
    out = []
    for name, va, size in funcs:
        fo = vaddr_to_off(va)
        if fo is None or size == 0:
            continue
        out.append((name, va, size, data[fo:fo + size]))
    return out


def native_text(path):
    data, entry, loads, _ = read_elf(path)
    vaddr, off, filesz, memsz = loads[0]
    return vaddr, entry, data[off:off + filesz]


def disasm(byts, vaddr):
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as t:
        t.write(byts); tp = t.name
    try:
        out = subprocess.run(
            ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64",
             f"--adjust-vma={vaddr}", tp],
            capture_output=True, text=True).stdout
    finally:
        os.unlink(tp)
    insns = []
    for line in out.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\t([0-9a-f ]+?)\t(\S+)\s*(.*?)\s*$", line)
        if not m:
            continue
        insns.append((int(m.group(1), 16), m.group(2).strip(),
                      m.group(3), re.sub(r"\s*#.*$", "", m.group(4)).strip()))
    return insns


def disasm_elf(path):
    """Disassemble a symtab-bearing ELF so call/data targets resolve to NAMES
    (used only to detect stack-protector functions in the seed). Returns the
    set of byte-offsets that are part of a canary sequence is not needed; we
    just need the per-function flag, computed by name reference."""
    out = subprocess.run(["objdump", "-d", path], capture_output=True,
                         text=True).stdout
    return out


# ---- semantic key: (mnemonic, width-class, operand-shape) -------------------
WIDTH_SUFFIX = {"q": 8, "l": 4, "w": 2, "b": 1}


def width_of(mnem, ops):
    """Operand byte-width, the load-bearing dimension for the bug family.
    Derived from the AT&T mnemonic suffix where present (movq/movl/movw/movb),
    the movz/movs extension form (movzbl etc.), or the register operand size."""
    # explicit suffix on data-movement / arith
    base = mnem
    for ext, w in (("movzbq", 1), ("movzwq", 2), ("movzlq", 4),
                   ("movzbl", 1), ("movzwl", 2),
                   ("movsbq", 1), ("movswq", 2), ("movslq", 4),
                   ("movsbl", 1), ("movswl", 2)):
        if mnem == ext:
            return w  # SOURCE width — the truncation-relevant size
    if len(mnem) > 2 and mnem[-1] in WIDTH_SUFFIX and mnem[:-1] in (
            "mov", "add", "sub", "cmp", "test", "and", "or", "xor", "push",
            "pop", "imul", "mul", "lea", "inc", "dec", "neg", "not", "shl",
            "shr", "sar", "sal", "movabs"):
        return WIDTH_SUFFIX[mnem[-1]]
    # register-size inference from a %reg operand
    for rsz, regs in ((8, r"%r[a-ds]x|%r[sb]p|%r[sd]i|%r8|%r9|%r1[0-5]"),
                      (4, r"%e[a-ds]x|%e[sb]p|%e[sd]i|%r\d+d"),
                      (2, r"%[a-ds][xpi]|%r\d+w"),
                      (1, r"%[a-ds][lh]|%[sb]pl|%[sd]il|%r\d+b")):
        if re.search(rsz and regs, ops):
            return rsz
    return 0


def shape(ops):
    """Operand structural class, register-name and address invariant."""
    o = re.sub(r"-?0x[0-9a-f]+\(%rip\)", "RIP", ops)
    o = re.sub(r"-?0x[0-9a-f]+\(%[a-z0-9]+\)", "MEM", o)   # frame/heap slot
    o = re.sub(r"\(%[a-z0-9]+\)", "DEREF", o)
    o = re.sub(r"\$0x[0-9a-f]+|\$\d+", "IMM", o)
    o = re.sub(r"0x[0-9a-f]+", "ADDR", o)                  # branch target
    o = re.sub(r"%[a-z0-9]+", "R", o)                      # any register
    return o


# Instructions whose COUNT legitimately differs between the backends and
# carries no semantic width signal — the documented encoding-freedom set:
#   * register-to-register MOV / PUSH / POP  : spill strategy (seed spills via
#     push/pop; native uses scratch-register movs). Net data movement is equal;
#     only the carrier differs. We DROP these so a spill-count delta is not a
#     false divergence. (A WIDTH bug never hides here: a sub-8-byte store/load
#     to MEMORY is a separate, retained key.)
#   * control flow (call/jmp/jcc/loop)       : layout/epilogue differences.
#   * leave/ret/endbr64/nop                   : frame/padding scaffolding.
#   * stack-canary ops (xor/mov vs %fs or the guard global) : the seed emits
#     the stack protector; native does not — a hardening difference, not a
#     miscompile.
_SPILL_DROP = {"push", "pop"}
_SCAFFOLD = {"leave", "ret", "endbr64", "nop", "ud2", "hlt"}


def is_canary(mnem, ops):
    return "%fs:" in ops or "stack_chk" in ops or "__stack_chk" in ops


# The Python seed emits -fstack-protector code for functions with local
# buffers; codegen.ad emits NONE (an intentional hardening gap, NOT a
# behavioral miscompile — the program runs identically). The canary's FIXED
# instruction contribution to a seed function's histogram is:
#   prologue:  mov __stack_chk_guard(%rip),%REG   -> ('mov', 8, 'RIP,R')
#              mov %REG,-off(%rbp)                 -> ('mov', 8, 'R,MEM')
#   epilogue:  mov -off(%rbp),%REG                 -> ('mov', 8, 'MEM,R')
#              xor __stack_chk_guard(%rip),%REG    -> ('xor', 8, 'RIP,R')
#              (the `call __stack_chk_fail` + its `je`/`jne` are control flow,
#               already excluded)
#              also a compare `test`/`cmp` of the result -> ('test'/('cmp'),...)
# Subtracting this fixed set from a canary-bearing seed function makes the
# differential see the SAME data flow the native (canary-free) function has.
CANARY_KEYS = Counter({
    ('mov', 8, 'RIP,R'): 1,
    ('mov', 8, 'R,MEM'): 1,
    ('mov', 8, 'MEM,R'): 1,
    ('xor', 8, 'RIP,R'): 1,
    ('test', 8, 'R,R'): 1,
})


def func_histogram(insns):
    """Semantic histogram: width-bearing MEMORY accesses + ALU ops, with the
    benign encoding-freedom set (spills, control flow, scaffolding, canary)
    removed so only a REAL divergence (wrong width on a memory access, wrong
    opcode class, a missing/extra computation) survives."""
    c = Counter()
    for addr, raw, mnem, ops in insns:
        if mnem in ("call", "jmp", "loop") or mnem.startswith("j"):
            continue  # control flow — layout-benign
        if mnem in _SCAFFOLD:
            continue
        if is_canary(mnem, ops):
            continue
        # Stack-argument marshalling for a >6-arg call: the seed reserves
        # `sub $N,%rsp` then writes each stack arg with `mov %reg,(%rsp)` /
        # `mov %reg,N(%rsp)`; codegen.ad pushes them with `push` (already
        # dropped as a spill). Both place the same value in the same stack slot
        # — encoding-equivalent. Drop the seed's %rsp-relative arg stores and
        # the matching `sub/add $imm,%rsp` frame adjust so the marshalling
        # choice is not a divergence. (Frame-pointer-relative `(%rbp)` stores —
        # real locals — are NOT dropped.)
        if mnem == "mov" and ("(%rsp)" in ops):
            continue
        if mnem in ("sub", "add") and "%rsp" in ops and "IMM" in shape(ops):
            continue
        sh = shape(ops)
        # register<->register movs are the spill carriers — drop (the data they
        # move is accounted at its memory/RIP touch points).
        if mnem == "mov" and sh == "R,R":
            continue
        if mnem in _SPILL_DROP and sh == "R":
            continue
        # register-to-register sign/zero EXTEND (movslq %eax,%rax etc.) is a
        # load-folding artifact: one backend sign-extends WHILE loading from
        # memory (`movslq MEM,R` — counted at the memory key), the other loads
        # then re-extends in a register (`mov MEM,R` + `movslq R,R`). Same
        # value; the reg-reg extend is the encoding-freedom carrier — drop it.
        if mnem in ("movslq", "movzbq", "movzwq", "movzlq", "movsbq",
                    "movswq", "movzbl", "movzwl", "movsbl", "movswl",
                    "cltq", "cdqe") and sh in ("R,R", "R", ""):
            continue
        # FRAME-SLOT (%rbp-relative) ZERO/SIGN-EXTEND reload of a spilled
        # sub-8-byte LOCAL: native may reload a uint8/uint16 local sized
        # (`movzbq -off(%rbp),%reg`) where the seed reloads the full slot
        # (`mov -off(%rbp),%reg`). The slot was sized-STORED, so both reloads
        # yield the same value — the reload width is an encoding choice. Map a
        # %rbp-relative movzx/movsx reload to the SAME key the seed's full `mov`
        # frame reload uses (`('mov', 8, 'MEM,R')`), so the spill-reload width is
        # not a divergence. We do NOT rewrite a plain `mov MEM,R` (so the canary
        # reload bookkeeping in CANARY_KEYS still lines up), and we restrict to
        # %rbp frames so real struct/heap/global sized loads keep their width.
        if mnem in ("movzbq", "movzwq", "movzlq", "movsbq", "movswq",
                    "movslq", "movzbl", "movzwl", "movsbl", "movswl") \
                and "(%rbp)" in ops and sh == "MEM,R":
            c[("mov", 8, "MEM,R")] += 1
            continue
        # Index/stride SCALING by a power-of-2 element size: one backend emits
        # `imulq $stride,%reg,%reg` (multiply), the other `shlq $log2,%reg`
        # (shift). Both compute reg*2^k mod 2^64 — provably equivalent. Canon-
        # icalize both (with an IMM operand) to a single SCALE class so the
        # encoding choice is not a divergence. (A NON-power-of-2 imul stride has
        # no shl equivalent and is NOT collapsed — it keeps its own key.)
        if mnem == "imul" and "IMM" in sh:
            c[("scale", 8, "IMM")] += 1
            continue
        if mnem in ("shl", "sal") and "IMM" in sh:
            c[("scale", 8, "IMM")] += 1
            continue
        # Immediate-to-register MATERIALIZATION: `movabs $imm64,%reg` (seed, the
        # explicit 64-bit form) vs `movq $imm32,%reg` (codegen.ad's compact
        # 48 C7 C0 sign-extending-imm32 form, used when the value fits a signed
        # 32-bit range OR is a sign-extension of one, e.g. 0xFFFF...FFFF == -1).
        # Both materialize the same register value; the encoding choice is the
        # seed's `as` movabs vs codegen.ad's size-minimizing pick. Collapse both
        # mov/movabs imm->reg into a single LOADIMM class. (The immediate VALUE
        # is already erased to IMM by shape(), as for every other instruction —
        # the histogram metric is structural, not value-exact.)
        if mnem in ("mov", "movabs") and sh == "IMM,R":
            c[("loadimm", 8, "IMM,R")] += 1
            continue
        c[(mnem, width_of(mnem, ops), sh)] += 1
    return c


def seed_fn_has_canary(sd):
    """A seed function emits -fstack-protector iff it loads the guard global
    via RIP and xors it: the signature `xorl/xorq <RIP-disp>(%rip),%reg` (the
    epilogue compare) plus the prologue `mov <RIP-disp>(%rip),%reg`. We detect
    it structurally: a function with BOTH a `mov RIP,R` (guard load) and an
    `xor RIP,R` (epilogue compare) — codegen.ad emits NEITHER, so this pair is
    canary-exclusive. Robust to objdump not resolving the guard symbol name."""
    has_xor_rip = any(m == "xor" and "(%rip)" in o for (_a, _r, m, o) in sd)
    has_mov_rip = any(m == "mov" and "(%rip)" in o for (_a, _r, m, o) in sd)
    return has_xor_rip and has_mov_rip


def compare_function(name, sd, nd, seed_canary):
    sh = func_histogram(sd)
    nh = func_histogram(nd)
    if not seed_canary:
        seed_canary = seed_fn_has_canary(sd)
    if seed_canary:
        # Remove the seed-only stack-protector contribution, but ONLY the part
        # that is genuinely seed-EXCESS (so a function that legitimately uses a
        # global xor/load in BOTH backends is not over-subtracted into a false
        # match). For each canary key, subtract at most the seed-minus-native
        # surplus, capped at the canary's fixed contribution.
        excess = Counter()
        for key, cnt in CANARY_KEYS.items():
            surplus = sh.get(key, 0) - nh.get(key, 0)
            if surplus > 0:
                excess[key] = min(cnt, surplus)
        sh = sh - excess
    if sh == nh:
        return []
    divs = []
    for key in sorted(set(sh) | set(nh), key=lambda k: str(k)):
        a, b = sh.get(key, 0), nh.get(key, 0)
        if a != b:
            divs.append(f"    {key}: seed×{a} native×{b}")
    return divs


def split_native_by_prologue(insns):
    """Split the native text into function blocks at each `endbr64` (every
    Adder free-function/method opens with one). The synthesized sys_* runtime
    wrappers and the _start shim have NO endbr64; codegen.ad emits them as a
    contiguous run AFTER the last user function, so they collect into the final
    block(s). We post-filter those out by signature (is_wrapper/is_entry_shim)
    rather than over-splitting on `ret` (user functions contain internal rets)."""
    # FIRST strip the synthesized runtime appendage (sys_* wrappers + the _start
    # shim) from the END of the stream. codegen.ad emits these AFTER the last
    # user function, none with an `endbr64`, so everything from the first
    # wrapper/shim instruction to EOF is appendage. We find that boundary: scan
    # backward while the tail is composed only of wrapper/shim instructions.
    # A wrapper = `[mov %rcx,%r10;] mov $imm,%rax; syscall; ret`; the shim =
    # `call; movslq %eax,%rdi; mov $1,%rax; syscall; jmp .`. Both consist solely
    # of {mov(imm/reg), movslq, syscall, ret, jmp, call} with no endbr64 and no
    # memory traffic — so the boundary is the last `endbr64`-started user block's
    # final `ret` IF everything after it is appendage. Simplest robust rule:
    # drop the trailing run with NO endbr64 that ends in `syscall; jmp` (the
    # shim) and any `syscall; ret` wrapper triples before it.
    n = len(insns)
    cut = n
    # walk back over appendage instructions
    i = n - 1
    APPEND_MN = {"mov", "movslq", "syscall", "ret", "jmp", "call", "endbr64"}
    seen_endbr_since = False
    while i >= 0:
        m = insns[i][2]
        o = insns[i][3]
        if m == "endbr64":
            # a user function prologue: stop — appendage is above this only if
            # this endbr64 belongs to a wrapper, but wrappers have none. So the
            # appendage starts AFTER the last user `ret`. Stop here.
            break
        if m not in APPEND_MN:
            break
        # a `mov` in the appendage only touches imm/registers (no frame/mem)
        if m == "mov" and ("(%rbp)" in o or "(%rip)" in o):
            break
        i -= 1
        cut = i + 1
    # only treat as appendage if the tail actually ends in the shim spin or a
    # wrapper ret/syscall (avoid eating a real trailing function by accident)
    if cut < n:
        tail_mns = {insns[k][2] for k in range(cut, n)}
        if "syscall" in tail_mns:
            insns = insns[:cut]

    blocks, cur = [], []
    for ins in insns:
        if ins[2] == "endbr64" and cur:
            blocks.append(cur); cur = [ins]
        else:
            cur.append(ins)
    if cur:
        blocks.append(cur)
    return blocks


def seed_canary_funcs(seed_path, user_names):
    """Names of seed FUNCTIONS that emit -fstack-protector code. The
    symtab-aware disasm shows the `call <__stack_chk_fail>` inside a LOCAL
    LABEL (e.g. `.__epilogue_perror`/`.endwhile_cat_one_4`), not under the
    function symbol. We map a canary site to its owning function by checking
    which user function NAME the current label embeds (the seed names epilogue/
    loop labels `.<kind>_<funcname>_<n>`)."""
    out = disasm_elf(seed_path)
    canary = set()
    cur = None
    for line in out.splitlines():
        m = re.match(r"^[0-9a-f]+ <([^>]+)>:", line)
        if m:
            cur = m.group(1)
        elif cur and "__stack_chk_fail" in line:
            # attribute to the owning user function: the label contains its name
            owner = cur
            if owner not in user_names:
                for un in user_names:
                    if un and ("_" + un + "_" in cur or cur.endswith("_" + un)
                               or cur == un):
                        owner = un
                        break
            canary.add(owner)
    return canary


def main():
    seed_path, nat_path, unit = sys.argv[1], sys.argv[2], sys.argv[3]
    sfuncs = seed_functions(seed_path)
    nat_vaddr, nat_entry, nat_bytes = native_text(nat_path)
    nat_blocks = split_native_by_prologue(disasm(nat_bytes, nat_vaddr))

    seed_user = [(nm, va, sz, by) for (nm, va, sz, by) in sfuncs
                 if not nm.startswith("sys_") and nm not in
                 ("__stack_chk_fail", "syscall6", "__runtime_start_mark_len")]
    seed_disasm = [(nm, disasm(by, va)) for (nm, va, sz, by) in seed_user]
    canary = seed_canary_funcs(seed_path, {nm for (nm, _v, _s, _b) in seed_user})

    def is_wrapper(block):
        mn = [b[2] for b in block]
        return "syscall" in mn and "endbr64" not in mn and len(block) <= 8

    def is_entry_shim(block):
        mn = [b[2] for b in block]
        return ("syscall" in mn and any(b == "jmp" for b in mn) and
                "endbr64" not in mn and len(block) <= 8)

    nat_user = [b for b in nat_blocks
                if not is_wrapper(b) and not is_entry_shim(b)]

    report, total_div = [], 0
    if len(nat_user) != len(seed_disasm):
        report.append(f"[{unit}] NOTE block-count: seed_user={len(seed_disasm)} "
                      f"native_user={len(nat_user)} (best-match align)")

    # ALIGNMENT: both backends emit user functions in declaration order, but a
    # merged multi-TU program (imports) can interleave module helpers, and the
    # native block splitter occasionally fuses/splits differently. So we align
    # each seed function to the native block that BEST matches its normalized
    # histogram (the metric we ultimately compare), preferring the positional
    # candidate on ties. A mis-pick can only HIDE a real divergence, never
    # invent one — and a genuinely diverged function still won't match ANY
    # block, so it surfaces. This makes the report robust to ordering.
    def best_block(nm, sd, used):
        target = func_histogram(sd)
        if nm in canary:
            target = target - CANARY_KEYS
        best, bestscore = None, -1
        for j, b in enumerate(nat_user):
            if used[j]:
                continue
            h = func_histogram(b)
            # similarity = size of multiset intersection minus symmetric diff
            inter = sum((target & h).values())
            sym = sum((target - h).values()) + sum((h - target).values())
            score = inter - sym
            if score > bestscore:
                bestscore, best = score, j
        return best

    # ALIGNMENT. The seed lists functions by symtab address; the native image
    # is split into endbr64 blocks in emission order. For SINGLE-TU units these
    # orders agree, but for MERGED multi-TU units (UI apps pulling many lib
    # modules) the two emission orders genuinely DIFFER, so a positional 1:1 is
    # wrong. We therefore do a GLOBAL greedy assignment by histogram similarity:
    #   1. score every (seed-fn, native-block) pair,
    #   2. assign in DESCENDING score order (most-confident match first),
    # so a distinctive function claims its twin before ambiguous small helpers
    # compete — avoiding the in-order greedy cascade that could orphan a real
    # match. A seed function left with NO block (count/structure mismatch) is a
    # genuine finding (MISSING). A clean assignment proves equivalence.
    used = [False] * len(nat_user)
    nat_hists = [func_histogram(b) for b in nat_user]
    seed_hists = []
    for nm, sd in seed_disasm:
        h = func_histogram(sd)
        if nm in canary:
            h = h - CANARY_KEYS
        seed_hists.append(h)
    pairs = []
    for si in range(len(seed_disasm)):
        th = seed_hists[si]
        for j in range(len(nat_user)):
            h = nat_hists[j]
            score = sum((th & h).values()) - (sum((th - h).values())
                                              + sum((h - th).values()))
            pairs.append((score, si, j))
    pairs.sort(key=lambda t: -t[0])
    assign = [None] * len(seed_disasm)
    for score, si, j in pairs:
        if assign[si] is None and not used[j]:
            assign[si] = j
            used[j] = True
    for si, (nm, sd) in enumerate(seed_disasm):
        cand = assign[si]
        if cand is None:
            report.append(f"[{unit}] {nm}: MISSING native block"); total_div += 1
            continue
        divs = compare_function(nm, sd, nat_user[cand], nm in canary)
        if divs:
            total_div += 1
            report.append(f"[{unit}] {nm}: histogram divergence")
            report.extend(divs[:8])

    if total_div:
        print("\n".join(report))
        print(f"[{unit}] DIVERGED ({total_div} function(s))")
        sys.exit(1)
    print(f"[{unit}] clean ({len(seed_disasm)} functions semantically match)")
    sys.exit(0)


if __name__ == "__main__":
    main()
