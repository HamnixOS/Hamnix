#!/usr/bin/env python3
"""
Adder CLI - Compile Python-syntax code to x86_64.

Usage:
    adder compile source.py --target=<target> -o output.elf

Targets:
    x86_64-bare-metal           Standalone kernel image (hamnix-kernel.elf)
    x86_64-linux-kernel-module  Emits .S for kbuild → .ko
    x86_64-adder-user           CPL-3 userspace ELF for the bare-metal kernel

The original ARM Cortex-M target lived in compiler/codegen_arm.py and was
deleted in the legacy cleanup; only the x86_64 backend ships now.
"""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

from .lexer import tokenize, LexerError
from .parser import Parser, ParseError, parse
from .ast_nodes import Program, ImportDecl
from .codegen_x86 import generate as generate_x86, CodeGenError


# Compilation targets. `codegen` selects the backend; `kbuild` means the
# Linux kernel build system owns assembly+link, so the CLI stops at emitting
# a .S file rather than invoking an assembler/linker itself.
TARGETS = {
    "x86_64-linux-kernel-module": {"codegen": "x86", "kbuild": True,
                                   "bare_metal": False},
    # Standalone x86_64 kernel ELF (hamnix-kernel.elf). The compiler owns
    # assembly + link itself (no kbuild), and the codegen skips the .modinfo
    # license stamp that's only meaningful for loadable modules.
    "x86_64-bare-metal": {"codegen": "x86", "kbuild": False,
                          "bare_metal": True},
    # CPL-3 user-mode ELF the Adder kernel's fs/elf.py loader can run.
    # Same codegen as bare-metal (RIP-relative addressing, no .modinfo),
    # different link: we add user/runtime.S (the _start + syscall
    # wrappers) and use user/init.lds (single PT_LOAD, OUTPUT_FORMAT
    # elf32-i386 so the kernel's loader can parse it).
    "x86_64-adder-user": {"codegen": "x86", "kbuild": False,
                          "bare_metal": True},
}
DEFAULT_TARGET = "x86_64-bare-metal"


def get_generator(target: str):
    """Return a callable program -> assembly string for the target."""
    spec = TARGETS.get(target)
    if spec is None:
        known = ", ".join(TARGETS)
        print(f"Error: unknown target '{target}'. Known targets: {known}",
              file=sys.stderr)
        sys.exit(1)
    if spec["codegen"] == "x86":
        bare = spec.get("bare_metal", False)
        return lambda program: generate_x86(program, bare_metal=bare)
    raise AssertionError(f"unhandled codegen backend: {spec['codegen']}")


def find_hamnix_root() -> Path:
    """Find the adder project root directory."""
    this_dir = Path(__file__).parent
    return this_dir.parent


def resolve_import(module_path: str, base_dir: Path) -> Path:
    """Resolve a module path to a file path.

    Adder source files use the `.ad` extension to keep them distinct
    from real Python sources (e.g. the compiler implementation in
    compiler/ and build scripts under scripts/). Python-style import
    syntax is reused — the module identifier `kernel.sched.core`
    resolves to `kernel/sched/core.ad`.
    """
    # Convert dots to path separators
    parts = module_path.split(".")
    path = base_dir / "/".join(parts)

    # Try as directory/__init__.ad first
    if (path / "__init__.ad").exists():
        return path / "__init__.ad"

    # Try as file.ad
    if path.with_suffix(".ad").exists():
        return path.with_suffix(".ad")

    raise FileNotFoundError(f"Cannot find module: {module_path}")


def collect_all_imports(main_file: Path, project_root: Path) -> list[Path]:
    """Collect all imported files transitively."""
    visited: set[Path] = set()
    to_process: list[Path] = [main_file.resolve()]
    ordered: list[Path] = []  # Dependency order (imports first)

    while to_process:
        current = to_process.pop()
        if current in visited:
            continue
        visited.add(current)

        # Parse this file to get its imports
        source = current.read_text()
        try:
            program = parse(source, str(current))
        except (LexerError, ParseError) as e:
            print(f"Error parsing {current}: {e}", file=sys.stderr)
            sys.exit(1)

        # Find all imported modules
        for imp in program.imports:
            try:
                imported_file = resolve_import(imp.module, project_root)
                if imported_file not in visited:
                    to_process.append(imported_file)
            except FileNotFoundError:
                # External/runtime imports - ignore
                pass

        # Add this file after its dependencies
        ordered.insert(0, current)

    return ordered


