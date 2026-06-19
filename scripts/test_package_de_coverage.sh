#!/usr/bin/env bash
# scripts/test_package_de_coverage.sh — no-VM package-coverage gate.
#
# Catches the silent-drift class permanently. The package table in
# scripts/build_packages.py is hand-curated, while the live rootfs
# (build_rootfs_img.py) globs build/user/*.elf wholesale. When the two
# drift, `hpm install hamnix-base` yields a system MISSING binaries the
# live image has — most painfully, the entire scene-file Desktop
# Environment (it was in NO package until 2026-06-19).
#
# This test asserts, against a freshly-built build/packages/main/index.json:
#
#   1. The hamnix-base dependency closure transitively includes the DE
#      (hamnix-desktop -> apps + config) AND hamUId / rc.5 / hamuid.svc
#      resolve to a file inside some package IN that closure.
#   2. Every /bin/ham* referenced by etc/rc.d/rc.5 and
#      etc/services.d/*.svc resolves to a file in a built package.
#   3. build/user/*.elf MINUS an allowlist of intentional skips
#      (demos/selftests/X11 test harnesses) is fully covered by the
#      union of all built packages' files.
#
# No QEMU, no kernel build. Pure build-system invariant.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

echo "[de-cov] (1/3) build userland (build/user/*.elf)"
bash scripts/build_user.sh >/dev/null

echo "[de-cov] (2/3) build packages (SLIM bootloader + debian)"
HAMNIX_BOOTLOADER_SLIM=1 HAMNIX_LINUX_DEBIAN_SLIM=1 \
    python3 scripts/build_packages.py >/dev/null

echo "[de-cov] (3/3) assert coverage invariants"
python3 - <<'PY'
import json, sys, tarfile, re
from pathlib import Path

ROOT = Path(".").resolve()
IDX = ROOT / "build" / "packages" / "main" / "index.json"
USER = ROOT / "build" / "user"
ETC = ROOT / "etc"
PKGDIR = ROOT / "build" / "packages" / "main"

# Intentional non-packaged binaries: pure demos, compiler self-tests,
# X11/scene test harnesses, the in-tree Adder compiler drivers. These
# are dev/test artifacts, not shipped userland. Keep this list tight —
# anything real that lands here is a coverage hole, not an exemption.
SKIP_BINS = {
    # compiler drivers + selftests
    "adder_cc", "codegen_ac_driver", "codegen_bss_selftest",
    "codegen_elf_selftest", "codegen_selftest", "lex_selftest",
    "parse_selftest",
    # generic demos / fixtures
    "hello", "dup_demo", "stdin_demo", "p9srv_demo", "preempt_demo",
    "preempt_hog", "nice_demo", "nice_hi", "nice_lo", "u_tlstest",
    "test_errstr_perbackend", "test_hugepage", "live_distro_up",
    # X11 bridge + scene test harnesses (not the shipped DE)
    "x11apptest", "x11srv", "x11test", "xclient_demo", "xfill",
    "scenetest", "multiwintest", "hamui_demo", "ham2048", "hamsnake",
    # Legacy PRE-scene-pivot DE widgets (hamui-toolkit era). The DE was
    # rearchitected onto scene FILES (docs/de_scene_file_arch.md); the
    # *scene variants (hampanelscene/hamfmscene/...) in
    # hamnix-desktop-apps superseded these and NOTHING in the autostart
    # (rc.5 / services.d / desktop.icons / panel.conf) references them.
    # Not shipped; pending source removal. If any of these gets wired
    # back into the autostart, drop it from this list and package it.
    "hamUI", "hambottom", "hampanel", "hamcycler", "hamrun", "hamsnap",
    "hamcalpop", "hamnotif", "hamsysmon", "hamecho", "hamfiles",
}

fail = []

idx = json.loads(IDX.read_text())
pkgs = {p["name"]: p for p in idx["packages"]}

def dep_names(p):
    out = []
    for d in p.get("depends", []):
        out.append(re.split(r"[<>=]", d, 1)[0].strip())
    return out

# --- closure from hamnix-base ---
seen = set()
stack = ["hamnix-base"]
while stack:
    n = stack.pop()
    if n in seen or n not in pkgs:
        continue
    seen.add(n)
    stack += dep_names(pkgs[n])

for want in ("hamnix-desktop", "hamnix-desktop-apps",
             "hamnix-desktop-config", "hamnix-hamsh"):
    if want not in seen:
        fail.append(f"hamnix-base closure MISSING {want}")

# --- map package -> set of installed file basenames + full rel paths ---
def pkg_files(name):
    p = pkgs.get(name)
    if not p:
        return [], []
    tar = PKGDIR / p["url"]
    rels, bases = [], []
    with tarfile.open(tar) as t:
        for m in t.getmembers():
            if not m.isfile():
                continue
            # arc: <pkg>-<v>/files/<rel>
            parts = m.name.split("/files/", 1)
            if len(parts) != 2:
                continue
            rel = parts[1]
            rels.append(rel)
            bases.append(Path(rel).name)
    return rels, bases

# union over ALL built packages (coverage of the live elf set is about
# "is it in ANY package", not just the base closure).
all_bins = set()
all_rels_in_closure = set()
bases_in_closure = set()
for name, p in pkgs.items():
    rels, bases = pkg_files(name)
    for b in bases:
        all_bins.add(b)
    if name in seen:
        for r in rels:
            all_rels_in_closure.add(r)
        for b in bases:
            bases_in_closure.add(b)

# --- 1b: the DE keystones resolve to a file in the base closure ---
for keyfile in ("bin/hamUId", "etc/rc.d/rc.5", "etc/services.d/hamuid.svc"):
    if keyfile not in all_rels_in_closure:
        fail.append(f"hamnix-base closure has no file {keyfile}")

# --- 2: every /bin/ham* referenced by rc.5 + svc resolves ---
ref_files = [ETC / "rc.d" / "rc.5"] + sorted((ETC / "services.d").glob("*.svc"))
referenced = set()
for f in ref_files:
    if not f.is_file():
        continue
    for m in re.findall(r"/bin/(ham[A-Za-z0-9_]+)", f.read_text()):
        referenced.add(m)
for r in sorted(referenced):
    if r not in bases_in_closure:
        fail.append(f"rc.5/svc references /bin/{r} but it is not in the "
                    f"hamnix-base closure")

# --- 3: every build/user/*.elf (minus allowlist) is in SOME package ---
built = {p.stem for p in USER.glob("*.elf")}
uncovered = sorted(b for b in built
                   if b not in SKIP_BINS and b not in all_bins)
if uncovered:
    fail.append(f"{len(uncovered)} built binaries packaged by NO package: "
                + ", ".join(uncovered))

if fail:
    print("[de-cov] FAIL:")
    for f in fail:
        print("   - " + f)
    sys.exit(1)

print(f"[de-cov] OK: base closure={len(seen)} pkgs; "
      f"rc.5/svc refs={len(referenced)} resolved; "
      f"{len(built)} built bins, {len(SKIP_BINS & built)} allowlisted, "
      "0 uncovered.")
PY

echo "[de-cov] PASS"
