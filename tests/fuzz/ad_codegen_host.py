#!/usr/bin/env python3
# tests/fuzz/ad_codegen_host.py
#
# HOST-side differential harness for the self-hosted Adder backend
# (adder/compiler/codegen.ad). It runs a small Adder source program through
# the codegen.ad pipeline ON THE HOST (NO QEMU) and produces a runnable
# x86_64-linux ELF, so codegen.ad's output can be executed + checked against
# the trusted Python backend / predicted-output oracle.
#
# Mechanism:
#   1. A pre-built host driver ELF (tests/fuzz/ad_codegen_dump_driver.ad,
#      compiled to --target=x86_64-linux) runs lex->parse->codegen on the
#      source file and DUMPS the raw machine-code bytes (code[]), the global
#      data bytes (gdata[]), and the layout metadata (CODE_CAP/DATA_BASE,
#      cg_entry_off, code_len, gdata_len, bss_len) as a hex manifest.
#   2. This module parses that manifest and WRAPS the raw bytes into a real
#      x86_64-linux ELF, mirroring elf_emit.ad's layout EXACTLY but with a
#      Linux `_start` (exit_group = syscall 60 instead of Hamnix SYS_EXIT=1):
#         code  at vaddr  V          (V = a page-aligned nonzero base)
#         data  at vaddr  V+DATA_BASE (preserves codegen's RIP-relative
#                                      disp32 = (DATA_BASE+off) - rip_end)
#         _start stub right after the code; e_entry points at it.
#      The data segment's p_memsz = gdata_len + bss_len (the .bss tail is
#      memsz-only and loader-zeroed), matching elf_emit.ad.
#   3. The stub calls the entry (cg_entry_off) and `exit_group`s with %rax.
#
# codegen.ad has NO extern/libc linkage: it only supports the __syscallN
# builtin for raw syscalls (NOT `extern def sys_write`). The fuzzer prelude
# uses `extern def sys_write`; codegen_compatible_source() rewrites that to a
# __syscall3 form so codegen.ad accepts it. On Linux, write IS syscall 1
# (same as the prelude already passes), so stdout is byte-identical; exit is
# done by the host ELF stub (syscall 60).
#
# A program codegen.ad cannot compile (2-D array globals, unsupported
# constructs) is reported as "cgfail"/"parsefail" (UNSUPPORTED, not a
# failure). Only a program codegen.ad COMPILED that produced the WRONG output
# is a genuine miscompile.

import os
import re
import struct
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
DRIVER_SRC = HERE / "ad_codegen_dump_driver.ad"
DRIVER_ELF = REPO_ROOT / "build" / "fuzz_ad_codegen" / "ad_codegen_dump"

# Host ELF layout. Code base is a page-aligned nonzero VA (avoid the null
# page). Data sits DATA_BASE bytes above it so codegen's RIP-relative data
# displacements (computed as (DATA_BASE + off) - rip_field_end against a
# code-base-0 / data-base-DATA_BASE model) stay correct: only the code<->data
# DELTA matters, and that delta is DATA_BASE in both models.
CODE_VBASE = 0x10000


def build_driver(force=False):
    """Compile the host dump driver to x86_64-linux if missing/stale."""
    if DRIVER_ELF.exists() and not force:
        if DRIVER_ELF.stat().st_mtime >= DRIVER_SRC.stat().st_mtime:
            return
    DRIVER_ELF.parent.mkdir(parents=True, exist_ok=True)
    rel_src = DRIVER_SRC.relative_to(REPO_ROOT)
    rel_elf = DRIVER_ELF.relative_to(REPO_ROOT)
    cp = subprocess.run(
        [sys.executable, "-m", "compiler.adder", "compile",
         "--target=x86_64-linux", str(rel_src), "-o", str(rel_elf)],
        cwd=str(REPO_ROOT), capture_output=True, text=True)
    if cp.returncode != 0 or not DRIVER_ELF.exists():
        raise RuntimeError(
            "failed to build ad_codegen_dump driver:\n"
            + (cp.stderr or cp.stdout))