# ---------------------------------------------------------------------------
# Per-module symbol scoping
# ---------------------------------------------------------------------------
#
# Adder has no `export`/`pub` keyword. Visibility is by *convention*:
#
#   * A top-level name that DOES NOT start with `_` is PUBLIC — it lives
#     in the single global symbol namespace, exactly as before. Two
#     modules defining the same public name is still a hard error.
#
#   * A top-level name that DOES start with `_` is MODULE-PRIVATE: it is
#     mangled to `<module_slug>__<name>` so a `_helper` in one .ad file
#     never collides with a `_helper` in another. Intra-module references
#     to that private name (calls, identifier loads, `&fn` address-of)
#     are rewritten to the mangled spelling so they still resolve.
#
#   * EXCEPTION — the `import` statement is itself the export annotation.
#     If any module does `from M import _name`, then `_name` is part of
#     an explicit cross-module contract: it is promoted to PUBLIC and
#     left un-mangled, so the importer's bare `_name` reference resolves.
#     (Today's cross-module underscore symbols: `_add_export`,
#     `__stack_chk_fail/guard/init`, `_u_errstr`.)
#
#   * ExternDecl names are NEVER mangled — they name real external
#     symbols. A private def that *backs* an `extern def` of the same
#     name elsewhere is likewise promoted to public.
#
# This needs ZERO migration of the ~350 existing .ad files: public API
# names are untouched, and underscore helpers — which are exactly the
# things that collide and exactly the things that are conventionally
# private — get scoped automatically.

# Symbols the x86_64 codegen emits references to by a hard-coded name
# (compiler/codegen_x86.py's stack-protector prologue/epilogue). These
# must never be mangled regardless of import status.
_CODEGEN_RESERVED_SYMBOLS = frozenset({
    "__stack_chk_guard",
    "__stack_chk_fail",
    "__stack_chk_init",
})


def _module_name_for(file_path: Path, project_root: Path) -> str:
    """Derive a dotted module path from a source file path.

    Inverse of resolve_import(): `kernel/sched/core.ad` ->
    `kernel.sched.core`. Used both as the scoping key and as the
    private-name mangle prefix.
    """
    try:
        rel = file_path.resolve().relative_to(project_root.resolve())
    except ValueError:
        # File outside the project tree (e.g. an ad-hoc temp file in a
        # standalone test). Fall back to the bare stem.
        rel = Path(file_path.name)
    parts = list(rel.with_suffix("").parts)
    return ".".join(parts)


def _mangle_private(module: str, name: str) -> str:
    """Mangle a module-private name to a globally-unique symbol.

    `<module_slug>__<name>` where the slug is the dotted module path
    with dots replaced by underscores. `name` already begins with `_`,
    so the result is e.g. `kernel_sched_core___emit_str` — the triple
    underscore (slug `_` + private `_`) is intentional and harmless.
    The result is a valid assembler identifier.
    """
    slug = module.replace(".", "_")
    return f"{slug}_{name}"


def _is_private_name(name: str) -> bool:
    """A leading-underscore top-level name is private by convention."""
    return name.startswith("_")


def _iter_child_nodes(node):
    """Yield every dataclass-typed child reachable from `node`.

    Generic structural walk: recurses into dataclass fields, lists,
    tuples and dict values. Used to find every Identifier (and the
    handful of name-bearing type nodes) in a declaration subtree.
    """
    import dataclasses
    if dataclasses.is_dataclass(node):
        for f in dataclasses.fields(node):
            yield getattr(node, f.name)
    elif isinstance(node, (list, tuple)):
        for item in node:
            yield item
    elif isinstance(node, dict):
        for v in node.values():
            yield v


