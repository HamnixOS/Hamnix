#!/usr/bin/env python3
# scan_oob.py — STATIC out-of-bounds store/load scanner for the whole-kernel
# LLVM IR (`build/kllvm/kernel_main.ll`) emitted by the Adder LLVM backend.
#
# Two classes of defect are modelled, both purely from the textual `.ll` (no
# clang, no run):
#
#   (A) CONSTANT-OFFSET OOB  (Phase 5i)
#       %a = ptrtoint [N x i8]* @sym to i64
#       %b = add i64 %a, CONST            (CONST + width > N)  -> OOB
#     A global accessed at a fixed byte offset beyond its declared [N x i8].
#
#   (B) VARIABLE-INDEX / WRONG-STRIDE OOB  (Phase 5l — this extension)
#       %a  = ptrtoint [N x i8]* @sym to i64        ; array base
#       %m  = mul i64 %i, STRIDE                     ; i * element-stride
#       %b  = add i64 %a, %m                         ; base + i*STRIDE
#       %c  = add i64 %b, FIELDOFF                   ; + struct field offset
#       %p  = inttoptr i64 %c to iW*
#       store iW %v, iW* %p
#     The Adder emitter computes an array-of-struct / nested-array element
#     address as base + i*STRIDE (+ inner j*STRIDE2) (+ FIELDOFF). If the chosen
#     STRIDE != the true element size (e.g. the innermost element width was used
#     instead of the struct's st_total, or a nested stride is off by the inner
#     dimension), a large index `i` overruns the global into the next `.bss`
#     global — a layout-sensitive wild store that constant-offset scanning (A)
#     cannot see. This pass models the base+index*stride+const chains and flags:
#       TILE     : STRIDE does not evenly divide the global size N
#                  (a correct element stride must tile the array exactly)
#       FIELDOVF : FIELDOFF + access-width > the OUTER (largest) stride
#                  (the constant field offset overruns one whole element ⇒
#                   the element stride is too small)
#       INCONSIST: the same global is indexed with two DIFFERENT strides in the
#                  program (one of them is wrong)
#
# Usage:  scripts/scan_oob.py build/kllvm/kernel_main.ll
# Exit status is always 0 (report-only); findings are printed and summarised.
import re, sys

path = sys.argv[1] if len(sys.argv) > 1 else "build/kllvm/kernel_main.ll"
lines = open(path).read().splitlines()

# ---- global [N x i8] sizes ------------------------------------------------
gsize = {}
gre = re.compile(r'^@([A-Za-z0-9_.$]+)\s*=.*?\[(\d+) x i8\]')
for ln in lines:
    m = gre.match(ln)
    if m:
        gsize[m.group(1)] = int(m.group(2))

# ---- instruction patterns -------------------------------------------------
sym = r'([%@]?[A-Za-z0-9_.$]+)'
ptrtoint_re = re.compile(r'%(\S+) = ptrtoint \[(\d+) x i8\]\* @([A-Za-z0-9_.$]+) to i64')
mul_re      = re.compile(r'%(\S+) = mul(?: nsw| nuw)* i64 ' + sym + r', ' + sym)
shl_re      = re.compile(r'%(\S+) = shl(?: nsw| nuw)* i64 ' + sym + r', (\d+)')
add_re      = re.compile(r'%(\S+) = add(?: nsw| nuw)* i64 ' + sym + r', ' + sym)
inttoptr_re = re.compile(r'%(\S+) = inttoptr i64 %(\S+) to (i\d+|double|float)\*')
store_re    = re.compile(r'store (?:volatile )?(i\d+|double|float) \S+, (i\d+|double|float)\* %(\S+)')
load_re     = re.compile(r'%(\S+) = load (?:volatile )?(i\d+|double|float), (i\d+|double|float)\* %(\S+)')
def_re      = re.compile(r'^define .*@([A-Za-z0-9_.$]+)\(')

width = {'i1':1,'i8':1,'i16':2,'i32':4,'i64':8,'float':4,'double':8}

def is_int_const(tok):
    return re.fullmatch(r'-?\d+', tok) is not None

# ---- per-value symbolic address model -------------------------------------
# sym_of[val] = dict(sym=name|None, size=N, off=const, strides=set(), scaled=bool)
#   sym=None with scaled=True  => a pure "index*stride" term (no base yet)
#   sym=name                    => base [+ const off] [+ index terms]
cur_fn = None
sym_of = {}
findings = []              # (severity, kind, fn, sym, N, stride/off, width, text)
stride_by_sym = {}         # sym -> set of strides seen (INCONSIST check)

def rec_stride(name, s):
    stride_by_sym.setdefault(name, set()).add(s)