# --------------------------------------------------------------------------
# Rewrite a fuzzer-style program (extern def sys_write + sys_write(...) calls)
# into codegen.ad's supported subset (__syscall3 for write). codegen.ad has no
# extern linkage; it only lowers __syscallN(num, a1..aN). Linux write == 1.
# --------------------------------------------------------------------------
_EXTERN_WRITE_RE = re.compile(
    r"^extern def sys_write\(.*\)\s*->\s*int64\s*$", re.M)


def codegen_compatible_source(body: str) -> str:
    """Make `body` acceptable to codegen.ad:
      * drop `extern def sys_write(...)` (codegen.ad has no extern linkage),
      * rewrite each `sys_write(fd, buf, count)` call into the codegen.ad
        syscall builtin `__syscall3(NUM, fd, buf, count)` where NUM is the
        Linux write syscall number (1). codegen.ad's __syscallN(num, a1..aN)
        has N = number of SYSCALL ARGS (write has 3: fd, buf, count), so the
        builtin call carries N+1 = 4 actual arguments: the number followed by
        the three write args. On Linux, write IS syscall 1, identical to what
        the fuzzer prelude already passes as fd, so stdout is byte-identical.
    The predicted-output oracle is unchanged.
    """
    body = _EXTERN_WRITE_RE.sub("", body)
    # sys_write(ARGS) -> __syscall3(cast[int64](1), ARGS). We splice the
    # write syscall number (1) as the first argument; the original three
    # args (fd, buf, count) become a1,a2,a3 of the 3-arg syscall.
    out = []
    i = 0
    needle = "sys_write("
    while True:
        j = body.find(needle, i)
        if j < 0:
            out.append(body[i:])
            break
        # ensure it's a standalone identifier (not a substring)
        if j > 0 and (body[j - 1].isalnum() or body[j - 1] == "_"):
            out.append(body[i:j + len(needle)])
            i = j + len(needle)
            continue
        out.append(body[i:j])
        out.append("__syscall3(cast[int64](1), ")
        i = j + len(needle)
    return "".join(out)


# --------------------------------------------------------------------------
# Run the dump driver and parse its manifest.
# --------------------------------------------------------------------------
class DumpResult:
    def __init__(self, status, **kw):
        self.status = status        # "ok" | "cgfail" | "parsefail" | "readfail"
        self.__dict__.update(kw)


def _hex_to_bytes(lines):
    return bytes.fromhex("".join(lines))


def run_dump(src_path: Path, timeout=30, opt=False) -> DumpResult:
    build_driver()
    rel = src_path
    # opt=True passes the dump driver's opt-in --opt flag, enabling the native
    # Adder optimizer (Phase 1 const-fold). Default (no flag) is byte-inert.
    argv = [str(DRIVER_ELF)]
    if opt:
        argv.append("--opt")
    argv.append(str(rel))
    cp = subprocess.run(argv,
                        capture_output=True, text=True, timeout=timeout)
    out = cp.stdout
    if "AC_DUMP_BEGIN" not in out:
        return DumpResult("drivererror",
                          detail=f"rc={cp.returncode} no manifest: "
                                 f"{(cp.stderr or out)[-400:]}")
    lines = out.splitlines()
    meta = {}
    code_hex, gdata_hex = [], []
    mode = None
    status = None
    for ln in lines:
        if ln.startswith("STATUS "):
            status = ln.split()[1]
            meta["status_line"] = ln
            continue
        if ln == "CODEHEX":
            mode = "code"; continue
        if ln == "GDATAHEX":
            mode = "gdata"; continue
        if ln == "ENDHEX":
            mode = None; continue
        if mode == "code":
            code_hex.append(ln.strip())
        elif mode == "gdata":
            gdata_hex.append(ln.strip())
        elif " " in ln:
            k, _, v = ln.partition(" ")
            if v.strip().lstrip("-").isdigit():
                meta[k] = int(v.strip())
    if status != "ok":
        return DumpResult(status or "drivererror",
                          detail=meta.get("status_line", out[-400:]))
    return DumpResult("ok",
                      code=_hex_to_bytes(code_hex),
                      gdata=_hex_to_bytes(gdata_hex),
                      data_base=meta["DATA_BASE"],
                      entry_off=meta["ENTRY_OFF"],
                      code_len=meta["CODE_LEN"],
                      gdata_len=meta["GDATA_LEN"],
                      bss_len=meta["BSS_LEN"],
                      fn_count=meta["FN_COUNT"],
                      folds=meta.get("FOLDS", 0),
                      cse=meta.get("CSE", 0),
                      licm=meta.get("LICM", 0),
                      iremit=meta.get("IREMIT", 0),
                      irfold=meta.get("IRFOLD", 0),
                      irfallback=meta.get("IRFALLBACK", 0),
                      irreassoc=meta.get("IRREASSOC", 0))


