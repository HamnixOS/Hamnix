#!/usr/bin/env python3
"""
Pynux CLI - Compile Python-syntax code to ARM

Usage:
    pynux compile source.py -o output.elf
    pynux run source.py  # Compile and run in QEMU
"""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

from .lexer import tokenize, LexerError
from .parser import Parser, ParseError, parse
from .ast_nodes import Program, ImportDecl
from .codegen_arm import generate as generate_arm, CodeGenError


# Compilation targets. `codegen` selects the backend; `kbuild` means the
# Linux kernel build system owns assembly+link, so the CLI stops at emitting
# a .S file rather than invoking an assembler/linker itself.
TARGETS = {
    "arm-cortex-m3": {"codegen": "arm", "kbuild": False, "bare_metal": True},
    "x86_64-linux-kernel-module": {"codegen": "x86", "kbuild": True,
                                   "bare_metal": False},
    # Standalone x86_64 kernel ELF (vmlinux-equivalent). The compiler owns
    # assembly + link itself (no kbuild), and the codegen skips the .modinfo
    # license stamp that's only meaningful for loadable modules.
    "x86_64-bare-metal": {"codegen": "x86", "kbuild": False,
                          "bare_metal": True},
}
DEFAULT_TARGET = "arm-cortex-m3"


def get_generator(target: str):
    """Return a callable program -> assembly string for the target."""
    spec = TARGETS.get(target)
    if spec is None:
        known = ", ".join(TARGETS)
        print(f"Error: unknown target '{target}'. Known targets: {known}",
              file=sys.stderr)
        sys.exit(1)
    if spec["codegen"] == "arm":
        return generate_arm
    if spec["codegen"] == "x86":
        from .codegen_x86 import generate as generate_x86
        bare = spec.get("bare_metal", False)
        return lambda program: generate_x86(program, bare_metal=bare)
    raise AssertionError(f"unhandled codegen backend: {spec['codegen']}")


def find_pynux_root() -> Path:
    """Find the pynux project root directory."""
    this_dir = Path(__file__).parent
    return this_dir.parent


def resolve_import(module_path: str, base_dir: Path) -> Path:
    """Resolve a module path to a file path."""
    # Convert dots to path separators
    parts = module_path.split(".")
    path = base_dir / "/".join(parts)

    # Try as directory/__init__.py first
    if (path / "__init__.py").exists():
        return path / "__init__.py"

    # Try as file.py
    if path.with_suffix(".py").exists():
        return path.with_suffix(".py")

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
    seen_names: set[str] = set()

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

        # Collect declarations, avoiding duplicates
        for decl in program.declarations:
            name = getattr(decl, 'name', None)
            if name:
                if name not in seen_names:
                    seen_names.add(name)
                    all_declarations.append(decl)
            else:
                all_declarations.append(decl)

    return Program(imports=all_imports, declarations=all_declarations)


def find_runtime() -> Path:
    """Find the runtime directory."""
    # Try relative to this file
    this_dir = Path(__file__).parent
    runtime = this_dir.parent / "runtime"
    if runtime.exists():
        return runtime

    # Try from current directory
    runtime = Path("runtime")
    if runtime.exists():
        return runtime

    raise FileNotFoundError("Cannot find runtime directory")


def compile_source(source: str, filename: str = "<stdin>",
                   target: str = DEFAULT_TARGET) -> str:
    """Compile Pynux source to assembly (single file, no imports)."""
    generate = get_generator(target)
    try:
        program = parse(source, filename)
        return generate(program)
    except (LexerError, ParseError, CodeGenError) as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


