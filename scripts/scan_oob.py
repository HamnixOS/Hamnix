#!/usr/bin/env python3
# Scan the whole-kernel .ll for constant-offset OOB accesses into a global:
#   %a = ptrtoint [N x i8]* @sym to i64
#   ... %b = add i64 %a, CONST      (CONST >= N)  -> OOB store/load
# Tracks SSA value -> (symbol, size, base_const_offset) within each function,
# following `add i64 %x, CONST` chains. Flags any inttoptr+store/load where the
# accumulated constant offset + access width exceeds the symbol size.
import re, sys

path = sys.argv[1]
lines = open(path).read().splitlines()

# global sizes: @sym = ... global [N x i8]  OR  [N x i8]*
gsize = {}
gre = re.compile(r'^@([A-Za-z0-9_.]+)\s*=.*?\[(\d+) x i8\]')
for ln in lines:
    m = gre.match(ln)
    if m:
        gsize[m.group(1)] = int(m.group(2))

ptrtoint_re = re.compile(r'%(\S+) = ptrtoint \[(\d+) x i8\]\* @([A-Za-z0-9_.]+) to i64')
add_re = re.compile(r'%(\S+) = add i64 %(\S+), (\d+)')
add_re2 = re.compile(r'%(\S+) = add i64 (\d+), %(\S+)')
inttoptr_re = re.compile(r'%(\S+) = inttoptr i64 %(\S+) to (i\d+|double|float)\*')
store_re = re.compile(r'store (i\d+|double|float) \S+, (i\d+|double|float)\* %(\S+)')
load_re = re.compile(r'%(\S+) = load (i\d+|double|float), (i\d+|double|float)\* %(\S+)')
def_re = re.compile(r'^define .*@([A-Za-z0-9_.]+)\(')

width = {'i8':1,'i16':2,'i32':4,'i64':8,'float':4,'double':8}

cur_fn = None
# val -> (sym, size, offset)
sym_of = {}
findings = []

for ln in lines:
    d = def_re.match(ln)
    if d:
        cur_fn = d.group(1)
        sym_of = {}
        continue
    s = ln.strip()
    m = ptrtoint_re.search(s)
    if m:
        sym_of[m.group(1)] = (m.group(3), int(m.group(2)), 0)
        continue
    m = add_re.search(s)
    if m and m.group(2) in sym_of:
        sym, sz, off = sym_of[m.group(2)]
        sym_of[m.group(1)] = (sym, sz, off + int(m.group(3)))
        continue
    m = add_re2.search(s)
    if m and m.group(3) in sym_of:
        sym, sz, off = sym_of[m.group(3)]
        sym_of[m.group(1)] = (sym, sz, off + int(m.group(2)))
        continue
    m = inttoptr_re.search(s)
    if m and m.group(2) in sym_of:
        sym, sz, off = sym_of[m.group(2)]
        w = width.get(m.group(3),8)
        sym_of[m.group(1)] = ('PTR:'+sym, sz, off, w)
        # check bound
        if off + w > sz:
            findings.append((cur_fn, sym, sz, off, w, s))
        continue

for f in findings:
    print(f"OOB fn={f[0]} @{f[1]} size={f[2]} off={f[3]} w={f[4]}  :: {f[5]}")
print(f"total OOB constant-offset accesses: {len(findings)}")
print(f"globals with size: {len(gsize)}")