# --------------------------------------------------------------------------
# Phase-4 GROUNDWORK CFG lane: run the dump driver in --dump-cfg mode and parse
# its CFG report. This builds the whole-function CFG + liveness + structural
# validator over the program and asserts the invariants. It NEVER touches
# codegen (the driver's --dump-cfg branch returns before opt_run/codegen), so it
# is a pure-analysis lane that cannot perturb codegen output.
# --------------------------------------------------------------------------
class CfgResult:
    def __init__(self, status, **kw):
        # status: "cfgok" | "cfgfail" | "parsefail" | "readfail" | "drivererror"
        self.status = status
        self.funcs = kw.get("funcs", 0)
        self.skipped = kw.get("skipped", 0)
        self.blocks = kw.get("blocks", 0)
        self.edges = kw.get("edges", 0)
        self.insts = kw.get("insts", 0)
        # Phase-4 PREREQ: value-level live ranges + alias/may-clobber stats.
        self.ranges = kw.get("ranges", 0)
        self.range_len = kw.get("range_len", 0)
        self.range_max = kw.get("range_max", 0)
        self.locals = kw.get("locals", 0)
        self.promotable = kw.get("promotable", 0)
        self.clobberable = kw.get("clobberable", 0)
        self.detail = kw.get("detail", "")


def run_cfg(src_path: Path, timeout=30) -> CfgResult:
    """Run the dump driver with --dump-cfg over `src_path` and parse the report.
    Returns a CfgResult. A parse/cgfail program is reported as parsefail (the
    CFG lane only validates programs codegen.ad's parser accepts)."""
    build_driver()
    argv = [str(DRIVER_ELF), "--dump-cfg", str(src_path)]
    cp = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    out = cp.stdout
    if "AC_DUMP_BEGIN" not in out:
        return CfgResult("drivererror",
                         detail=f"rc={cp.returncode} no manifest: "
                                f"{(cp.stderr or out)[-400:]}")
    meta = {}
    status = None
    detail = ""
    for ln in out.splitlines():
        if ln.startswith("STATUS "):
            parts = ln.split()
            status = parts[1]
            detail = ln
            continue
        if " " in ln:
            k, _, v = ln.partition(" ")
            if v.strip().lstrip("-").isdigit():
                meta[k] = int(v.strip())
    if status in ("parsefail", "readfail"):
        return CfgResult(status, detail=detail)
    if status not in ("cfgok", "cfgfail"):
        return CfgResult("drivererror", detail=detail or out[-400:])
    return CfgResult(status,
                     funcs=meta.get("CFG_FUNCS", 0),
                     skipped=meta.get("CFG_SKIPPED", 0),
                     blocks=meta.get("CFG_BLOCKS", 0),
                     edges=meta.get("CFG_EDGES", 0),
                     insts=meta.get("CFG_INSTS", 0),
                     ranges=meta.get("CFG_RANGES", 0),
                     range_len=meta.get("CFG_RANGE_LEN", 0),
                     range_max=meta.get("CFG_RANGE_MAX", 0),
                     locals=meta.get("CFG_LOCALS", 0),
                     promotable=meta.get("CFG_PROMOTABLE", 0),
                     clobberable=meta.get("CFG_CLOBBERABLE", 0),
                     detail=detail)


