#!/usr/bin/env python3
# scripts/kllvm_force_native.py — Phase-5d A/B native-substitution helper.
#
# Given the whole-kernel LLVM IR (.ll) and a set of function names, rewrite each
# matching top-level `define <ret> @NAME(<params>) ... {  ... }` into a bare
# `declare <ret> @NAME(<paramtypes>)`. clang then leaves @NAME UNDEFINED in the
# LLVM object, so the hybrid link (`ld --allow-multiple-definition`, native
# main.o supplies the fallback) resolves ALL references — including internal
# LLVM callers — to the NATIVE-compiled copy. This is the proven Phase-5c
# technique to bisect which function's LLVM codegen is the miscompile.
#
# Usage: kllvm_force_native.py <in.ll> <out.ll> NAME [NAME ...]
import re
import sys

def strip_param_names(params):
    # "i64 %v1, ptr %v2" -> "i64, ptr" ; also drop param attrs before the type? at
    # -O0 the emit is just "<type> %name". Keep everything up to the %name token.
    parts = []
    depth = 0
    cur = ""
    for ch in params:
        if ch == '<' or ch == '(' or ch == '[' or ch == '{':
            depth += 1
        elif ch == '>' or ch == ')' or ch == ']' or ch == '}':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    out = []
    for p in parts:
        p = p.strip()
        if not p:
            continue
        # cut at the %name value token
        m = re.search(r"\s%\S+", p)
        if m:
            p = p[:m.start()].strip()
        out.append(p)
    return ", ".join(out)

def main():
    inf, outf = sys.argv[1], sys.argv[2]
    names = set(sys.argv[3:])
    def_re = re.compile(r"^define\s+(.*?)\s+(@[A-Za-z0-9_$.]+)\((.*)\)\s*(.*)\{\s*$")
    out = []
    i = 0
    lines = open(inf).read().splitlines()
    n = len(lines)
    subbed = []
    while i < n:
        line = lines[i]
        m = def_re.match(line)
        if m and m.group(2)[1:] in names:
            ret = m.group(1)
            name = m.group(2)
            params = m.group(3)
            decl = "declare %s %s(%s)" % (ret, name, strip_param_names(params))
            out.append(decl)
            subbed.append(name[1:])
            # skip body until a lone `}` at col 0
            i += 1
            while i < n and lines[i] != "}":
                i += 1
            i += 1  # skip the closing brace
            continue
        out.append(line)
        i += 1
    open(outf, "w").write("\n".join(out) + "\n")
    missing = names - set(subbed)
    sys.stderr.write("[force_native] substituted->native: %s\n" % ", ".join(sorted(subbed)))
    if missing:
        sys.stderr.write("[force_native] WARNING not found as define: %s\n" % ", ".join(sorted(missing)))

if __name__ == "__main__":
    main()
