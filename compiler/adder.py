#!/usr/bin/env python3
"""
Adder CLI - Compile Python-syntax code to x86_64.

Usage:
    adder compile source.py --target=<target> -o output.elf

Targets:
    x86_64-bare-metal           Standalone kernel image (vmlinux-equivalent)
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
    # Standalone x86_64 kernel ELF (vmlinux-equivalent). The compiler owns
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


def merge_programs(files: list[Path]) -> Program:
    """Parse all files and merge into a single program."""
    all_imports: list[ImportDecl] = []
    all_declarations = []
    # Map name -> first file we saw it in. We allow duplicates only
    # for ExternDecl (the same `extern def foo(...)` may legitimately
    # appear in multiple modules that each call foo). Every other
    # collision is an error — silent dedup used to mean two modules
    # could each define `_find_free_slot` and the second silently
    # never got compiled, with callers in module B linking against
    # module A's body. Hours-of-debugging type of bug.
    from .ast_nodes import ExternDecl
    seen_names: dict[str, Path] = {}

    for file_path in files:
        source = file_path.read_text()
        program = parse(source, str(file_path))

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
                    f"them — function/class/variable names are global "
                    f"across all merged modules.",
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
    arch/x86/kernel/head_64.S, then links with arch/x86/kernel/vmlinux.lds
    into an ELF that multiboot1-capable loaders (QEMU -kernel, GRUB) accept.
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
    lds = project_root / "arch/x86/kernel/vmlinux.lds"
    for required in (boot_s, head_s, lds):
        if not required.exists():
            print(f"Error: missing {required}", file=sys.stderr)
            return False

    # Additional hand-written .S files under arch/x86/ (excluding the two
    # boot/early-entry stubs above, which are passed explicitly so we can
    # guarantee link order: header.o first → multiboot magic lands at top
    # of .head.text). Anything else in arch/x86/{boot,kernel} that ends in
    # .S is picked up automatically — drop a new file in and rebuild.
    extra_s = sorted(
        p for path_root in ("arch/x86", "fs")
        for p in (project_root / path_root).rglob("*.S")
        if p != boot_s and p != head_s
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        boot_o = tmpdir / "header.o"
        head_o = tmpdir / "head_64.o"
        main_o = tmpdir / "main.o"

        # Adder's emitted .S is 64-bit code but has no leading `.code64`
        # (the codegen is target-mode-agnostic). For the bare-metal target
        # we assemble with `as --32` to produce an elf32-i386 .o that the
        # multiboot1 loader will accept, while a leading `.code64` tells
        # the assembler to encode 64-bit instructions. The same prepend is
        # applied to head_64.S below by way of the file already declaring
        # `.code64`. The boot stub (header.S) starts in `.code32`.
        hamnix_s = tmpdir / "hamnix_main.S"
        hamnix_s.write_text(".code64\n" + asm_file.read_text())

        extra_objs: list[Path] = []
        for src in extra_s:
            obj = tmpdir / (src.stem + ".o")
            extra_objs.append(obj)

        for src, obj in [(boot_s, boot_o), (head_s, head_o),
                         (hamnix_s, main_o)] + list(zip(extra_s, extra_objs)):
            result = subprocess.run(
                [as_cmd, "--32", "-o", str(obj), str(src)],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                print(f"Error assembling {src}:\n{result.stderr}",
                      file=sys.stderr)
                return False

        # Order matters: header.o first so multiboot magic lands at the top
        # of .head.text; the linker script enforces section order but listing
        # header.o first eliminates any cross-section ambiguity in the input.
        link_cmd = [
            ld_cmd, "-m", "elf_i386", "-nostdlib", "-static",
            "-T", str(lds), "-o", str(output),
            str(boot_o), str(head_o), str(main_o),
        ] + [str(o) for o in extra_objs]
        result = subprocess.run(link_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error linking:\n{result.stderr}", file=sys.stderr)
            return False

    return True


def assemble_and_link_x86_user(asm_file: Path, output: Path,
                                project_root: Path) -> bool:
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

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        runtime_o = tmpdir / "runtime.o"
        main_o    = tmpdir / "main.o"

        # Same .code64 prepend trick the bare-metal kernel uses: the
        # Adder codegen is target-mode-agnostic, but we want 64-bit
        # instructions inside an elf32-i386 wrapper. `as --32` plus a
        # leading `.code64` directive produces exactly that.
        hamnix_s = tmpdir / "hamnix_main.S"
        hamnix_s.write_text(".code64\n" + asm_file.read_text())

        for src, obj in [(runtime_s, runtime_o), (hamnix_s, main_o)]:
            result = subprocess.run(
                [as_cmd, "--32", "-o", str(obj), str(src)],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                print(f"Error assembling {src}:\n{result.stderr}",
                      file=sys.stderr)
                return False

        # runtime.o first so _start (and the syscall stubs the user
        # code calls into) sits at the very start of .text. The
        # linker script doesn't strictly require this — _start is the
        # ENTRY — but listing it first keeps the layout predictable
        # when eyeballing `objdump -d`.
        link_cmd = [
            ld_cmd, "-m", "elf_i386", "-nostdlib", "-static",
            "-T", str(lds), "-o", str(output),
            str(runtime_o), str(main_o),
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
            ok = assemble_and_link_x86_user(asm_path, output, find_hamnix_root())
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