def run_cfg_over_body(seed, body, work_dir: Path, keep=False) -> CfgResult:
    """Write `body` (rewritten to codegen.ad's subset) to a temp file and run the
    CFG lane over it."""
    work_dir.mkdir(parents=True, exist_ok=True)
    cg_body = codegen_compatible_source(body)
    src = work_dir / f"cfg_{seed}.ad"
    src.write_text(cg_body)
    try:
        r = run_cfg(src)
    except subprocess.TimeoutExpired:
        return CfgResult("drivererror", detail="cfg driver timeout")
    finally:
        if not keep:
            src.unlink(missing_ok=True)
    return r


# --------------------------------------------------------------------------
# Phase-4 register-allocation lane: run the dump driver in --dump-regalloc mode
# and parse its allocation report (linear scan over every function, pure
# analysis, no codegen emitted). Reports register/spill stats.
# --------------------------------------------------------------------------
class RegallocResult:
    def __init__(self, status, **kw):
        self.status = status            # "raok" | "parsefail" | "drivererror"
        self.funcs = kw.get("funcs", 0)
        self.skipped = kw.get("skipped", 0)
        self.promotable = kw.get("promotable", 0)
        self.inreg = kw.get("inreg", 0)
        self.spilled = kw.get("spilled", 0)
        self.regs_used = kw.get("regs_used", 0)
        self.max_regs = kw.get("max_regs", 0)
        self.callcross = kw.get("callcross", 0)
        self.detail = kw.get("detail", "")


def run_regalloc(src_path: Path, timeout=30) -> RegallocResult:
    """Run the dump driver with --dump-regalloc over `src_path` and parse the
    allocation report."""
    build_driver()
    argv = [str(DRIVER_ELF), "--dump-regalloc", str(src_path)]
    cp = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    out = cp.stdout
    if "AC_DUMP_BEGIN" not in out:
        return RegallocResult("drivererror",
                              detail=f"rc={cp.returncode} no manifest: "
                                     f"{(cp.stderr or out)[-400:]}")
    meta = {}
    status = None
    detail = ""
    for ln in out.splitlines():
        if ln.startswith("STATUS "):
            status = ln.split()[1]
            detail = ln
            continue
        if " " in ln:
            k, _, v = ln.partition(" ")
            if v.strip().lstrip("-").isdigit():
                meta[k] = int(v.strip())
    if status in ("parsefail", "readfail"):
        return RegallocResult(status, detail=detail)
    if status != "raok":
        return RegallocResult("drivererror", detail=detail or out[-400:])
    return RegallocResult("raok",
                          funcs=meta.get("RA_FUNCS", 0),
                          skipped=meta.get("RA_SKIPPED", 0),
                          promotable=meta.get("RA_PROMOTABLE", 0),
                          inreg=meta.get("RA_INREG", 0),
                          spilled=meta.get("RA_SPILLED", 0),
                          regs_used=meta.get("RA_REGS_USED", 0),
                          max_regs=meta.get("RA_MAX_REGS", 0),
                          callcross=meta.get("RA_CALLCROSS", 0),
                          detail=detail)


def run_regalloc_over_body(seed, body, work_dir: Path, keep=False) -> RegallocResult:
    """Write `body` (rewritten to codegen.ad's subset) and run the regalloc lane."""
    work_dir.mkdir(parents=True, exist_ok=True)
    cg_body = codegen_compatible_source(body)
    src = work_dir / f"ra_{seed}.ad"
    src.write_text(cg_body)
    try:
        r = run_regalloc(src)
    except subprocess.TimeoutExpired:
        return RegallocResult("drivererror", detail="regalloc driver timeout")
    finally:
        if not keep:
            src.unlink(missing_ok=True)
    return r


# --------------------------------------------------------------------------
# Wrap raw codegen.ad bytes into a real x86_64-linux ELF (ELF64, EM_X86_64).
# --------------------------------------------------------------------------
def _start_stub(code_vbase, entry_off, stub_vaddr):
    """Hand-assembled x86_64 _start:
        E8 <rel32>     call entry            ; entry at code_vbase+entry_off
        48 89 C7       mov  rdi, rax         ; return value -> exit code
        B8 3C 00 00 00 mov  eax, 60          ; SYS_exit_group? use exit(60)
        0F 05          syscall
        EB FE          jmp .                 ; defensive spin
    rel32 = entry_va - (field_va + 4). field is at stub_vaddr+1.
    """
    entry_va = code_vbase + entry_off
    field_va = stub_vaddr + 1
    rel = (entry_va - (field_va + 4)) & 0xFFFFFFFF
    b = bytearray()
    b += b"\xE8" + struct.pack("<I", rel)      # call entry
    b += b"\x48\x89\xC7"                        # mov rdi, rax
    b += b"\xB8" + struct.pack("<I", 60)        # mov eax, 60 (exit)
    b += b"\x0F\x05"                            # syscall
    b += b"\xEB\xFE"                            # jmp .
    return bytes(b)


