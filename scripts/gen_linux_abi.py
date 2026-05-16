#!/usr/bin/env python3
"""
scripts/gen_linux_abi.py — BTF -> Adder struct generator.

Parses BTF (BPF Type Format) out of a Linux 6.12 vmlinux image (or
the kernel's exposed `/sys/kernel/btf/vmlinux`) and emits class
definitions for a fixed set of struct types under
`linux_abi/structs/<name>.ad`.

This is the L0 deliverable of the Hamnix Linux ABI track. L1 (and
later) will consume these struct files to lay out C-Linux-compatible
in-memory objects from Adder code.

BTF format reference: Documentation/bpf/btf.rst in the Linux source.
We only implement enough of the parser to walk the type table, since
that's all we need for size + offset extraction.

Usage:
    gen_linux_abi.py                       # auto-detect BTF source
    gen_linux_abi.py <path/to/vmlinux>     # explicit path
    gen_linux_abi.py --check               # verify on-disk .ad files
    gen_linux_abi.py --check <path>        # same, explicit BTF

Exit status:
    0  success (real BTF found, files emitted or --check passed)
    1  BTF not available; mock files emitted with a clear warning
    2  --check found a mismatch between BTF and on-disk .ad files
"""

from __future__ import annotations

import os
import struct
import sys
from dataclasses import dataclass
from typing import Optional


# --------------------------------------------------------------------------
# Target configuration
# --------------------------------------------------------------------------

# The structs we extract for L0. Keep in sync with linux_abi/TARGET_ABI.md.
TARGET_STRUCTS = ("list_head", "kref", "kobject", "module")

# Default search locations for a BTF blob.
DEFAULT_BTF_PATHS = (
    "/sys/kernel/btf/vmlinux",
    "vmlinux",
    "/boot/vmlinuz-6.12",
)

# The Linux version we expect. Used in file headers; the BTF blob itself
# carries no version, so this is informational. Pulled from TARGET_ABI.md.
TARGET_KERNEL_VERSION = "6.12.48"

# Project layout
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRUCTS_DIR = os.path.join(REPO_ROOT, "linux_abi", "structs")


# --------------------------------------------------------------------------
# BTF constants (from include/uapi/linux/btf.h)
# --------------------------------------------------------------------------

BTF_MAGIC = 0xEB9F

BTF_KIND_VOID = 0
BTF_KIND_INT = 1
BTF_KIND_PTR = 2
BTF_KIND_ARRAY = 3
BTF_KIND_STRUCT = 4
BTF_KIND_UNION = 5
BTF_KIND_ENUM = 6
BTF_KIND_FWD = 7
BTF_KIND_TYPEDEF = 8
BTF_KIND_VOLATILE = 9
BTF_KIND_CONST = 10
BTF_KIND_RESTRICT = 11
BTF_KIND_FUNC = 12
BTF_KIND_FUNC_PROTO = 13
BTF_KIND_VAR = 14
BTF_KIND_DATASEC = 15
BTF_KIND_FLOAT = 16
BTF_KIND_DECL_TAG = 17
BTF_KIND_TYPE_TAG = 18
BTF_KIND_ENUM64 = 19

# BTF integer encoding flags (in the trailing 4-byte int info word)
BTF_INT_SIGNED = 1
BTF_INT_CHAR = 2
BTF_INT_BOOL = 4


# --------------------------------------------------------------------------
# Parser
# --------------------------------------------------------------------------

@dataclass
class BtfType:
    tid: int
    name: str
    kind: int
    kflag: int
    vlen: int
    size_or_type: int  # struct: size_in_bytes; ptr/typedef/etc: target tid
    extra_off: int     # absolute file offset of the variable-length payload