def _collect_local_names(node, acc: set) -> None:
    """Collect names BOUND as locals within a function body subtree.

    A name bound locally (parameter, `x: T = ...`, for-loop var,
    `except E as e`, `with ... as w`, comprehension/lambda var, or a
    tuple unpack target) shadows a same-named module-private top-level
    symbol, so its references must NOT be mangled. A `global _x`
    statement is the opposite — it forces `_x` to mean the module
    global — so global-declared names are deliberately NOT collected
    here (they SHOULD be mangled along with the global decl).

    We over-approximate the rest deliberately: treating a name as
    "local" only ever SUPPRESSES a rewrite, and the codegen already
    resolves locals-before-globals, so a false positive is safe (it
    just leaves a genuine global reference un-mangled) while a false
    negative would miscompile.
    """
    from .ast_nodes import (
        FunctionDef, VarDecl, ForStmt, ForUnpackStmt, ExceptHandler,
        WithItem, ListComprehension, LambdaExpr, TupleUnpackAssign,
        Parameter,
    )
    if node is None:
        return
    if isinstance(node, Parameter):
        acc.add(node.name)
    elif isinstance(node, VarDecl):
        acc.add(node.name)
    elif isinstance(node, ForStmt):
        acc.add(node.var)
    elif isinstance(node, ForUnpackStmt):
        acc.update(node.vars)
    elif isinstance(node, ExceptHandler):
        if node.name:
            acc.add(node.name)
    elif isinstance(node, WithItem):
        if node.var:
            acc.add(node.var)
    elif isinstance(node, ListComprehension):
        acc.add(node.var)
    elif isinstance(node, LambdaExpr):
        acc.update(node.params)
    elif isinstance(node, TupleUnpackAssign):
        acc.update(node.targets)
    # FunctionDef params are Parameter nodes handled above via recursion.
    for child in _iter_child_nodes(node):
        _collect_local_names(child, acc)


def _rewrite_refs(node, rename: dict, shadowed: frozenset) -> None:
    """Rewrite identifier references to module-private mangled names.

    `rename` maps a module-private source name -> its mangled symbol.
    `shadowed` is the set of names bound as locals somewhere in the
    enclosing function (see _collect_local_names) — references to a
    shadowed name are left alone.

    Every symbol-by-name reference in Adder lands on an `Identifier`
    node: a bare variable/global load, the `func` of a CallExpr, and
    the operand of a `&` address-of are all `Identifier`. We also
    defensively rewrite the name-bearing type nodes (StructInitExpr,
    ContainerOfExpr, Type) — no private *types* exist in the codebase
    today, but handling them keeps the scheme correct if one is added.
    """
    from .ast_nodes import (
        Identifier, StructInitExpr, ContainerOfExpr, Type,
    )
    if node is None:
        return
    if isinstance(node, Identifier):
        if node.name in rename and node.name not in shadowed:
            node.name = rename[node.name]
        return
    if isinstance(node, StructInitExpr):
        if node.struct_name in rename:
            node.struct_name = rename[node.struct_name]
    elif isinstance(node, ContainerOfExpr):
        if node.type_name in rename:
            node.type_name = rename[node.type_name]
    elif isinstance(node, Type):
        if node.name in rename:
            node.name = rename[node.name]
    for child in _iter_child_nodes(node):
        _rewrite_refs(child, rename, shadowed)


def _collect_exported_names(programs: list) -> set:
    """Names that must stay global (un-mangled) despite a leading `_`.

    A leading-underscore name is normally module-private, but a name
    that is part of an explicit cross-module contract must stay global:

      * any name appearing in some module's `from M import name` list
        — the import statement IS the export annotation;
      * any ExternDecl name — extern decls reference real external
        symbols, and a private def backing one must keep its name;
      * the codegen-reserved stack-protector symbols.
    """
    from .ast_nodes import ExternDecl
    exported: set = set(_CODEGEN_RESERVED_SYMBOLS)
    for program in programs:
        for imp in program.imports:
            # `from M import a, b` names cross-module symbols. A plain
            # `import M` / `import M as x` has an empty names list.
            for nm in imp.names:
                exported.add(nm)
        for decl in program.declarations:
            if isinstance(decl, ExternDecl):
                exported.add(decl.name)
    return exported