def wrap_elf(dump: DumpResult, out_path: Path):
    """Build an ELF64 x86_64-linux executable from the dumped code+gdata."""
    code = dump.code
    gdata = dump.gdata
    data_base = dump.data_base
    entry_off = dump.entry_off
    bss_len = dump.bss_len

    EHDR = 64
    PHENT = 56
    NPH = 2
    headers_len = EHDR + NPH * PHENT           # 64 + 112 = 176
    align = 0x1000

    # The code PT_LOAD maps from file offset 0 (covering the ELF header +
    # program headers) at vaddr code_vbase, so (p_offset % align) ==
    # (p_vaddr % align) == 0 — the congruence the kernel ELF loader requires.
    # The compiled code's vaddr 0 (codegen's model) therefore maps to
    # code_vbase + headers_len; the entry/data offsets are rebased by the same
    # headers_len so codegen's RIP-relative data delta (== data_base) is
    # preserved (it is a code<->data DELTA, unaffected by the shared shift).
    code_vbase = CODE_VBASE                     # page-aligned, code[0] base
    code_start_vaddr = code_vbase + headers_len # where code[0] actually lands
    stub_vaddr = code_start_vaddr + len(code)
    stub = _start_stub(code_start_vaddr, entry_off, stub_vaddr)
    entry_vaddr = stub_vaddr                    # e_entry == _start stub

    code_seg = code + stub
    # code PT_LOAD file image = headers + code + stub, mapped from offset 0.
    code_filesz = headers_len + len(code_seg)
    # Data sits data_base bytes above code[0] (== code_start_vaddr), preserving
    # the RIP-relative delta codegen baked in.
    data_vbase = code_start_vaddr + data_base
    data_filesz = len(gdata)
    data_memsz = len(gdata) + bss_len

    # Data segment file offset: after the code image, bumped so
    # (p_offset % align) == (p_vaddr % align).
    data_file_off = code_filesz
    want = data_vbase % align
    cur = data_file_off % align
    pad = (want - cur) % align
    data_file_off += pad

    # --- ELF64 header ---
    e = bytearray()
    e += b"\x7fELF"
    e += bytes([2, 1, 1, 0])        # ELFCLASS64, LSB, version, SYSV
    e += bytes(8)                   # pad
    e += struct.pack("<H", 2)       # e_type = ET_EXEC
    e += struct.pack("<H", 0x3E)    # e_machine = EM_X86_64
    e += struct.pack("<I", 1)       # e_version
    e += struct.pack("<Q", entry_vaddr)   # e_entry
    e += struct.pack("<Q", EHDR)          # e_phoff
    e += struct.pack("<Q", 0)             # e_shoff
    e += struct.pack("<I", 0)             # e_flags
    e += struct.pack("<H", EHDR)          # e_ehsize
    e += struct.pack("<H", PHENT)         # e_phentsize
    e += struct.pack("<H", NPH)           # e_phnum
    e += struct.pack("<H", 0)             # e_shentsize
    e += struct.pack("<H", 0)             # e_shnum
    e += struct.pack("<H", 0)             # e_shstrndx

    PT_LOAD = 1
    PF_X, PF_W, PF_R = 1, 2, 4

    def phdr(p_type, p_flags, p_offset, p_vaddr, p_filesz, p_memsz, p_align):
        return struct.pack("<IIQQQQQQ", p_type, p_flags, p_offset, p_vaddr,
                           p_vaddr, p_filesz, p_memsz, p_align)

    ph_code = phdr(PT_LOAD, PF_R | PF_X, 0, code_vbase,
                   code_filesz, code_filesz, align)
    ph_data = phdr(PT_LOAD, PF_R | PF_W, data_file_off, data_vbase,
                   data_filesz, data_memsz, align)

    img = bytearray()
    img += e
    img += ph_code
    img += ph_data
    assert len(img) == headers_len, (len(img), headers_len)
    img += code_seg
    # pad to data_file_off
    if len(img) < data_file_off:
        img += b"\x00" * (data_file_off - len(img))
    img += gdata

    out_path.write_bytes(img)
    os.chmod(out_path, 0o755)