class BtfBlob:
    """Parsed BTF section, ready for type lookups."""

    def __init__(self, data: bytes):
        self.data = data
        if len(data) < 24:
            raise ValueError("BTF blob is too short to contain a header")

        magic, version, flags, hdr_len = struct.unpack_from("<HBBI", data, 0)
        if magic != BTF_MAGIC:
            raise ValueError(
                f"Bad BTF magic: 0x{magic:04x} (expected 0x{BTF_MAGIC:04x}). "
                "This file is not a raw BTF blob; if it's a vmlinux ELF, "
                "you need to extract the .BTF section first (e.g. "
                "`pahole --btf_encode_detached`)."
            )
        if version != 1:
            raise ValueError(f"Unsupported BTF version: {version}")

        type_off, type_len, str_off, str_len = struct.unpack_from(
            "<IIII", data, 8
        )

        self.type_base = hdr_len + type_off
        self.type_end = self.type_base + type_len
        self.str_base = hdr_len + str_off
        self.str_end = self.str_base + str_len

        self.types: dict[int, BtfType] = {}
        self._by_name: dict[tuple[int, str], int] = {}
        self._parse_types()

    # --- string section ---

    def get_str(self, off: int) -> str:
        if off == 0:
            return ""
        pos = self.str_base + off
        end = self.data.index(b"\x00", pos)
        return self.data[pos:end].decode("utf-8", errors="replace")

    # --- type table walk ---

    def _parse_types(self) -> None:
        pos = self.type_base
        tid = 1
        while pos < self.type_end:
            name_off, info, size_or_type = struct.unpack_from(
                "<III", self.data, pos
            )
            vlen = info & 0xFFFF
            kind = (info >> 24) & 0x1F
            kflag = (info >> 31) & 1

            extra_off = pos + 12
            extra_bytes = self._extra_len(kind, vlen)

            name = self.get_str(name_off)
            self.types[tid] = BtfType(
                tid=tid,
                name=name,
                kind=kind,
                kflag=kflag,
                vlen=vlen,
                size_or_type=size_or_type,
                extra_off=extra_off,
            )
            if name and kind in (
                BTF_KIND_STRUCT,
                BTF_KIND_UNION,
                BTF_KIND_ENUM,
                BTF_KIND_ENUM64,
                BTF_KIND_TYPEDEF,
                BTF_KIND_FWD,
            ):
                self._by_name[(kind, name)] = tid

            pos = extra_off + extra_bytes
            tid += 1

    @staticmethod
    def _extra_len(kind: int, vlen: int) -> int:
        """Size of the variable-length payload after each 12-byte type header."""
        if kind == BTF_KIND_INT:
            return 4
        if kind in (BTF_KIND_STRUCT, BTF_KIND_UNION):
            return vlen * 12  # name_off + type + offset
        if kind == BTF_KIND_ENUM:
            return vlen * 8
        if kind == BTF_KIND_ARRAY:
            return 12
        if kind == BTF_KIND_FUNC_PROTO:
            return vlen * 8
        if kind == BTF_KIND_VAR:
            return 4
        if kind == BTF_KIND_DATASEC:
            return vlen * 12
        if kind == BTF_KIND_DECL_TAG:
            return 4
        if kind == BTF_KIND_ENUM64:
            return vlen * 12
        # PTR, FWD, TYPEDEF, VOLATILE, CONST, RESTRICT, FUNC, FLOAT,
        # TYPE_TAG: no trailing payload.
        return 0

    # --- lookups ---

    def find_struct(self, name: str) -> Optional[BtfType]:
        tid = self._by_name.get((BTF_KIND_STRUCT, name))
        return self.types[tid] if tid is not None else None

    def members(self, t: BtfType) -> list[tuple[str, int, int]]:
        """Return [(name, type_id, bit_offset)] for a struct/union type."""
        out = []
        for i in range(t.vlen):
            mname_off, mtype, moff = struct.unpack_from(
                "<III", self.data, t.extra_off + i * 12
            )
            out.append((self.get_str(mname_off), mtype, moff))
        return out

    # --- type resolution ---

    def render_type(self, tid: int, _depth: int = 0) -> str:
        """Return an Adder-ish type spelling for a given BTF tid."""
        if _depth > 8:
            return "?"
        if tid == 0:
            return "void"
        t = self.types[tid]
        k = t.kind
        if k == BTF_KIND_INT:
            ival, = struct.unpack_from("<I", self.data, t.extra_off)
            bits = ival & 0xFF
            encoding = (ival >> 24) & 0xF
            signed = bool(encoding & BTF_INT_SIGNED)
            # Promote odd widths to the nearest standard so the Adder
            # type spelling stays well-defined.
            if bits not in (8, 16, 32, 64):
                bits = (bits + 7) & ~7 or 8
            return ("int" if signed else "uint") + str(bits)
        if k == BTF_KIND_PTR:
            return "uint64"  # pointers as 8-byte opaque on x86_64
        if k == BTF_KIND_ARRAY:
            et, _it, nelems = struct.unpack_from(
                "<III", self.data, t.extra_off
            )
            return f"{self.render_type(et, _depth + 1)}[{nelems}]"
        if k == BTF_KIND_STRUCT:
            return f"struct_{t.name or 'anon'}"
        if k == BTF_KIND_UNION:
            return f"union_{t.name or 'anon'}"
        if k in (BTF_KIND_ENUM, BTF_KIND_ENUM64):
            return f"enum_{t.name or 'anon'}_u32"  # all BTF enums are 4B unless size says otherwise
        if k in (
            BTF_KIND_TYPEDEF,
            BTF_KIND_CONST,
            BTF_KIND_VOLATILE,
            BTF_KIND_RESTRICT,
            BTF_KIND_TYPE_TAG,
        ):
            return self.render_type(t.size_or_type, _depth + 1)
        if k == BTF_KIND_FUNC_PROTO:
            return "uint64"  # function pointer == 8 bytes
        if k == BTF_KIND_FWD:
            return f"fwd_{t.name}"
        if k == BTF_KIND_FLOAT:
            return t.name or "float"
        return f"kind{k}"

    def type_size(self, tid: int, _depth: int = 0) -> int:
        if _depth > 16 or tid == 0:
            return 0
        t = self.types[tid]
        k = t.kind
        if k == BTF_KIND_INT:
            ival, = struct.unpack_from("<I", self.data, t.extra_off)
            return (ival & 0xFF) // 8
        if k == BTF_KIND_PTR:
            return 8
        if k == BTF_KIND_ARRAY:
            et, _it, nelems = struct.unpack_from(
                "<III", self.data, t.extra_off
            )
            return self.type_size(et, _depth + 1) * nelems
        if k in (
            BTF_KIND_STRUCT,
            BTF_KIND_UNION,
            BTF_KIND_ENUM,
            BTF_KIND_FLOAT,
            BTF_KIND_ENUM64,
        ):
            return t.size_or_type
        if k in (
            BTF_KIND_TYPEDEF,
            BTF_KIND_CONST,
            BTF_KIND_VOLATILE,
            BTF_KIND_RESTRICT,
            BTF_KIND_TYPE_TAG,
        ):
            return self.type_size(t.size_or_type, _depth + 1)
        if k == BTF_KIND_FUNC_PROTO:
            return 8
        return 0


