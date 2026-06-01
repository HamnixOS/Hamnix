#!/usr/bin/env python3
"""
scripts/gen_autostubs.py — Hamnix Linux-ABI autostub generator.

Scans every bundled kernel-modules/*/*.ko file for UND (undefined /
external) symbols whose names match a small catalog of mechanical
"trivial stub" patterns — names where the right behaviour is always
the same regardless of which driver is asking for them. The script
emits linux_abi/api_autostubs.ad: one shim per match plus a single
linux_abi_register_autostubs() registration function the kernel
calls from linux_abi_exports_init() at boot.

The mechanical patterns are the ones agents have been hand-writing
over and over in api_*.ad for every new .ko. Closing this at the
build-tool level means every future .ko load gets these for free —
no agent ever needs to discover the same gap twice.

Pattern catalog (each row is an UND-name regex + the stub shape):

    __SCK__*                  no-op fn  (static_call_key — never deref'd)
    __SCT__tp_func_*          ret 0 fn  (tracepoint static-call trampoline)
    __SCT__*                  no-op fn  (static_call_tramp — patched at boot)
    __tracepoint_*            64-byte zeroed BSS struct (no probes attached)
    __traceiter_*             ret 0 fn  (iterator entry — no probes attached)
    __bpf_trace_*             no-op fn  (BPF trace probe — never invoked)
    __profile_*               no-op fn  (kbuild profile point)
    __x86_indirect_thunk_r*   `popq %rbp; jmpq *%r{reg}` retpoline thunk
    __x86_indirect_thunk_rax  `popq %rbp; jmpq *%rax` (same idea — explicit
    __x86_indirect_thunk_rbx   row per GPR so the regex stays simple)
    __x86_indirect_thunk_rcx
    __x86_indirect_thunk_rdx
    __x86_indirect_thunk_rsi
    __x86_indirect_thunk_rdi
    __x86_indirect_thunk_rbp
    __x86_return_thunk        bare ret fn
    __fentry__                bare ret fn

Cross-reference: every name already shimmed by a hand-written api_*.ad
(any _add_export call line in linux_abi/api_*.ad or exports.ad) is
SKIPPED. The autostub file is the always-on safety net for symbols
the hand-written shims haven't reached yet — it never overrides an
intentional hand-shim.

Usage:
    scripts/gen_autostubs.py                # writes linux_abi/api_autostubs.ad
    scripts/gen_autostubs.py --print-only   # diagnostic: list what would emit
    scripts/gen_autostubs.py --check        # exit 1 if regenerate would change

Stdout summary at the end:
    [gen_autostubs] scanned N .ko files, M UND symbols
    [gen_autostubs] matched K trivial patterns, S skipped (already shimmed)
    [gen_autostubs] emitted A autostubs into linux_abi/api_autostubs.ad
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable

HERE = Path(__file__).resolve().parent.parent
KMODS = HERE / "kernel-modules"
LINUX_ABI = HERE / "linux_abi"
OUT = LINUX_ABI / "api_autostubs.ad"

# Committed per-.ko UND-symbol manifest. Records, per curated .ko, the
# catalog-matched UND symbol names. The generator UNIONS the manifest
# with whatever .ko files are physically present at scan time, so a stub
# for a transiently-absent driver (large .ko's like i915.ko / drm.ko are
# harvested only by their own test, gitignored otherwise) survives a
# build that doesn't have that .ko on disk. When a .ko IS present, its
# manifest entry is refreshed/augmented (monotonic union, never shrinks)
# and the manifest file rewritten — so the manifest is self-healing.
#
# This is what makes api_autostubs.ad a STABLE committed artifact: its
# content is the union across ALL curated drivers, invariant to which
# .ko subset a given build happens to have present.
MANIFEST = LINUX_ABI / "autostub_und_manifest.json"

# Catalog: ordered list of (regex, stub-kind, comment). Stub-kind drives
# the emission shape in render_autostub_file(). The order matters only
# for diagnostics — the first matching row wins for each UND name.
#
# Stub kinds:
#   "noop"        zero-arg function with empty body (returns immediately)
#   "ret0"        zero-arg function returning int32 0
#   "bss64"       64-byte zeroed BSS Array (data export — address only)
#   "thunk_REG"   x86 retpoline trampoline for `call *%REG`
#                 (REG inferred from the regex match group)
CATALOG: list[tuple[re.Pattern[str], str, str]] = [
    # Order: more specific patterns FIRST so e.g. __SCT__tp_func_* wins
    # over __SCT__* (which would also match it).
    (re.compile(r"^__SCT__tp_func_.+$"), "ret0",
     "tracepoint static-call trampoline — ret 0"),
    (re.compile(r"^__SCK__.+$"), "noop",
     "static_call_key — never dereferenced at runtime"),
    (re.compile(r"^__SCT__.+$"), "noop",
     "static_call_tramp — patched at boot, no-op fallback"),
    (re.compile(r"^__tracepoint_.+$"), "bss64",
     "tracepoint struct — 64-byte zeroed (no probe attached)"),
    (re.compile(r"^__traceiter_.+$"), "ret0",
     "tracepoint iterator entry — ret 0 (no probes)"),
    (re.compile(r"^__bpf_trace_.+$"), "noop",
     "BPF trace probe — never invoked"),
    (re.compile(r"^__profile_.+$"), "noop",
     "kbuild profile point — no-op"),
    # Retpoline thunks: one row per GPR. The regex captures the reg
    # name so render_autostub_file() can spit out the right `jmpq *%r{N}`.
    (re.compile(r"^__x86_indirect_thunk_(rax|rbx|rcx|rdx|rsi|rdi|rbp"
                r"|r8|r9|r10|r11|r12|r13|r14|r15)$"), "thunk",
     "x86 retpoline thunk — popq %rbp; jmpq *%<reg>"),
    (re.compile(r"^__x86_return_thunk$"), "noop",
     "x86 return thunk — bare ret"),
    (re.compile(r"^__fentry__$"), "noop",
     "gcc -mfentry trampoline — bare ret"),
]


def _und_symbols(ko_path: Path) -> list[str]:
    """Return the UND (undefined / external) symbol names from one .ko."""
    try:
        out = subprocess.check_output(
            ["nm", "-u", str(ko_path)],
            stderr=subprocess.DEVNULL,
        ).decode("utf-8", "replace")
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    syms: list[str] = []
    for line in out.splitlines():
        # `nm -u` output: "                 U <name>" (variable spacing).
        parts = line.split()
        if len(parts) >= 2 and parts[-2] == "U":
            syms.append(parts[-1])
        elif len(parts) == 2 and parts[0] == "U":
            syms.append(parts[1])
    return syms


def _existing_shimmed_names() -> set[str]:
    """Collect every name appearing in an _add_export("...") call across
    linux_abi/*.ad. This is the union of all hand-written shims; the
    autostub file never re-exports any of them.
    """
    pat = re.compile(r'_add_export\(\s*"([^"]+)"')
    names: set[str] = set()
    for p in sorted(LINUX_ABI.glob("api_*.ad")):
        # We don't read api_autostubs.ad itself — that's the output.
        if p.name == "api_autostubs.ad":
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in pat.finditer(text):
            names.add(m.group(1))
    # exports.ad has hand-rolled _add_export calls too (printk family,
    # __fentry__, __x86_return_thunk, __stack_chk_*, kmalloc family).
    exp = LINUX_ABI / "exports.ad"
    if exp.is_file():
        text = exp.read_text(encoding="utf-8", errors="replace")
        for m in pat.finditer(text):
            names.add(m.group(1))
    return names


def _scan_modules() -> tuple[list[Path], dict[str, list[str]]]:
    """Walk kernel-modules/*/*.ko (mirrors build_initramfs.py's glob).

    Returns (ko_files, per_ko_und_map). per_ko_und_map keys are the
    .ko basename without extension; values are the UND symbol lists.
    """
    ko_files: list[Path] = []
    per_ko: dict[str, list[str]] = {}
    if not KMODS.is_dir():
        return ko_files, per_ko
    for sub in sorted(KMODS.iterdir()):
        if not sub.is_dir():
            continue
        for ko in sorted(sub.glob("*.ko")):
            ko_files.append(ko)
            per_ko[ko.stem] = _und_symbols(ko)
    return ko_files, per_ko


def _load_manifest() -> dict[str, list[str]]:
    """Load the committed per-.ko UND manifest (ko_stem -> sorted names).

    Returns an empty dict if the file is missing or unreadable — the
    generator then degrades to pure live-scan behaviour (no crash).
    """
    if not MANIFEST.is_file():
        return {}
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    out: dict[str, list[str]] = {}
    for stem, syms in data.items():
        if isinstance(syms, list):
            out[str(stem)] = [str(s) for s in syms]
    return out


def _merge_manifest(manifest: dict[str, list[str]],
                    per_ko_matched: dict[str, list[str]]) -> dict[str, list[str]]:
    """Union the live-scanned catalog-matched symbols into the manifest.

    For each .ko present on disk, its manifest entry becomes the union of
    the previously-recorded names and the freshly-scanned names — so the
    manifest grows monotonically and self-heals when a driver IS present.
    A .ko that is absent at scan time keeps its recorded entry untouched
    (that is the whole point: transiently-absent drivers' stubs survive).
    """
    merged: dict[str, list[str]] = {k: list(v) for k, v in manifest.items()}
    for stem, matched in per_ko_matched.items():
        prev = set(merged.get(stem, []))
        prev.update(matched)
        merged[stem] = sorted(prev)
    # Drop empty entries so the manifest stays tidy.
    return {k: v for k, v in sorted(merged.items()) if v}


def _manifest_text(manifest: dict[str, list[str]]) -> str:
    """Deterministic, byte-stable JSON serialization of the manifest."""
    ordered = {k: sorted(set(manifest[k])) for k in sorted(manifest)}
    return json.dumps(ordered, indent=2, sort_keys=True) + "\n"


def _classify(name: str) -> tuple[str | None, str | None, str]:
    """Return (kind, reg, comment) for `name`. kind is None if no
    pattern matches. reg is set only for thunk-kind entries.
    """
    for pat, kind, comment in CATALOG:
        m = pat.match(name)
        if m:
            reg = m.group(1) if (kind == "thunk" and m.groups()) else None
            return kind, reg, comment
    return None, None, ""


# --- Adder file emission -------------------------------------------------

HEADER = '''# linux_abi/api_autostubs.ad
#
# AUTO-GENERATED by scripts/gen_autostubs.py — DO NOT HAND-EDIT.
# Regenerate via `python3 scripts/gen_autostubs.py` (build_initramfs.py
# also runs the generator on every build, so any new bundled .ko picks
# up its mechanical-stub coverage automatically).
#
# This file shims the UND symbols across every kernel-modules/*/*.ko
# that match a small catalog of mechanical patterns:
#
#   * Static-call keys   (__SCK__*)            — never dereferenced
#   * Static-call tramps (__SCT__*)            — patched at boot
#   * Tracepoint structs (__tracepoint_*)      — 64-byte zeroed
#   * Tracepoint iters   (__traceiter_*)       — ret 0
#   * BPF trace probes   (__bpf_trace_*)       — never invoked
#   * Profile points     (__profile_*)         — no-op
#   * Retpoline thunks   (__x86_indirect_thunk_*) — popq %rbp; jmpq *%reg
#   * Return thunk       (__x86_return_thunk)  — bare ret
#   * fentry trampoline  (__fentry__)          — bare ret
#
# Every name already shimmed by hand in another api_*.ad (or exports.ad)
# is SKIPPED. The autostub file is the always-on safety net; it never
# overrides an intentional hand-rolled shim.
#
# Closing this gap at build-tool level means every future .ko load
# gets these stubs for free — no agent ever has to re-discover them.

from linux_abi.exports import _add_export
from kernel.printk.printk import printk1

'''

THUNK_FN_TEMPLATE = '''def _auto___x86_indirect_thunk_{reg}():
    # Retpoline replacement for `call *%{reg}`. Adder emits a
    # `push %rbp; mov %rsp, %rbp` prologue we must undo before the
    # indirect jump — otherwise the callee returns into the saved
    # %rbp slot rather than the caller's return address.
    asm_volatile("""
        popq %rbp
        jmpq *%{reg}
    """)


'''

NOOP_FN_TEMPLATE = '''def _auto_{symid}():
    # {comment}
    return


'''

RET0_FN_TEMPLATE = '''def _auto_{symid}() -> int32:
    # {comment}
    return 0


'''

BSS64_DATA_TEMPLATE = '''_auto_{symid}: Array[64, uint8]
'''


def _ad_safe_id(name: str) -> str:
    """Adder identifiers allow letters/digits/underscore. UND names are
    already that shape — no transformation needed. Helper kept for
    symmetry with future patterns that might carry dots / colons.
    """
    return name


def render_autostub_file(matches: list[tuple[str, str, str | None, str]]) -> str:
    """matches is a sorted list of (sym_name, kind, reg, comment).

    Layout of the emitted file:
       1. Header docstring
       2. BSS data exports (Array[64, uint8] tracepoint structs)
       3. Function shims (no-op / ret0 / thunk_*)
       4. linux_abi_register_autostubs() — one _add_export per match
    """
    parts: list[str] = [HEADER]

    bss = [m for m in matches if m[1] == "bss64"]
    thunks = [m for m in matches if m[1] == "thunk"]
    noops = [m for m in matches if m[1] == "noop"]
    ret0s = [m for m in matches if m[1] == "ret0"]

    if bss:
        parts.append("# --- BSS data exports (zeroed tracepoint structs) ---\n\n")
        for name, _kind, _reg, _comment in bss:
            parts.append(BSS64_DATA_TEMPLATE.format(symid=_ad_safe_id(name)))
        parts.append("\n")

    if thunks:
        parts.append("# --- x86 retpoline thunks ---\n\n")
        for _name, _kind, reg, _comment in thunks:
            parts.append(THUNK_FN_TEMPLATE.format(reg=reg))

    if noops:
        parts.append("# --- no-op function stubs ---\n\n")
        for name, _kind, _reg, comment in noops:
            parts.append(NOOP_FN_TEMPLATE.format(
                symid=_ad_safe_id(name), comment=comment))

    if ret0s:
        parts.append("# --- ret-0 function stubs ---\n\n")
        for name, _kind, _reg, comment in ret0s:
            parts.append(RET0_FN_TEMPLATE.format(
                symid=_ad_safe_id(name), comment=comment))

    # Registration function: one _add_export per match. Grouped in the
    # same order as the emission above for readability. Even if there
    # are zero matches (every catalog pattern already hand-shimmed), we
    # still emit the function + boot-time printk so the test harness
    # can detect the registration ran.
    parts.append("# --- registration --------------------------------------\n\n")
    parts.append("def linux_abi_register_autostubs():\n")
    parts.append("    # Called from linux_abi_exports_init(). Adds the\n")
    parts.append("    # mechanical-pattern shims for every bundled .ko UND\n")
    parts.append("    # that isn't already covered by a hand-written api_*.ad.\n")
    parts.append("    # The printk at the end prints the count actually\n")
    parts.append("    # added — useful for spotting catalog drift over time.\n")
    parts.append(f"    n_total: uint64 = {len(matches)}\n")

    if not matches:
        parts.append('    printk1("linux_abi_register_autostubs registered '
                     '%d symbols\\n", n_total)\n')
        return "".join(parts)

    def _emit_group(label: str, group: Iterable[tuple[str, str, str | None, str]],
                    thunk: bool = False) -> None:
        first = True
        for name, _kind, reg, _comment in group:
            if first:
                parts.append(f"    # {label}\n")
                first = False
            if thunk:
                target = f"_auto___x86_indirect_thunk_{reg}"
            elif _kind == "bss64":
                target = f"&_auto_{name}[0]"
                parts.append(f'    _add_export("{name}",\n'
                             f'                cast[uint64]({target}))\n')
                continue
            else:
                target = f"&_auto_{name}"
            parts.append(f'    _add_export("{name}",\n'
                         f'                cast[uint64]({target}))\n')

    _emit_group("BSS data exports (tracepoint structs)", bss)
    _emit_group("x86 retpoline thunks", thunks, thunk=True)
    _emit_group("no-op function stubs", noops)
    _emit_group("ret-0 function stubs", ret0s)
    parts.append('    printk1("linux_abi_register_autostubs registered '
                 '%d symbols\\n", n_total)\n')
    return "".join(parts)


# --- driver --------------------------------------------------------------

def generate(verbose: bool = True
             ) -> tuple[str, dict[str, int], dict[str, list[str]]]:
    """Scan, classify, render. Returns (file-content, stats, manifest).

    stats keys: ko_files, und_total, matched, skipped_shimmed,
                manifest_only.
    The returned manifest is the merged (live ∪ committed) per-.ko map;
    main() persists it back to MANIFEST so it self-heals.
    """
    ko_files, per_ko_und = _scan_modules()
    shimmed = _existing_shimmed_names()

    # Per-.ko catalog-matched UND symbols from the live scan. We record
    # the matched set (not the raw UND set) so the committed manifest
    # stays small and stable.
    per_ko_matched: dict[str, list[str]] = {}
    for stem, syms in per_ko_und.items():
        matched = sorted({s for s in syms if _classify(s)[0] is not None})
        if matched:
            per_ko_matched[stem] = matched

    # Merge live scan into the committed manifest (monotonic union).
    manifest = _merge_manifest(_load_manifest(), per_ko_matched)

    # The emitted stub set is the UNION across ALL curated drivers in
    # the manifest — invariant to which .ko subset is present on disk.
    all_und: set[str] = set()
    for syms in manifest.values():
        all_und.update(syms)
    # Also include any live UND that matched but somehow isn't catalogued
    # yet (defensive — _merge_manifest already folds per_ko_matched in).
    for syms in per_ko_und.values():
        all_und.update(syms)

    # Classify + filter against the already-shimmed set.
    matches: list[tuple[str, str, str | None, str]] = []
    skipped = 0
    by_pattern: dict[str, int] = {}
    for name in sorted(all_und):
        kind, reg, comment = _classify(name)
        if kind is None:
            continue
        # Track which catalog row matched, for the diagnostic summary.
        by_pattern[kind] = by_pattern.get(kind, 0) + 1
        if name in shimmed:
            skipped += 1
            continue
        matches.append((name, kind, reg, comment))

    content = render_autostub_file(matches)

    # How many manifest entries are for .ko absent from this scan — the
    # stubs that would have been lost without the manifest union.
    live_stems = set(per_ko_matched)
    manifest_only = sum(1 for stem in manifest if stem not in live_stems)

    stats = {
        "ko_files": len(ko_files),
        "und_total": len(all_und),
        "matched": len(matches),
        "skipped_shimmed": skipped,
        "manifest_only": manifest_only,
    }

    if verbose:
        print(f"[gen_autostubs] scanned {stats['ko_files']} .ko files, "
              f"{stats['und_total']} unique UND symbols")
        print(f"[gen_autostubs] manifest: {len(manifest)} curated .ko "
              f"({manifest_only} absent from this scan, stubs preserved)")
        for kind in ("bss64", "thunk", "noop", "ret0"):
            n = by_pattern.get(kind, 0)
            if n:
                print(f"[gen_autostubs]   pattern '{kind}': {n} hits "
                      f"(some may already be hand-shimmed)")
        print(f"[gen_autostubs] matched {stats['matched']} trivial patterns, "
              f"{stats['skipped_shimmed']} skipped (already shimmed)")

    return content, stats, manifest


def main(argv: list[str]) -> int:
    print_only = "--print-only" in argv
    check = "--check" in argv

    content, stats, manifest = generate(verbose=True)
    manifest_text = _manifest_text(manifest)

    if print_only:
        sys.stdout.write(content)
        return 0

    if check:
        ok = True
        if not (OUT.is_file() and OUT.read_text(encoding="utf-8") == content):
            print(f"[gen_autostubs] FAIL: {OUT.relative_to(HERE)} out of date "
                  f"— rerun gen_autostubs.py")
            ok = False
        if not (MANIFEST.is_file()
                and MANIFEST.read_text(encoding="utf-8") == manifest_text):
            print(f"[gen_autostubs] FAIL: {MANIFEST.relative_to(HERE)} out of "
                  f"date — rerun gen_autostubs.py")
            ok = False
        if ok:
            print(f"[gen_autostubs] OK: {OUT.relative_to(HERE)} + "
                  f"{MANIFEST.relative_to(HERE)} up to date")
            return 0
        return 1

    # Persist the self-healed manifest first (only when it changed) so a
    # present-driver scan augments the committed union for next time.
    prev_manifest: str | None = None
    if MANIFEST.is_file():
        try:
            prev_manifest = MANIFEST.read_text(encoding="utf-8")
        except OSError:
            prev_manifest = None
    if prev_manifest != manifest_text:
        MANIFEST.write_text(manifest_text, encoding="utf-8")
        print(f"[gen_autostubs] updated manifest {MANIFEST.relative_to(HERE)} "
              f"({len(manifest)} curated .ko)")

    # Only rewrite if the content changed — keeps the file's mtime stable
    # so the kernel build doesn't see needless recompile triggers.
    prev: str | None = None
    if OUT.is_file():
        try:
            prev = OUT.read_text(encoding="utf-8")
        except OSError:
            prev = None
    if prev == content:
        print(f"[gen_autostubs] {OUT.relative_to(HERE)} unchanged "
              f"({stats['matched']} autostubs)")
    else:
        OUT.write_text(content, encoding="utf-8")
        print(f"[gen_autostubs] emitted {stats['matched']} autostubs into "
              f"{OUT.relative_to(HERE)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
