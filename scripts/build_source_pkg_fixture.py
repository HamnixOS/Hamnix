#!/usr/bin/env python3
"""scripts/build_source_pkg_fixture.py — build a native SOURCE-package repo.

Packages the example source package under
packages/main/source/hello-src-1.0/ into a .tar.gz + a `main`-channel
index.json under <out-dir>, ready to plant as an hpm file:// repo. The
package ships its Adder SOURCE (src/greet.ad) + a `recipe` and NO
prebuilt binary, so `hpm install hello-src` MUST compile it on-box via
the self-hosted Adder compiler (/bin/adder_cc).

Run with python3 (per repo convention), NOT bash:

    python3 scripts/build_source_pkg_fixture.py <out-dir>

Mirrors the tarball layout + index.json schema that scripts/test_hpm.sh
and scripts/build_packages.py emit (top-level <name>-<version>/ dir,
PKGINFO at the root, recipe + src/ alongside it, files/ for prebuilt
artifacts — omitted here so the install path goes through compilation).
"""
import hashlib
import sys
import tarfile
from pathlib import Path

PROJ_ROOT = Path(__file__).resolve().parent.parent
# The example source package lives in-tree (NOT in the `packages`
# git submodule, which isn't initialised in every worktree) so the
# test is self-contained and reads the same .ad source a real native
# repo would ship.
PKG_SRC = PROJ_ROOT / "examples" / "hpm-source" / "hello-src-1.0"
PKG_NAME = "hello-src"
PKG_VER = "1.0"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: build_source_pkg_fixture.py <out-dir>", file=sys.stderr)
        return 2
    out_dir = Path(sys.argv[1])
    if not PKG_SRC.is_dir():
        print(f"error: package source {PKG_SRC} not found", file=sys.stderr)
        return 1

    chan = out_dir / "main"
    pkgs = chan / "packages"
    pkgs.mkdir(parents=True, exist_ok=True)

    tar_name = f"{PKG_NAME}-{PKG_VER}.tar.gz"
    tar_path = pkgs / tar_name

    # Deterministic gzipped tar. The top-level dir entry is
    # "<name>-<version>/" (what hpm's tar walker strips). Every tracked
    # file under packages/main/source/hello-src-1.0/ is added under that
    # prefix. NOTE: there is NO files/ binary — only PKGINFO, recipe, and
    # src/greet.ad — so the install path is forced through on-box compile.
    members = sorted(p for p in PKG_SRC.rglob("*") if p.is_file())
    with tarfile.open(tar_path, mode="w:gz", format=tarfile.GNU_FORMAT,
                      compresslevel=9) as tar:
        # Top-level directory entry.
        ti = tarfile.TarInfo(name=f"{PKG_NAME}-{PKG_VER}")
        ti.type = tarfile.DIRTYPE
        ti.mode = 0o755
        ti.mtime = 0
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        tar.addfile(ti)
        for m in members:
            rel = m.relative_to(PKG_SRC).as_posix()
            arcname = f"{PKG_NAME}-{PKG_VER}/{rel}"
            info = tar.gettarinfo(name=str(m), arcname=arcname)
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mode = 0o644
            with m.open("rb") as fh:
                tar.addfile(info, fh)

    data = tar_path.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    size = len(data)

    index = f"""{{
  "schema": 1,
  "repo": "test/hpm-source",
  "channel": "main",
  "url": "file:///test-hpm-repo/main/",
  "updated": "2026-06-01",
  "description": "hpm #186 source-package fixture (main channel)",
  "packages": [
    {{
      "name": "{PKG_NAME}",
      "version": "{PKG_VER}",
      "arch": "any",
      "channel": "main",
      "url": "packages/{tar_name}",
      "sha256": "{sha}",
      "size": {size},
      "description": "native source package compiled on-box at install",
      "depends": [],
      "target": "#hamnix-system"
    }}
  ]
}}
"""
    (chan / "index.json").write_text(index, encoding="utf-8")
    print(f"[build_source_pkg_fixture] wrote {tar_path} ({size} bytes, "
          f"sha256={sha[:16]}...)")
    print(f"[build_source_pkg_fixture] wrote {chan / 'index.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