# --------------------------------------------------------------------------
# Emission
# --------------------------------------------------------------------------

def _format_class(
    *,
    struct_name: str,
    members: list[tuple[str, str, int, int, str]],  # name, ad_type, off, size, comment
    size: int,
    tid: str | int,
    source_header: str,
    kernel_version: str,
    is_mock: bool,
    mock_note: str = "",
) -> str:
    """Render an Adder source file for one struct."""
    lines = []
    lines.append(f"# linux_abi/structs/{struct_name}.ad — AUTOGENERATED, do not edit.")
    lines.append(f"# Source: struct {struct_name} ({source_header}) in Linux {kernel_version}")
    lines.append(f"# BTF type ID: {tid}")
    lines.append(f"# Generated by: scripts/gen_linux_abi.py")
    lines.append(f"# Size: {size} bytes")
    if is_mock:
        lines.append("#")
        lines.append("# MOCK: this file was emitted without a real BTF blob.")
        lines.append("# Field layouts are hand-translated from Linux 6.12 headers and")
        lines.append("# MUST be verified against real BTF before L1 can claim correctness.")
        if mock_note:
            for ln in mock_note.splitlines():
                lines.append(f"# {ln}")
    lines.append("")
    lines.append(f"class {struct_name}:")
    if not members:
        lines.append("    pass")
    else:
        for mname, mtype, moff, msize, comment in members:
            end = moff + msize - 1 if msize > 0 else moff
            base = f"    {mname}: {mtype}"
            tail = f"# {moff}..{end}"
            if comment:
                tail += f"  ({comment})"
            # Pad to column 48 so the comments line up like the spec example.
            pad = max(1, 48 - len(base))
            lines.append(base + " " * pad + tail)
    lines.append("")
    return "\n".join(lines)


