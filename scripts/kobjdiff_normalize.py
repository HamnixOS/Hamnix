#!/usr/bin/env python3
"""kobjdiff_normalize.py — semantic native-vs-seed machine-code differential
for the bare-metal KERNEL object (init/main.ad, --target=x86_64-bare-metal).

Inputs: <seed.o> <native.o>
Both are ET_REL ELF64 x86-64 relocatable objects. UNLIKE the userland
harness (scripts/objdiff_normalize.py), the native bare-metal kernel object
KEEPS A SYMBOL TABLE: every Adder free-function/method is a FUNC symbol with
the SAME NAME in both backends. So we align PER SYMBOL NAME — no prologue
heuristics, no positional alignment, no block splitting. This closes the
systemic gap where kernel-only codegen divergences slipped past the userland
objdiff (which only covers user/*.ad).

Function boundaries:
  - SEED  : the GNU `as`-assembled .o gives each FUNC symbol a real st_size.
  - NATIVE: codegen.ad emits FUNC symbols with st_size==0, so we derive each
            function's extent as (next FUNC start within .text) - (this start).

Per matched function we reuse the EXACT same semantic histogram metric as the
userland harness (objdiff_normalize.func_histogram): the multiset of
(mnemonic, operand-width, operand-shape) keys with the documented benign
encoding-freedom set removed (register spills, control flow, scaffolding,
stack-canary, rsp arg-marshalling, scale-by-imul-vs-shl, imm materialization).
So register-scheduling / push-pop-vs-mov / address+reloc differences are
normalized away identically to userland; only a REAL width/opcode-class/
missing-op divergence survives.

Exit 0 + "clean" when zero functions diverge; exit 1 + a per-function key
delta list otherwise.

Usage:  python3 scripts/kobjdiff_normalize.py <seed.o> <native.o>
        OBJDIFF_VERBOSE=1 for extra notes.
        KOBJDIFF_ONLY="ns_walk,_resolve_path_uncached" to restrict to names.
"""
import os
import re
import struct
import subprocess
import sys
import tempfile
from collections import Counter

# Reuse the userland harness's normalization so the metric is IDENTICAL.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import objdiff_normalize as U  # noqa: E402

VERBOSE = os.environ.get("OBJDIFF_VERBOSE", "0") == "1"