def resolve_module_scopes(programs: list) -> None:
    """Apply per-module private-name scoping to a list of programs.

    Mutates each Program in place: mangles its module-private
    declaration names and rewrites every intra-module reference to
    them. After this runs, the merged declaration set has no private
    name collisions and every public name is still global.

    Each Program MUST already have its `.module` field set.
    """
    exported = _collect_exported_names(programs)

    for program in programs:
        module = program.module or ""
        # Build this module's private-name rename map.
        rename: dict[str, str] = {}
        for decl in program.declarations:
            name = getattr(decl, "name", None)
            if not name:
                continue
            # ExternDecl names are real external symbols — never mangle.
            from .ast_nodes import ExternDecl
            if isinstance(decl, ExternDecl):
                continue
            if not _is_private_name(name):
                continue
            if name in exported:
                # Promoted to public by an explicit import / extern.
                continue
            rename[name] = _mangle_private(module, name)

        if not rename:
            continue

        # Rename the declarations themselves, preserving orig_name so
        # name-based codegen heuristics keep working.
        from .ast_nodes import FunctionDef, VarDecl
        for decl in program.declarations:
            name = getattr(decl, "name", None)
            if name in rename:
                if isinstance(decl, (FunctionDef, VarDecl)):
                    decl.orig_name = name
                decl.name = rename[name]

        # Rewrite intra-module references. Local bindings (params,
        # `x: T`, loop vars, ...) shadow a same-named private global,
        # so collect them per-function and exclude them.
        for decl in program.declarations:
            shadow: set = set()
            _collect_local_names(decl, shadow)
            _rewrite_refs(decl, rename, frozenset(shadow))


def merge_programs(files: list[Path]) -> Program:
    """Parse all files and merge into a single program.

    Before merging, the per-module scoping pass (resolve_module_scopes)
    mangles each module's private (leading-underscore) names so they
    cannot collide. After that, the only remaining name collisions are
    between PUBLIC names — and those are still a hard error, exactly as
    before: silent dedup once meant two modules each defined
    `_find_free_slot`, the second was silently dropped, and callers in
    module B linked against module A's body — hours-of-debugging bug.
    """
    from .ast_nodes import ExternDecl

    project_root = find_hamnix_root()

    # Parse every file once, tagging each Program with its module path.
    programs: list[Program] = []
    program_files: list[Path] = []
    for file_path in files:
        source = file_path.read_text()
        program = parse(source, str(file_path))
        program.module = _module_name_for(file_path, project_root)
        for decl in program.declarations:
            # Tag each top-level decl with its origin module.
            if hasattr(decl, "module"):
                decl.module = program.module
        programs.append(program)
        program_files.append(file_path)

    # Scope module-private names BEFORE merging into one namespace.
    resolve_module_scopes(programs)

    all_imports: list[ImportDecl] = []
    all_declarations = []
    # Map name -> first file we saw it in. Duplicates are allowed only
    # for ExternDecl (the same `extern def foo(...)` may legitimately
    # appear in multiple modules that each call foo). Every other
    # collision is an error.
    seen_names: dict[str, Path] = {}

    for program, file_path in zip(programs, program_files):
        # Collect imports (runtime only)
        for imp in program.imports:
            # Skip internal imports (lib.*, kernel.*, coreutils.*)
            if not (imp.module.startswith("lib.") or
                    imp.module.startswith("kernel.") or
                    imp.module.startswith("coreutils.")):
                all_imports.append(imp)

        for decl in program.declarations:
            name = getattr(decl, 'name', None)
            if not name:
                all_declarations.append(decl)
                continue
            if name in seen_names:
                if isinstance(decl, ExternDecl):
                    # Extern decls are forward references; ignoring a
                    # duplicate `extern def` is harmless.
                    continue
                prev = seen_names[name]
                print(
                    f"Error: duplicate top-level definition '{name}' in "
                    f"{file_path} (first seen in {prev}). Rename one of "
                    f"them — these are PUBLIC names, global across all "
                    f"merged modules. (Module-private helpers — names "
                    f"starting with '_' — are scoped per-module and do "
                    f"not collide.)",
                    file=sys.stderr,
                )
                sys.exit(1)
            seen_names[name] = file_path
            all_declarations.append(decl)

    return Program(imports=all_imports, declarations=all_declarations)


def compile_source(source: str, filename: str = "<stdin>",
                   target: str = DEFAULT_TARGET) -> str:
    """Compile Adder source to assembly (single file, no imports)."""
    generate = get_generator(target)
    try:
        program = parse(source, filename)
        return generate(program)
    except (LexerError, ParseError, CodeGenError) as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