def _ad_member_type_and_size(
    btf: BtfBlob, member_tid: int
) -> tuple[str, int, str]:
    """Map a BTF member type to an Adder type name + byte size + raw C-ish comment."""
    raw = btf.render_type(member_tid)
    size = btf.type_size(member_tid)

    # Walk through type modifiers to get the underlying kind
    t = btf.types[member_tid]
    while t.kind in (
        BTF_KIND_TYPEDEF,
        BTF_KIND_CONST,
        BTF_KIND_VOLATILE,
        BTF_KIND_RESTRICT,
        BTF_KIND_TYPE_TAG,
    ):
        t = btf.types[t.size_or_type]

    if t.kind == BTF_KIND_PTR:
        # Best-effort: spell out the pointee for documentation
        pointee = btf.render_type(t.size_or_type)
        return "uint64", 8, f"{pointee} *"
    if t.kind == BTF_KIND_FUNC_PROTO:
        return "uint64", 8, "function pointer"
    if t.kind == BTF_KIND_ARRAY:
        et, _it, nelems = struct.unpack_from(
            "<III", btf.data, t.extra_off
        )
        elem_t = btf.types[et]
        # Drill through modifiers on the element type
        while elem_t.kind in (
            BTF_KIND_TYPEDEF,
            BTF_KIND_CONST,
            BTF_KIND_VOLATILE,
            BTF_KIND_RESTRICT,
            BTF_KIND_TYPE_TAG,
        ):
            elem_t = btf.types[elem_t.size_or_type]
        elem_render = btf.render_type(et)
        return f"{elem_render}[{nelems}]", size, ""
    if t.kind == BTF_KIND_STRUCT:
        return f"opaque_bytes[{size}]", size, f"struct {t.name}"
    if t.kind == BTF_KIND_UNION:
        return f"opaque_bytes[{size}]", size, f"union {t.name}"
    if t.kind in (BTF_KIND_ENUM, BTF_KIND_ENUM64):
        # Plain enum sized by the struct; render as the underlying int
        if size == 4:
            return "int32", 4, f"enum {t.name}"
        if size == 8:
            return "int64", 8, f"enum {t.name}"
        return f"opaque_bytes[{size}]", size, f"enum {t.name}"
    return raw, size, ""


def emit_struct(btf: BtfBlob, struct_name: str, source_header: str) -> str:
    t = btf.find_struct(struct_name)
    if t is None:
        raise ValueError(f"BTF has no struct named {struct_name!r}")

    members_out = []
    members = btf.members(t)
    for i, (mname, mtype, mbit_off) in enumerate(members):
        # Non-bitfield kflag=0: offset is in bits but always byte-aligned.
        if t.kflag == 0:
            byte_off = mbit_off // 8
        else:
            # bitfield_size:offset packed
            bit_size = (mbit_off >> 24) & 0xFF
            byte_off = (mbit_off & 0x00FFFFFF) // 8
            # We treat bitfields as opaque for L0.
            if bit_size:
                ad_type, sz, raw = "opaque_bits", 0, f"bitfield, {bit_size} bits"
                members_out.append((mname or f"_field{i}", ad_type, byte_off, sz, raw))
                continue
        ad_type, sz, raw = _ad_member_type_and_size(btf, mtype)
        members_out.append((mname or f"_field{i}", ad_type, byte_off, sz, raw))

    return _format_class(
        struct_name=struct_name,
        members=members_out,
        size=t.size_or_type,
        tid=t.tid,
        source_header=source_header,
        kernel_version=TARGET_KERNEL_VERSION,
        is_mock=False,
    )


