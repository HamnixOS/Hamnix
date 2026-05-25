#!/usr/bin/env python3
"""
scripts/build_modules_dep.py — Linux-shape modules.dep generator.

Sibling of build_modules_alias.py. Scans `kernel-modules/<name>/<name>.ko`
and emits a flat text dependency table: one line per module, listing
the modules it depends on. The in-kernel modules_dep parser
(kernel/modules_dep.ad) reads this at boot to topologically load a
module's deps before the module itself.

Output line format mirrors Linux's depmod-emitted modules.dep at the
smallest meaningful scale (we strip path prefixes since Hamnix has a
flat /lib/modules/ layout):

    <module>: <dep1> <dep2> ...

For example:

    mac80211: cfg80211 libarc4
    cfg80211: rfkill
    e1000e:

Note: a module with no deps still gets a line (with an empty dep list
after the colon) so the parser can distinguish "known module with no
deps" from "unknown module". Comment lines start with '#'.

We derive the dep list from each .ko's `modinfo -F depends` field
(comma-separated). The in-kernel parser handles the case where a
declared dep doesn't have its own .ko in the initramfs (e.g.
"libarc4" — small library we don't ship as a separate .ko) by simply
skipping the missing dep with a printk. That matches Linux's modprobe
--ignore-missing semantics in spirit.

We DO NOT do depmod-style transitive expansion here — the in-kernel
parser does that recursively when it processes a load. Hamnix's
modules.dep is the directly-declared edge set; transitive closure
happens at runtime.

Idempotent — re-runs overwrite the output.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path


def _find_modinfo() -> str:
    for cand in ("modinfo", "/sbin/modinfo", "/usr/sbin/modinfo"):
        p = shutil.which(cand) if "/" not in cand else (
            cand if os.path.exists(cand) else None)
        if p:
            return p
    raise SystemExit(
        "build_modules_dep: modinfo not found. Install the kmod "
        "package (Debian: `apt install kmod`).")


def _module_name(modinfo: str, ko_path: Path) -> str | None:
    try:
        out = subprocess.run(
            [modinfo, "-F", "name", str(ko_path)],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"  WARN: modinfo -F name {ko_path} failed: "
              f"{e.stderr.strip() or e}", file=sys.stderr)
        return None
    return out or ko_path.stem


def _module_depends(modinfo: str, ko_path: Path) -> list[str]:
    """modinfo -F depends prints a comma-separated dep list (or empty).
    Linux's depmod normalizes module names with underscores, but
    modinfo prints whatever the source declared. We emit verbatim
    and let the in-kernel parser case/separator-normalize at lookup."""
    try:
        out = subprocess.run(
            [modinfo, "-F", "depends", str(ko_path)],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"  WARN: modinfo -F depends {ko_path} failed: "
              f"{e.stderr.strip() or e}", file=sys.stderr)
        return []
    if not out:
        return []
    return [d.strip() for d in out.split(",") if d.strip()]


def build_dep_table(modules_root: Path) -> str:
    """Walk every kernel-modules/<name>/<name>.ko and emit a
    "<name>: <dep1> <dep2> ..." line per module. Modules with no
    deps still get a line (terminating colon with empty tail) so
    the parser can find them. Sorted by module name for stable
    cpio hash."""
    modinfo = _find_modinfo()
    lines: list[str] = []
    n_modules = 0
    n_deps = 0
    if not modules_root.is_dir():
        return ""
    rows: list[tuple[str, list[str]]] = []
    for sub in sorted(modules_root.iterdir()):
        if not sub.is_dir():
            continue
        for ko in sorted(sub.glob("*.ko")):
            name = _module_name(modinfo, ko)
            if name is None:
                continue
            deps = _module_depends(modinfo, ko)
            rows.append((name, deps))
    # Sort the final emit by module name so cpio hash stays stable
    # across re-runs of the same kernel-modules/ tree.
    rows.sort(key=lambda r: r[0])
    for name, deps in rows:
        lines.append(f"{name}: {' '.join(deps)}".rstrip())
        n_modules += 1
        n_deps += len(deps)
    if lines:
        header = (
            "# Hamnix auto-generated module dependency table.\n"
            "# Source: kernel-modules/<name>/<name>.ko + "
            "`modinfo -F depends`.\n"
            f"# {n_modules} modules / {n_deps} dependency edges.\n"
        )
    else:
        header = ("# Hamnix auto-generated module dependency table.\n"
                  "# (No kernel-modules/<name>/*.ko present.)\n")
    return header + "\n".join(lines) + ("\n" if lines else "")


def main() -> int:
    here = Path(__file__).resolve().parent.parent
    modules_root = here / "kernel-modules"
    out_arg = sys.argv[1] if len(sys.argv) >= 2 else "build/modules.dep"
    out_path = Path(out_arg)
    if not out_path.is_absolute():
        out_path = here / out_path
    out_path.parent.mkdir(parents=True, exist_ok=True)
    text = build_dep_table(modules_root)
    out_path.write_text(text)
    print(f"  wrote {out_path} ({len(text)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
