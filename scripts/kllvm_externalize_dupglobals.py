#!/usr/bin/env python3
# scripts/kllvm_externalize_dupglobals.py — Phase-5p hybrid-link correctness fix.
#
# THE BUG (Phase 5p, docs/kernel_llvm_phase5b.md): the whole-kernel LLVM object
# (kernel_main_llvm.o) and the native hybrid fallback object (native_main.o) BOTH
# define every module global (NR_EXPORTS, export_names, task_table, ...). Linked
# with `ld --allow-multiple-definition`, ld resolves EACH relocation against a
# duplicated global INDEPENDENTLY — so two references to the very same
# `@NR_EXPORTS` in the SAME LLVM object can bind to DIFFERENT copies. Concretely:
# `linux_abi_exports_init`/`_add_export` populate ONE copy of the export table
# (NR_EXPORTS=2756) while `linux_abi_lookup` reads the OTHER copy (still 0), so
# every Linux-ABI symbol lookup fails, `usbcore` init_module skips 3290
# relocations and #GPs. (Phases 5g-5o mis-diagnosed this empty second copy as a
# "wild .bss store" — it is never written; it is simply the unpopulated duplicate
# the reader happened to bind to.)
#
# THE FIX: give every global exactly ONE definition. For each named module global
# that native_main.o ALSO defines, rewrite the LLVM object's DEFINITION into an
# `external` DECLARATION, so the native object is the sole definer and every
# reference (from LLVM- and native-compiled code alike) binds to that one copy.
# Globals defined ONLY in the LLVM object (e.g. __stack_chk_guard,
# _l_PCI_CAP_ID_MSIX) are left defined. `.Lstr*` string literals are `internal`
# (assembler-local) and never match. dso_local is preserved so addressing stays
# direct (no GOT).
#
# This is opt-in-lane-only: it rewrites the GENERATED .ll, never any compiler or
# kernel source, so the native kernel build is byte-identical.
#
# Usage: kllvm_externalize_dupglobals.py <in.ll> <out.ll> <native_main.o>
import re
import subprocess
import sys


def native_global_names(obj: str) -> set:
    # Data/bss/rodata symbols DEFINED (not 'U') in the native object.
    out = subprocess.run(["nm", obj], capture_output=True, text=True).stdout
    names = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] in "BbDdGgRrCVv":
            names.add(parts[2])
    return names


def main():
    inf, outf, obj = sys.argv[1], sys.argv[2], sys.argv[3]
    native = native_global_names(obj)
    # @name = dso_local global [N x i8] <initializer>, align K
    rx = re.compile(r"^@([\w.$]+) = dso_local global (\[\d+ x i8\]) .*, align \d+$")
    n = 0
    with open(inf) as f, open(outf, "w") as g:
        for line in f:
            m = rx.match(line.rstrip("\n"))
            if m and m.group(1) in native:
                g.write(f"@{m.group(1)} = external dso_local global {m.group(2)}, align 16\n")
                n += 1
            else:
                g.write(line)
    print(f"[externalize] collapsed {n} duplicated globals to external "
          f"(native_main.o = sole definer)")


if __name__ == "__main__":
    main()