# --------------------------------------------------------------------------
# Mock layouts (used when no BTF is available)
# --------------------------------------------------------------------------

SOURCE_HEADERS = {
    "list_head": "include/linux/types.h",
    "kref":      "include/linux/kref.h",
    "kobject":   "include/linux/kobject.h",
    "module":    "include/linux/module.h",
}


def mock_list_head() -> str:
    members = [
        ("next", "uint64", 0, 8, "struct list_head *"),
        ("prev", "uint64", 8, 8, "struct list_head *"),
    ]
    return _format_class(
        struct_name="list_head",
        members=members,
        size=16,
        tid="MOCK",
        source_header=SOURCE_HEADERS["list_head"],
        kernel_version=TARGET_KERNEL_VERSION,
        is_mock=True,
    )


def mock_kref() -> str:
    members = [
        ("refs", "int32", 0, 4, "refcount_t.refs"),
    ]
    return _format_class(
        struct_name="kref",
        members=members,
        size=4,
        tid="MOCK",
        source_header=SOURCE_HEADERS["kref"],
        kernel_version=TARGET_KERNEL_VERSION,
        is_mock=True,
    )


def mock_kobject() -> str:
    # 64-byte placeholder; fields not exercised by L1 yet.
    members = [
        ("_opaque", "opaque_bytes[64]", 0, 64, "kobject (fields not yet used)"),
    ]
    return _format_class(
        struct_name="kobject",
        members=members,
        size=64,
        tid="MOCK",
        source_header=SOURCE_HEADERS["kobject"],
        kernel_version=TARGET_KERNEL_VERSION,
        is_mock=True,
    )


def mock_module() -> str:
    # Hand-picked subset of fields L1 will need. The remainder of the
    # 1280-byte struct is padded out as opaque bytes so the overall
    # size matches what real Linux 6.12 emits.
    members = [
        ("state",     "int32",            0,    4,  "enum module_state"),
        ("_pad1",     "opaque_bytes[4]",  4,    4,  "alignment"),
        ("list",      "opaque_bytes[16]", 8,    16, "struct list_head"),
        ("name",      "uint8[56]",        24,   56, "char name[56]"),
        ("_pad2",     "opaque_bytes[232]", 80,  232, "mkobj, modinfo_attrs, version, ..."),
        ("init",      "uint64",           312,  8,  "int (*init)(void)"),
        ("_pad3",     "opaque_bytes[880]", 320, 880, "mem[7], arch, bug_table, kallsyms, ..."),
        ("exit",      "uint64",           1200, 8,  "void (*exit)(void)"),
        ("_pad4",     "opaque_bytes[72]", 1208, 72, "refcnt + trailing fields"),
    ]
    note = (
        "Field offsets are best-effort estimates for Linux 6.12 mainline. "
        "Distro kernels (e.g. Debian) add fields and shift offsets — run "
        "`gen_linux_abi.py /sys/kernel/btf/vmlinux` on the real target to "
        "regenerate. Note: 6.12 replaced `core_layout` with `mem[7]`; "
        "L1 callers should NOT assume a `core_layout.base` field exists."
    )
    return _format_class(
        struct_name="module",
        members=members,
        size=1280,
        tid="MOCK",
        source_header=SOURCE_HEADERS["module"],
        kernel_version=TARGET_KERNEL_VERSION,
        is_mock=True,
        mock_note=note,
    )


MOCK_EMITTERS = {
    "list_head": mock_list_head,
    "kref":      mock_kref,
    "kobject":   mock_kobject,
    "module":    mock_module,
}


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------

def find_btf_blob(explicit_path: Optional[str]) -> Optional[bytes]:
    candidates = [explicit_path] if explicit_path else list(DEFAULT_BTF_PATHS)
    for path in candidates:
        if not path:
            continue
        if not os.path.exists(path):
            continue
        try:
            with open(path, "rb") as f:
                head = f.read(2)
            if len(head) < 2:
                continue
            magic, = struct.unpack("<H", head)
            if magic != BTF_MAGIC:
                # Not a raw BTF blob (probably an ELF — we don't dig into
                # .BTF sections in L0). Skip.
                continue
            with open(path, "rb") as f:
                return f.read()
        except (OSError, PermissionError):
            continue
    return None