def compile_with_imports(main_file: Path, target: str = DEFAULT_TARGET) -> str:
    """Compile Pynux source with import resolution."""
    generate = get_generator(target)
    project_root = find_pynux_root()

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
    """Assemble + link a Pynux bare-metal x86_64 kernel image.

    Combines the compiler-emitted .S (Pynux init/main.py et al.) with the
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
        p for p in (project_root / "arch/x86").rglob("*.S")
        if p != boot_s and p != head_s
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        boot_o = tmpdir / "header.o"
        head_o = tmpdir / "head_64.o"
        main_o = tmpdir / "main.o"

        # Pynux's emitted .S is 64-bit code but has no leading `.code64`
        # (the codegen is target-mode-agnostic). For the bare-metal target
        # we assemble with `as --32` to produce an elf32-i386 .o that the
        # multiboot1 loader will accept, while a leading `.code64` tells
        # the assembler to encode 64-bit instructions. The same prepend is
        # applied to head_64.S below by way of the file already declaring
        # `.code64`. The boot stub (header.S) starts in `.code32`.
        pynux_s = tmpdir / "pynux_main.S"
        pynux_s.write_text(".code64\n" + asm_file.read_text())

        extra_objs: list[Path] = []
        for src in extra_s:
            obj = tmpdir / (src.stem + ".o")
            extra_objs.append(obj)

        for src, obj in [(boot_s, boot_o), (head_s, head_o),
                         (pynux_s, main_o)] + list(zip(extra_s, extra_objs)):
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


def assemble_and_link(asm_file: Path, output: Path, runtime_dir: Path) -> bool:
    """Assemble and link to create ELF binary."""
    # Check for toolchain
    as_cmd = "arm-none-eabi-as"
    ld_cmd = "arm-none-eabi-ld"

    try:
        subprocess.run([as_cmd, "--version"], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Error: arm-none-eabi toolchain not found", file=sys.stderr)
        print("Install with: sudo apt install gcc-arm-none-eabi", file=sys.stderr)
        return False

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)

        # Assemble startup.s
        startup_obj = tmpdir / "startup.o"
        result = subprocess.run([
            as_cmd, "-mcpu=cortex-m3", "-mthumb",
            "-o", str(startup_obj),
            str(runtime_dir / "startup.s")
        ], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error assembling startup.s:\n{result.stderr}", file=sys.stderr)
            return False

        # Assemble io.s
        io_obj = tmpdir / "io.o"
        result = subprocess.run([
            as_cmd, "-mcpu=cortex-m3", "-mthumb",
            "-o", str(io_obj),
            str(runtime_dir / "io.s")
        ], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error assembling io.s:\n{result.stderr}", file=sys.stderr)
            return False

        # Assemble main program
        main_obj = tmpdir / "main.o"
        result = subprocess.run([
            as_cmd, "-mcpu=cortex-m3", "-mthumb",
            "-o", str(main_obj),
            str(asm_file)
        ], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error assembling {asm_file}:\n{result.stderr}", file=sys.stderr)
            return False

        # Link
        linker_script = runtime_dir / "mps2-an385.ld"
        result = subprocess.run([
            ld_cmd,
            "-T", str(linker_script),
            "-o", str(output),
            str(startup_obj),
            str(io_obj),
            str(main_obj)
        ], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error linking:\n{result.stderr}", file=sys.stderr)
            return False

    return True


def run_qemu(elf_file: Path, timeout: int = 5) -> None:
    """Run ELF in QEMU."""
    qemu_cmd = "qemu-system-arm"

    try:
        subprocess.run([qemu_cmd, "--version"], capture_output=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Error: qemu-system-arm not found", file=sys.stderr)
        print("Install with: sudo apt install qemu-system-arm", file=sys.stderr)
        sys.exit(1)

    try:
        result = subprocess.run([
            qemu_cmd,
            "-M", "mps2-an385",
            "-nographic",
            "-kernel", str(elf_file),
            "-semihosting-config", "enable=on,target=native"
        ], timeout=timeout, capture_output=False)
    except subprocess.TimeoutExpired:
        pass  # Expected - program loops forever after main returns
    except KeyboardInterrupt:
        pass


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
            ok = assemble_and_link_x86_bare(asm_path, output, find_pynux_root())
        else:
            ok = assemble_and_link(asm_path, output, find_runtime())
        if not ok:
            return 1
    finally:
        asm_path.unlink()

    print(f"Compiled to {output}")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    """Compile and run command."""
    source_file = Path(args.source)
    if not source_file.exists():
        print(f"Error: {source_file} not found", file=sys.stderr)
        return 1

    asm = compile_with_imports(source_file)

    runtime_dir = find_runtime()

    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = Path(tmpdir)
        asm_file = tmpdir / "main.s"
        asm_file.write_text(asm)

        elf_file = tmpdir / "main.elf"
        if not assemble_and_link(asm_file, elf_file, runtime_dir):
            return 1

        print(f"Running {source_file} in QEMU (Ctrl+A, X to exit)...")
        run_qemu(elf_file, timeout=args.timeout)

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
        prog="pynux",
        description="Pynux - Python syntax to ARM compiler"
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

    # Run command
    run_parser = subparsers.add_parser("run", help="Compile and run in QEMU")
    run_parser.add_argument("source", help="Source file (.py)")
    run_parser.add_argument("--timeout", type=int, default=5,
                           help="QEMU timeout in seconds")
    run_parser.set_defaults(func=cmd_run)

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