def read_elf64(path):
    """Minimal ELF64 reader: returns (data, sections, symbols).

    sections: list of (name, sh_type, sh_offset, sh_size, sh_link, sh_entsize)
    symbols : list of (name, st_value, st_size, st_info, st_shndx)
    """
    with open(path, "rb") as f:
        data = f.read()
    assert data[:4] == b"\x7fELF" and data[4] == 2, "not ELF64"
    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]

    raw_sh = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        (sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size,
         sh_link, sh_info, sh_addralign, sh_entsize) = \
            struct.unpack_from("<IIQQQQIIQQ", data, off)
        raw_sh.append((sh_name, sh_type, sh_offset, sh_size, sh_link,
                       sh_entsize))

    shstr_off = raw_sh[e_shstrndx][2]

    def shname(n):
        end = data.index(b"\0", shstr_off + n)
        return data[shstr_off + n:end].decode("latin1")

    sections = []
    symtab = None
    strtab_off = None
    for idx, (sh_name, sh_type, sh_offset, sh_size, sh_link, sh_entsize) \
            in enumerate(raw_sh):
        nm = shname(sh_name)
        sections.append((nm, sh_type, sh_offset, sh_size, sh_link, sh_entsize))
        if nm == ".symtab":
            symtab = (sh_offset, sh_size, sh_link, sh_entsize)
        if nm == ".strtab":
            strtab_off = sh_offset

    symbols = []
    if symtab and strtab_off is not None:
        soff, ssize, slink, sentsz = symtab
        # .symtab's sh_link is the strtab index; honor it over name-guess.
        link_strtab_off = raw_sh[slink][2] if slink < len(raw_sh) else strtab_off

        def syname(n):
            end = data.index(b"\0", link_strtab_off + n)
            return data[link_strtab_off + n:end].decode("latin1")

        for i in range(ssize // sentsz):
            o = soff + i * sentsz
            st_name, st_info, st_other, st_shndx, st_value, st_size = \
                struct.unpack_from("<IBBHQQ", data, o)
            symbols.append((syname(st_name), st_value, st_size, st_info,
                            st_shndx))
    return data, sections, symbols


# Conditional-branch SIGNEDNESS classes. A loop-guard or comparison
# miscompiled from signed to unsigned (or vice versa) flips the jcc family
# here even when the histogram (which DROPS all control flow) sees nothing.
# Polarity (jl vs jge) flips legitimately between backends, so we collapse to
# the SIGNEDNESS class and count per function; a class-count delta is the
# value-level signal the histogram can't carry.
_SIGNED_JCC = {"jl", "jle", "jg", "jge", "jnge", "jnle", "jng", "jnl"}
_UNSIGNED_JCC = {"jb", "jbe", "ja", "jae", "jnae", "jnbe", "jna", "jnb",
                 "jc", "jnc"}


def branch_signedness(insns):
    """Counter over {'signed','unsigned'} conditional branches. je/jne and
    the flag-only jumps (js/jns/jo/jno/jp/jnp) carry no signedness and are
    excluded — they don't distinguish a signed-vs-unsigned compare bug."""
    c = Counter()
    for _addr, _raw, mnem, _ops in insns:
        if mnem in _SIGNED_JCC:
            c["signed"] += 1
        elif mnem in _UNSIGNED_JCC:
            c["unsigned"] += 1
    return c


def text_section(sections):
    for idx, (nm, sh_type, off, size, link, entsz) in enumerate(sections):
        if nm == ".text":
            return idx, off, size
    raise RuntimeError("no .text section")


def func_name_counts(path):
    """{name: number of distinct-address FUNC symbols with that name in .text}.

    The native compiler does NOT module-prefix-mangle a module-PRIVATE
    (leading-`_`) function name, so two modules' `_word_eq` (etc.) both emit a
    LOCAL FUNC symbol with the SAME bare name. codegen.ad resolve_calls() then
    patches a call to the FIRST same-named symbol — a cross-module CALL MIS-
    RESOLUTION when the two functions differ (e.g. dev.ad `_word_eq(s,lit)` vs
    devnet.ad `_word_eq(buf,pos,len,word)`). The seed has no such count (it
    mangles), so count>1 in the native flags a real symbol collision the
    .text-histogram cannot (the bytes are each individually fine; the LINK is
    wrong)."""
    data, sections, symbols = read_elf64(path)
    text_idx, _to, _ts = text_section(sections)
    from collections import Counter as _C
    c = _C()
    seen = set()
    for name, value, size, info, shndx in symbols:
        if (info & 0xF) != 2 or shndx != text_idx or not name:
            continue
        if (name, value) in seen:
            continue
        seen.add((name, value))
        c[name] += 1
    return c


def func_bytes(path):
    """Return {name: bytes} for every FUNC symbol in .text.

    Seed FUNCs carry st_size; native FUNCs have st_size==0 so we derive
    the extent from the next FUNC start within .text.
    """
    data, sections, symbols = read_elf64(path)
    text_idx, text_off, text_size = text_section(sections)

    funcs = []  # (name, value, size)
    for name, value, size, info, shndx in symbols:
        if (info & 0xF) != 2:           # STT_FUNC
            continue
        if shndx != text_idx:
            continue
        if not name:
            continue
        funcs.append((name, value, size))

    # Sort by address; derive missing sizes from the next function start.
    funcs.sort(key=lambda t: t[1])
    out = {}
    for i, (name, value, size) in enumerate(funcs):
        if size == 0:
            if i + 1 < len(funcs):
                size = funcs[i + 1][1] - value
            else:
                size = text_size - value
        if size <= 0:
            continue
        fo = text_off + value
        out[name] = data[fo:fo + size]
    return out


_MODPATH_RE = re.compile(r"[a-z0-9_]+")


def reconcile_names(seed_fns, nat_fns):
    """Map every native FUNC name to its seed twin.

    Names align DIRECTLY for exported (public) functions and for free
    functions whose bare name the seed did not module-prefix. But the SEED
    module-prefix-mangles every module-PRIVATE function (one whose name
    starts with `_`): `_absorb64` in sys/src/9/port/devrandom.ad becomes the
    seed symbol `sys_src_9_port_devrandom__absorb64` (the `/`-path with `/`
    -> `_`, then `_` joiner, then the bare name which itself starts with
    `_`, yielding the `__` boundary). The NATIVE compiler does NOT prefix
    private names — it emits the bare `_absorb64` as a LOCAL symbol (benign
    for linking: LOCAL symbols don't collide across the link).

    So we reconcile a native bare name `b` to the seed symbol `s` when
    `s` ends with `b`, the char before is the `_` modpath joiner, and the
    stripped prefix is a valid lowercase modpath. A few private names
    (`_align_up`, `_cstr_len`, ...) exist in >1 module and the native
    collapses them to one bare symbol per definition site; those map to a
    CANDIDATE LIST and the diff picks the best-histogram-matching seed twin
    (a mis-pick can only hide a divergence, never invent one).

    Returns: list of (native_name, native_bytes, [seed_bytes, ...]).
    """
    sset, nset = set(seed_fns), set(nat_fns)
    direct = sset & nset
    nat_only = sorted(nset - sset)
    seed_only = sorted(sset - nset)

    pairs = []  # (nat_name, nat_bytes, [seed_bytes,...])
    for name in sorted(direct):
        pairs.append((name, nat_fns[name], [seed_fns[name]]))

    # Index seed_only by trailing bare-name for cheap suffix lookup.
    unmatched_nat = []
    for nb in nat_only:
        cands = [s for s in seed_only
                 if len(s) > len(nb) and s.endswith(nb)
                 and s[-len(nb) - 1] == "_"
                 and _MODPATH_RE.fullmatch(s[:-len(nb)])]
        if cands:
            pairs.append((nb, nat_fns[nb], [seed_fns[c] for c in cands]))
        else:
            unmatched_nat.append(nb)
    return pairs, unmatched_nat, seed_only


def main():
    if len(sys.argv) < 3:
        print("usage: kobjdiff_normalize.py <seed.o> <native.o>",
              file=sys.stderr)
        sys.exit(2)
    seed_o, nat_o = sys.argv[1], sys.argv[2]
    only = None
    if os.environ.get("KOBJDIFF_ONLY"):
        only = set(os.environ["KOBJDIFF_ONLY"].split(","))

    seed_fns = func_bytes(seed_o)
    nat_fns = func_bytes(nat_o)
    pairs, unmatched_nat, seed_only = reconcile_names(seed_fns, nat_fns)

    if VERBOSE:
        print(f"[kobjdiff] seed FUNCs={len(seed_fns)} native FUNCs={len(nat_fns)}"
              f" reconciled-pairs={len(pairs)}")
        if unmatched_nat:
            print(f"[kobjdiff] native FUNCs with NO seed twin: "
                  f"{len(unmatched_nat)} e.g. {unmatched_nat[:6]}")

    # SYMBOL-COLLISION check: a native LOCAL FUNC name that appears MORE THAN
    # ONCE is two (or more) different modules' private `_helper` colliding
    # because the native driver does not module-mangle private names (the seed
    # does). codegen.ad resolve_calls() patches a call to the FIRST same-named
    # symbol, so a cross-module call to such a name MIS-LINKS when the two
    # bodies differ (the dev.ad `_word_eq(s,lit)` vs devnet.ad
    # `_word_eq(buf,pos,len,word)` live-root bug). This is invisible to the
    # per-function histogram (each body is individually fine); we surface it
    # here as a hard divergence so the gate catches the whole class.
    nat_counts = func_name_counts(nat_o)
    collisions = sorted(n for n, c in nat_counts.items() if c > 1)
    if only:
        collisions = [n for n in collisions if n in only]

    diverged = []
    compared = 0
    for name, nb, seed_cands in pairs:
        if only and name not in only:
            continue
        compared += 1
        # vaddr is irrelevant to the histogram metric (addresses are erased
        # by shape()); disasm at 0 for both.
        nd = U.disasm(nb, 0)
        # Among the (usually single) seed candidates, pick the one with the
        # best histogram overlap to the native, then report its divergence.
        best = None
        best_score = None
        best_branch = None
        nh = U.func_histogram(nd)
        nbr = branch_signedness(nd)
        for sbytes in seed_cands:
            sd = U.disasm(sbytes, 0)
            seed_canary = U.seed_fn_has_canary(sd)
            divs = U.compare_function(name, sd, nd, seed_canary)
            sh = U.func_histogram(sd)
            score = sum((sh & nh).values()) - (sum((sh - nh).values())
                                               + sum((nh - sh).values()))
            if best_score is None or score > best_score:
                best_score, best = score, divs
                # Branch-signedness delta against THIS best-aligned twin.
                sbr = branch_signedness(sd)
                bd = []
                for cls in ("signed", "unsigned"):
                    if sbr.get(cls, 0) != nbr.get(cls, 0):
                        bd.append(f"    branch[{cls}]: seed×{sbr.get(cls,0)} "
                                  f"native×{nbr.get(cls,0)}")
                best_branch = bd
        out_divs = list(best) if best else []
        # The branch-signedness signal is reported but, by default, only the
        # histogram gates PASS/FAIL (branch counts can differ on a legitimate
        # control-flow restructure). KOBJDIFF_STRICT_BRANCH=1 promotes it to a
        # hard divergence — useful when hunting a signedness miscompile.
        if best_branch:
            if os.environ.get("KOBJDIFF_STRICT_BRANCH") == "1":
                out_divs = out_divs + best_branch
            elif VERBOSE:
                print(f"[kobjdiff] NOTE {name}: branch-signedness delta "
                      f"{best_branch}")
        if out_divs:
            diverged.append((name, out_divs))

    print("=" * 60)
    print(f"[kobjdiff] kernel FUNCs compared: {compared}")
    if collisions:
        print(f"[kobjdiff] PRIVATE-NAME SYMBOL COLLISIONS ({len(collisions)}): "
              f"the native emits >1 LOCAL FUNC with these bare names because "
              f"it does not module-mangle private (`_`) names like the seed; a "
              f"cross-module call MIS-LINKS to the first one (resolve_calls "
              f"first-match). Fix: per-module private mangling in "
              f"adder/compiler/fused_driver_host_main.ad.")
        for n in collisions:
            print(f"    {n}: native×{nat_counts[n]}")
    if diverged:
        for name, divs in diverged:
            print(f"[kobjdiff] {name}: histogram divergence")
            for d in divs[:12]:
                print(d)
        print(f"[kobjdiff] DIVERGED kernel functions ({len(diverged)}): "
              f"{[n for n, _ in diverged]}")
    if diverged or collisions:
        sys.exit(1)
    print(f"[kobjdiff] PASS — zero semantic kernel divergences "
          f"across {compared} matched functions")
    sys.exit(0)


if __name__ == "__main__":
    main()