def print_btf_instructions(tried: list[str]) -> None:
    print(
        "ERROR: no BTF blob found.\n"
        "\n"
        "Tried:\n"
        + "\n".join(f"  - {p}" for p in tried)
        + "\n\n"
        "To obtain BTF for Linux 6.12:\n"
        "  Debian/Ubuntu:\n"
        "    sudo apt install linux-image-6.12-generic\n"
        "    # then BTF appears at /sys/kernel/btf/vmlinux when booted on it\n"
        "  Or build from source:\n"
        "    git clone --depth=1 --branch v6.12.48 \\\n"
        "      https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git\n"
        "    cd linux && make defconfig && \\\n"
        "      scripts/config -e CONFIG_DEBUG_INFO_BTF && make -j$(nproc) vmlinux\n"
        "    # then extract: pahole --btf_encode_detached out.btf vmlinux\n"
        "\n"
        "Falling back to MOCK struct layouts so L1 work can proceed.\n",
        file=sys.stderr,
    )


def cmd_generate(explicit_path: Optional[str]) -> int:
    os.makedirs(STRUCTS_DIR, exist_ok=True)
    blob = find_btf_blob(explicit_path)
    if blob is None:
        tried = [explicit_path] if explicit_path else list(DEFAULT_BTF_PATHS)
        print_btf_instructions(tried)
        # Emit mocks.
        print("Emitting MOCK struct files:", file=sys.stderr)
        for name in TARGET_STRUCTS:
            text = MOCK_EMITTERS[name]()
            out = os.path.join(STRUCTS_DIR, f"{name}.ad")
            with open(out, "w") as f:
                f.write(text)
            print(f"  WARNING: mock {out}", file=sys.stderr)
        return 1

    btf = BtfBlob(blob)
    for name in TARGET_STRUCTS:
        text = emit_struct(btf, name, SOURCE_HEADERS[name])
        out = os.path.join(STRUCTS_DIR, f"{name}.ad")
        with open(out, "w") as f:
            f.write(text)
        t = btf.find_struct(name)
        size = t.size_or_type if t else "?"
        tid = t.tid if t else "?"
        print(f"  wrote {out}  (tid={tid}, size={size})")
    return 0


def cmd_check(explicit_path: Optional[str]) -> int:
    blob = find_btf_blob(explicit_path)
    if blob is None:
        print(
            "--check requires a BTF blob; none found. See instructions above.",
            file=sys.stderr,
        )
        tried = [explicit_path] if explicit_path else list(DEFAULT_BTF_PATHS)
        print_btf_instructions(tried)
        return 1
    btf = BtfBlob(blob)
    mismatches = 0
    for name in TARGET_STRUCTS:
        expected = emit_struct(btf, name, SOURCE_HEADERS[name])
        path = os.path.join(STRUCTS_DIR, f"{name}.ad")
        if not os.path.exists(path):
            print(f"  MISSING: {path}", file=sys.stderr)
            mismatches += 1
            continue
        with open(path) as f:
            actual = f.read()
        if actual != expected:
            print(f"  MISMATCH: {path}", file=sys.stderr)
            mismatches += 1
        else:
            print(f"  OK: {path}")
    if mismatches:
        print(
            f"--check failed: {mismatches} file(s) differ from BTF. "
            "Re-run without --check to regenerate.",
            file=sys.stderr,
        )
        return 2
    print("--check passed: all struct files match BTF.")
    return 0


def main(argv: list[str]) -> int:
    args = argv[1:]
    check = False
    path = None
    for a in args:
        if a == "--check":
            check = True
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        elif a.startswith("-"):
            print(f"unknown flag: {a}", file=sys.stderr)
            return 2
        else:
            path = a
    if check:
        return cmd_check(path)
    return cmd_generate(path)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