# --------------------------------------------------------------------------
# Top-level: compile a body through codegen.ad and run the wrapped ELF.
# --------------------------------------------------------------------------
class CodegenRun:
    def __init__(self, kind, **kw):
        # kind: "unsupported" | "ok" | "runfail" | "drivererror"
        self.kind = kind
        self.stdout = kw.get("stdout", "")
        self.exit = kw.get("exit", None)
        self.detail = kw.get("detail", "")
        self.folds = kw.get("folds", 0)
        self.cse = kw.get("cse", 0)
        self.licm = kw.get("licm", 0)
        self.iremit = kw.get("iremit", 0)
        self.irfold = kw.get("irfold", 0)
        self.irreassoc = kw.get("irreassoc", 0)


def run_through_codegen_ad(seed, body, work_dir: Path, keep=False, opt=False):
    work_dir.mkdir(parents=True, exist_ok=True)
    cg_body = codegen_compatible_source(body)
    src = work_dir / f"ad_{seed}.ad"
    elf = work_dir / f"ad_{seed}.elf"
    src.write_text(cg_body)
    try:
        dump = run_dump(src, opt=opt)
    except subprocess.TimeoutExpired:
        return CodegenRun("drivererror", detail="dump driver timeout")
    if dump.status in ("cgfail", "parsefail", "readfail"):
        if not keep:
            src.unlink(missing_ok=True)
        return CodegenRun("unsupported", detail=dump.detail)
    if dump.status != "ok":
        if not keep:
            src.unlink(missing_ok=True)
        return CodegenRun("drivererror", detail=getattr(dump, "detail", "?"))
    wrap_elf(dump, elf)
    try:
        rp = subprocess.run([str(elf)], capture_output=True, text=True,
                            timeout=20)
    except subprocess.TimeoutExpired:
        if not keep:
            src.unlink(missing_ok=True); elf.unlink(missing_ok=True)
        return CodegenRun("runfail", detail="timeout")
    out = rp.stdout.strip()
    if not keep:
        src.unlink(missing_ok=True)
        elf.unlink(missing_ok=True)
    folds = getattr(dump, "folds", 0)
    cse = getattr(dump, "cse", 0)
    licm = getattr(dump, "licm", 0)
    iremit = getattr(dump, "iremit", 0)
    irfold = getattr(dump, "irfold", 0)
    irreassoc = getattr(dump, "irreassoc", 0)
    if rp.returncode < 0:
        return CodegenRun("runfail", detail=f"signal {-rp.returncode}",
                          stdout=out, exit=rp.returncode, folds=folds, cse=cse,
                          licm=licm, iremit=iremit, irfold=irfold,
                          irreassoc=irreassoc)
    return CodegenRun("ok", stdout=out, exit=rp.returncode & 0xFF,
                      folds=folds, cse=cse, licm=licm, iremit=iremit,
                      irfold=irfold, irreassoc=irreassoc)


if __name__ == "__main__":
    # Standalone smoke: compile a tiny program through codegen.ad and run it.
    body = (
        "_ch: Array[1, uint8]\n"
        "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
        "    _ch[0] = cast[uint8](65)\n"
        "    __syscall3(cast[int64](1), cast[int64](1), &_ch[0], cast[uint64](1))\n"
        "    return cast[int32](7)\n"
    )
    wd = REPO_ROOT / "build" / "fuzz_ad_codegen"
    r = run_through_codegen_ad(99, body, wd, keep=True)
    print("kind=", r.kind, "stdout=", repr(r.stdout), "exit=", r.exit,
          "detail=", r.detail)