for ln in lines:
    d = def_re.match(ln)
    if d:
        cur_fn = d.group(1)
        sym_of = {}
        continue
    s = ln.strip()

    m = ptrtoint_re.search(s)
    if m:
        sym_of[m.group(1)] = dict(sym=m.group(3), size=int(m.group(2)),
                                  off=0, strides=set(), scaled=False)
        continue

    m = mul_re.search(s)
    if m:
        dst, a, b = m.group(1), m.group(2), m.group(3)
        ac, bc = is_int_const(a), is_int_const(b)
        if ac and bc:
            # const * const -> a pure CONSTANT term (e.g. `mul i64 0, 8` from a
            # constant-folded `[0]` index): fold the product into `off`, NOT a
            # stride. Treating it as a variable stride false-positives on every
            # constant-index cast-pointer store.
            sym_of[dst] = dict(sym=None, size=0, off=int(a) * int(b),
                               strides=set(), scaled=True)
        elif bc:            # variable * STRIDE  -> record the stride
            sym_of[dst] = dict(sym=None, size=0, off=0,
                               strides={int(b)}, scaled=True)
        elif ac:            # STRIDE * variable
            sym_of[dst] = dict(sym=None, size=0, off=0,
                               strides={int(a)}, scaled=True)
        # variable * variable: unresolvable stride -> leave untracked
        continue

    m = shl_re.search(s)
    if m:
        dst, a, sh = m.group(1), m.group(2), int(m.group(3))
        sym_of[dst] = dict(sym=None, size=0, off=0,
                           strides={1 << sh}, scaled=True)
        continue

    m = add_re.search(s)
    if m:
        dst, a, b = m.group(1), m.group(2), m.group(3)
        ael = sym_of.get(a[1:]) if a.startswith('%') else None
        bel = sym_of.get(b[1:]) if b.startswith('%') else None
        # base + const
        if ael is not None and is_int_const(b):
            e = dict(ael); e['off'] = e['off'] + int(b); sym_of[dst] = e; continue
        if bel is not None and is_int_const(a):
            e = dict(bel); e['off'] = e['off'] + int(a); sym_of[dst] = e; continue
        # combine two tracked values (base + index-term, or index + index)
        if ael is not None and bel is not None:
            base = ael if ael['sym'] is not None else bel
            other = bel if ael['sym'] is not None else ael
            e = dict(sym=base['sym'], size=base['size'],
                     off=base['off'] + other['off'],
                     strides=set(base['strides']) | set(other['strides']),
                     scaled=base['scaled'] and other['scaled'])
            sym_of[dst] = e
            continue
        # base(or index) + untracked value: propagate the tracked side
        if ael is not None:
            sym_of[dst] = dict(ael); continue
        if bel is not None:
            sym_of[dst] = dict(bel); continue
        continue

    m = inttoptr_re.search(s)
    if m:
        src = m.group(2)
        w = width.get(m.group(3), 8)
        e = sym_of.get(src)
        if e is not None:
            e = dict(e); e['width'] = w
            sym_of[m.group(1)] = e
        continue

    # store / load through a tracked pointer
    pv = None; w = 8
    m = store_re.search(s)
    if m:
        pv = m.group(3); w = width.get(m.group(2), 8)
    else:
        m = load_re.search(s)
        if m:
            pv = m.group(4); w = width.get(m.group(3), 8)
    if pv is None:
        continue
    e = sym_of.get(pv)
    if e is None or e['sym'] is None:
        continue
    name, N, off = e['sym'], e['size'], e['off']
    strides = sorted(x for x in e['strides'] if x > 0)
    w = e.get('width', w)

    if not strides:
        # constant-offset access (class A)
        if off + w > N:
            findings.append((3, 'CONSTOOB', cur_fn, name, N, off, w, s))
        continue

    # class B — variable index/stride.
    #   The LARGEST stride is the presumptive OUTER (array-of-struct element)
    #   stride and MUST tile the global exactly (N % stride == 0). Smaller
    #   strides are inner-array strides bounded WITHIN the element, so they are
    #   NOT required to divide N — checking them would false-positive on every
    #   legitimate nested `g[i].inner[j]` access. When the outer index has been
    #   constant-folded into `off` (off >= maxs), the true outer stride is not
    #   visible in this store, so the TILE check is suppressed (off carries it).
    maxs = max(strides)
    for st in strides:
        rec_stride(name, st)
    if off < maxs and N % maxs != 0:
        findings.append((3, 'TILE', cur_fn, name, N, maxs, w, s))
    # FIELDOVF: the constant field offset within the indexed element plus the
    # access width must fit inside ONE element (the outer stride). off >= maxs
    # here means the whole reach spills past the element the outer stride tiles
    # — either a too-small element stride or a folded outer index; both worth a
    # look, ranked below TILE.
    if off + w > maxs and N % maxs == 0 and off >= maxs:
        findings.append((2, 'FIELDOVF', cur_fn, name, N, maxs, off + w, s))

# ---- inconsistent-stride check (whole program) ----------------------------
for name, sts in stride_by_sym.items():
    if len(sts) > 1:
        findings.append((1, 'INCONSIST', '(global)', name,
                         gsize.get(name, 0), sorted(sts), 0,
                         'strides=' + ','.join(str(x) for x in sorted(sts))))

# ---- report ---------------------------------------------------------------
order = {'CONSTOOB':0, 'TILE':1, 'FIELDOVF':2, 'INCONSIST':3}
findings.sort(key=lambda f: (-f[0], order.get(f[1], 9), f[3]))
for sev, kind, fn, name, N, val, w, txt in findings:
    if kind == 'INCONSIST':
        print(f"[{kind}] @{name} size={N} strides={val}")
    elif kind == 'CONSTOOB':
        print(f"[{kind}] fn={fn} @{name} size={N} off={val} w={w}  :: {txt}")
    elif kind == 'TILE':
        print(f"[{kind}] fn={fn} @{name} size={N} stride={val} (N%stride={N%val})  :: {txt}")
    else:  # FIELDOVF
        print(f"[{kind}] fn={fn} @{name} size={N} max_stride={val} reach={w}  :: {txt}")

nA = sum(1 for f in findings if f[1] == 'CONSTOOB')
nT = sum(1 for f in findings if f[1] == 'TILE')
nF = sum(1 for f in findings if f[1] == 'FIELDOVF')
nI = sum(1 for f in findings if f[1] == 'INCONSIST')
print(f"---")
print(f"constant-offset OOB (A) : {nA}")
print(f"wrong-stride TILE   (B) : {nT}")
print(f"field-overflow FIELDOVF : {nF}")
print(f"inconsistent-stride     : {nI}")
print(f"globals with size       : {len(gsize)}")