def compile_with_imports(main_file: Path, target: str = DEFAULT_TARGET) -> str:
    """Compile Adder source with import resolution."""
    generate = get_generator(target)
    project_root = find_hamnix_root()

    # Collect all imported files
    all_files = collect_all_imports(main_file, project_root)

    print(f"Compiling {len(all_files)} modules...", file=sys.stderr)
    for f in all_files:
        print(f"  {f.relative_to(project_root)}", file=sys.stderr)

    # Merge into single program
    merged_program = merge_programs(all_files)

    # Generate assembly
    try:
        return generate(merged_program)
    except CodeGenError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


def assemble_and_link_x86_bare(asm_file: Path, output: Path,
                                project_root: Path) -> bool:
    """Assemble + link a Adder bare-metal x86_64 kernel image.

    Combines the compiler-emitted .S (Adder init/main.py et al.) with the
    hand-written boot stubs under arch/x86/boot/header.S and
    arch/x86/kernel/head_64.S, then links with arch/x86/kernel/kernel.lds
    into an ELF that multiboot1-capable loaders (QEMU -kernel, GRUB) accept.

    HIGHER-HALF KERNEL: this now produces a true `elf64-x86-64` ELF
    (assembled with `as --64`, linked `ld -m elf_x86_64`). The kernel
    proper is LINKED at 0xffffffff80000000+offset but LOADED at low
    physical addresses; the elf32-i386 wrapper used previously could
    not represent symbol addresses above 4 GiB. GRUB's multiboot1 ELF
    loader accepts ELFCLASS64 and loads PT_LOAD segments by p_paddr
    (a 64-bit field), so the VMA/LMA split rides through cleanly.
    """
    as_cmd = "as"
    ld_cmd = "ld"

    try:
        subprocess.run([as_cmd, "--version"], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Error: GNU as not found (install binutils)", file=sys.stderr)
        return False

    boot_s = project_root / "arch/x86/boot/header.S"
    head_s = project_root / "arch/x86/kernel/head_64.S"
    lds = project_root / "arch/x86/kernel/kernel.lds"
    for required in (boot_s, head_s, lds):
        if not required.exists():
            print(f"Error: missing {required}", file=sys.stderr)
            return False

    # Additional hand-written .S files under arch/x86/, fs/, drivers/
    # (excluding the two boot/early-entry stubs above, which are passed
    # explicitly so we can guarantee link order: header.o first → multiboot
    # magic lands at top of .head.text). Anything else under these roots
    # that ends in .S is picked up automatically — drop a new file in
    # and rebuild. The drivers/ root was added when fb_text.ad needed
    # an embedded 8x16 font glyph table (drivers/video/console/fb_font_8x16.S).
    extra_s = sorted(
        p for path_root in ("arch/x86", "fs", "drivers")
        for p in (project_root / path_root).rglob("*.S")
        if p != boot_s and p != head_s
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        boot_o = tmpdir / "header.o"
        head_o = tmpdir / "head_64.o"
        main_o = tmpdir / "main.o"

        # Adder's emitted .S is 64-bit code but has no leading `.code64`
        # (the codegen is target-mode-agnostic). `as --64` defaults to
        # 64-bit instruction encoding, so a leading `.code64` is no
        # longer strictly required, but keep it as a belt-and-braces
        # marker — it is harmless in a 64-bit assembly. header.S itself
        # declares `.code32` for its boot prologue and `.code64` for
        # the long-mode trampoline tail, both of which `as --64`
        # honours per-section.
        hamnix_s = tmpdir / "hamnix_main.S"
        hamnix_s.write_text(".code64\n" + asm_file.read_text())

        extra_objs: list[Path] = []
        for src in extra_s:
            obj = tmpdir / (src.stem + ".o")
            extra_objs.append(obj)

        for src, obj in [(boot_s, boot_o), (head_s, head_o),
                         (hamnix_s, main_o)] + list(zip(extra_s, extra_objs)):
            result = subprocess.run(
                [as_cmd, "--64", "-o", str(obj), str(src)],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                print(f"Error assembling {src}:\n{result.stderr}",
                      file=sys.stderr)
                return False

        # Order matters: header.o first so multiboot magic lands at the top
        # of .head.text; the linker script enforces section order but listing
        # header.o first eliminates any cross-section ambiguity in the input.
        # `-z noexecstack` silences the GNU-stack-note warning; `-n` is not
        # used (we want the default page-aligned section layout the
        # multiboot1 loader expects).
        link_cmd = [
            ld_cmd, "-m", "elf_x86_64", "-nostdlib", "-static",
            "-z", "noexecstack", "-z", "max-page-size=4096",
            "-T", str(lds), "-o", str(output),
            str(boot_o), str(head_o), str(main_o),
        ] + [str(o) for o in extra_objs]
        result = subprocess.run(link_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error linking:\n{result.stderr}", file=sys.stderr)
            return False

    return True


def assemble_and_link_x86_user(asm_file: Path, output: Path,
                                project_root: Path,
                                progname: str = "unknown") -> bool:
    """Assemble + link a Adder source into a CPL-3 user-mode ELF.

    Same shape as assemble_and_link_x86_bare but a much smaller link:
    the user binary is purely the compiler-emitted .S (with the
    .code64 prepend trick) plus user/runtime.S (the _start entry and
    syscall wrappers). The linker script is user/init.lds, which
    emits an elf32-i386 wrapper with a single PT_LOAD at virtual base
    0 — this is what fs/elf.py knows how to load.

    No kernel objects are linked in: a user binary lives in its own
    address space and reaches the kernel only via the `syscall`
    instruction.

    TEMP_DEBUG_HAMSH_BRINGUP: `progname` selects the per-binary
    marker string the runtime's `_start` prints to fd 2. We synthesize
    a tiny progname.S on the fly carrying STRONG definitions of
    __runtime_start_mark / __runtime_start_mark_end with the binary's
    name baked in, and link it ahead of runtime.o so the linker picks
    the strong defs over the weak fallback ("[runtime:unknown] _start")
    that lives in user/runtime.S. Output per binary becomes a distinct
    line, e.g. "[runtime:init] _start" vs "[runtime:hamsh] _start" —
    so a real-hardware boot can tell us whether SYSRETQ out of hamsh's
    execve actually reached hamsh's _start.
    """
    as_cmd = "as"
    ld_cmd = "ld"

    try:
        subprocess.run([as_cmd, "--version"], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Error: GNU as not found (install binutils)", file=sys.stderr)
        return False

    runtime_s = project_root / "user/runtime.S"
    lds       = project_root / "user/init.lds"
    for required in (runtime_s, lds):
        if not required.exists():
            print(f"Error: missing {required}", file=sys.stderr)
            return False

    # TEMP_DEBUG_HAMSH_BRINGUP: keep the marker string ASCII-safe and
    # short — the linker script merges .rodata into the single PT_LOAD,
    # so no extra alignment concerns, but the syscall pulls the length
    # from `end - start` at link time so a stray non-ASCII byte would
    # still emit cleanly. The basename comes from cmd_compile and is
    # already a filesystem name, so it can't contain `"` or `\`.
    progname_safe = "".join(
        c if (c.isalnum() or c in "._-") else "_" for c in progname
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        runtime_o  = tmpdir / "runtime.o"
        progname_o = tmpdir / "progname.o"
        main_o     = tmpdir / "main.o"

        # Same .code64 prepend trick the bare-metal kernel uses: the
        # Adder codegen is target-mode-agnostic, but we want 64-bit
        # instructions inside an elf32-i386 wrapper. `as --32` plus a
        # leading `.code64` directive produces exactly that.
        hamnix_s = tmpdir / "hamnix_main.S"
        hamnix_s.write_text(".code64\n" + asm_file.read_text())

        # TEMP_DEBUG_HAMSH_BRINGUP: per-binary marker override. Strong
        # definitions of __runtime_start_mark / _end clobber the .weak
        # fallback in user/runtime.S. .ascii (no trailing NUL) plus the
        # bracketing labels means `_end - _start` is exactly the byte
        # count we want passed as sys_write's count arg.
        progname_s = tmpdir / "progname.S"
        progname_s.write_text(
            ".code64\n"
            "    .section .rodata\n"
            "    .align 8\n"
            "    .globl __runtime_start_mark\n"
            "    .globl __runtime_start_mark_end\n"
            "__runtime_start_mark:\n"
            f'    .ascii "[runtime:{progname_safe}] _start\\n"\n'
            "__runtime_start_mark_end:\n"
        )

        for src, obj in [(runtime_s, runtime_o),
                         (progname_s, progname_o),
                         (hamnix_s, main_o)]:
            result = subprocess.run(
                [as_cmd, "--32", "-o", str(obj), str(src)],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                print(f"Error assembling {src}:\n{result.stderr}",
                      file=sys.stderr)
                return False

        # progname.o BEFORE runtime.o so the linker sees the strong
        # __runtime_start_mark first; runtime.o's same-named .weak
        # symbols then quietly defer to it. runtime.o still has to
        # come early so _start (and the syscall stubs the user code
        # calls into) sits at the start of .text — the linker script
        # doesn't strictly require this but it keeps `objdump -d`
        # layout predictable.
        link_cmd = [
            ld_cmd, "-m", "elf_i386", "-nostdlib", "-static",
            "-T", str(lds), "-o", str(output),
            str(progname_o), str(runtime_o), str(main_o),
        ]
        result = subprocess.run(link_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error linking:\n{result.stderr}", file=sys.stderr)
            return False

    return True


def cmd_compile(args: argparse.Namespace) -> int:
    """Compile command."""
    source_file = Path(args.source)
    if not source_file.exists():
        print(f"Error: {source_file} not found", file=sys.stderr)
        return 1

    asm = compile_with_imports(source_file, target=args.target)

    # kbuild targets: the Linux kernel build system owns assembly + link, so
    # we stop at emitting a .S file for it to consume.
    if TARGETS[args.target]["kbuild"]:
        if args.output:
            output = Path(args.output)
        else:
            output = source_file.with_suffix(".S")
        output.write_text(asm)
        print(f"Emitted {output} for kbuild ({args.target})")
        return 0

    # Determine output file
    if args.output:
        output = Path(args.output)
    else:
        output = source_file.with_suffix(".elf")

    # Write assembly (for debugging)
    if args.emit_asm:
        asm_file = source_file.with_suffix(".s")
        asm_file.write_text(asm)
        print(f"Assembly written to {asm_file}")

    with tempfile.NamedTemporaryFile(suffix=".s", delete=False, mode="w") as f:
        f.write(asm)
        asm_path = Path(f.name)

    try:
        if args.target == "x86_64-bare-metal":
            ok = assemble_and_link_x86_bare(asm_path, output, find_hamnix_root())
        elif args.target == "x86_64-adder-user":
            # TEMP_DEBUG_HAMSH_BRINGUP: pass the source-file stem as the
            # progname so runtime.S's _start marker is per-binary
            # distinguishable (e.g. "[runtime:init]" vs "[runtime:hamsh]").
            ok = assemble_and_link_x86_user(
                asm_path, output, find_hamnix_root(),
                progname=source_file.stem,
            )
        else:
            raise AssertionError(
                f"x86_64-bare-metal / x86_64-adder-user are the only "
                f"non-kbuild link paths; got '{args.target}'"
            )
        if not ok:
            return 1
    finally:
        asm_path.unlink()

    print(f"Compiled to {output}")
    return 0


def cmd_asm(args: argparse.Namespace) -> int:
    """Emit assembly only."""
    source_file = Path(args.source)
    if not source_file.exists():
        print(f"Error: {source_file} not found", file=sys.stderr)
        return 1

    source = source_file.read_text()
    asm = compile_source(source, str(source_file), target=args.target)

    if args.output:
        Path(args.output).write_text(asm)
    else:
        print(asm)

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="adder",
        description="Adder compiler — Python syntax to x86_64 native code"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Compile command
    compile_parser = subparsers.add_parser("compile", help="Compile to ELF")
    compile_parser.add_argument("source", help="Source file (.py)")
    compile_parser.add_argument("-o", "--output", help="Output file (.elf)")
    compile_parser.add_argument("--emit-asm", action="store_true",
                               help="Also emit assembly file")
    compile_parser.add_argument("--target", default=DEFAULT_TARGET,
                               choices=list(TARGETS),
                               help=f"Compilation target (default: {DEFAULT_TARGET})")
    compile_parser.set_defaults(func=cmd_compile)

    # Asm command
    asm_parser = subparsers.add_parser("asm", help="Emit assembly only")
    asm_parser.add_argument("source", help="Source file (.py)")
    asm_parser.add_argument("-o", "--output", help="Output file (.s)")
    asm_parser.add_argument("--target", default=DEFAULT_TARGET,
                           choices=list(TARGETS),
                           help=f"Compilation target (default: {DEFAULT_TARGET})")
    asm_parser.set_defaults(func=cmd_asm)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
