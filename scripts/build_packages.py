#!/usr/bin/env python3
"""
scripts/build_packages.py — build the v1 Hamnix package tarballs.

The Debian-installer-shape pivot: each install step is a `hpm install
<pkg>`. To make that scale beyond the monolithic v1 set, this script
emits one package PER command-line app plus a handful of
component/driver packages, and two metapackages (`hamnix-coreutils`
and `hamnix-base`) that pull groups of them in via `depends:`. A
future install can pick a subset (e.g. `{ hamnix-init, hamnix-hamsh,
hpm, hamnix-cat, hamnix-ls, hamnix-drivers-net-e1000e, hamnix-fs-ext4
}` for an embedded build) and skip everything else.

Per-command split (2026-05-28): each `user/<cmd>.ad` ships as its own
`hamnix-<cmd>` package (one binary, minimal `depends:`). Underscored
command stems map to hyphenated package names (the PKGINFO `name`
grammar is `[a-z][a-z0-9-]*` — NO underscores), while the installed
BINARY keeps its underscored filename. E.g. `env_show` →
package `hamnix-env-show`, binary `bin/env_show`. `hamnix-coreutils`
is now a METAPACKAGE depending on every `hamnix-<cmd>`, so anything
that pulled `hamnix-coreutils` still gets the whole command set.

Channel layout (2026-05-27 pivot, per memory/project_nonfree_repo.md):
top-level directories under build/packages/ are *channels* mirroring
Debian's main / contrib / non-free / non-free-firmware split. Today
this script writes every package into `main/` (free + first-party
software). Placeholder `non-free/` and `non-free-firmware/` channels
exist as empty channels with a `{schema:1, packages:[]}` index so a
fresh `hpm refresh` against an enabled channel returns cleanly
instead of 404. The contrib channel is reserved (not auto-created).

Outputs (under build/packages/):

  * main/index.json                    — main-channel index. Each
                                          entry carries `channel: "main"`.
  * main/packages/hamnix-base-<v>.tar.gz   — metapackage (zero files,
                                          depends on all component pkgs).
                                          target: #hamnix-system
  * hamnix-init-<v>.tar.gz             — /init + /etc/rc.boot etc.
  * hamnix-hamsh-<v>.tar.gz            — /bin/hamsh + /etc/profile etc.
  * hamnix-<cmd>-<v>.tar.gz            — one package PER command
                                          (~83: cat, ls, echo, ps, ...)
  * hamnix-coreutils-<v>.tar.gz        — METAPACKAGE depending on every
                                          hamnix-<cmd> (preserves the
                                          old "install all utils" path)
  * hamnix-net-<v>.tar.gz              — ifconfig, ping, route, httpd
  * hamnix-svc-sshd-<v>.tar.gz         — sshd + /etc/svc/sshd.hamsh
  * hpm-<v>.tar.gz                     — /bin/hpm + var dirs
  * hamnix-fs-ext4-<v>.tar.gz          — mkfs_ext4 + install_file_to_slot
  * hamnix-fs-fat-<v>.tar.gz           — mkfs_fat
  * hamnix-drivers-net-e1000e-<v>.tar.gz — e1000e.ko
  * hamnix-drivers-block-ahci-<v>.tar.gz — ahci + libata + scsi_mod + ...
  * hamnix-drivers-block-nvme-<v>.tar.gz — nvme + nvme_core
  * hamnix-drivers-usb-xhci-<v>.tar.gz   — xhci_pci + xhci_hcd + usbcore
  * hamnix-drivers-snd-hda-<v>.tar.gz    — snd_hda_intel + ALSA stack
  * hamnix-installer-tools-<v>.tar.gz  — hamnix_partition + dd_blk
  * hamnix-bootloader-<v>.tar.gz       — BOOTX64.EFI + kernel ELF
  * linux-debian-12-<v>.tar.gz         — Debian 12 rootfs
  * index.json                         — repo index (docs/packages.md)

Cleavage principle: every reusable subsystem is its own package so a
shrink-wrapped install can pick exactly what it needs. A NUC with only
USB+NVMe doesn't need ahci/snd-hda; an embedded headless build doesn't
need linux-debian-12; a kiosk box might want only hamnix-{kernel,init,
hamsh}.

After this script runs the ISO builder stages build/packages/main/ at
/iso-packages/ on the cpio (build_initramfs.py) and the installer
runs

    hpm --repo=file:///iso-packages --target-prefix=/tmp/newroot \\
        install hamnix-base

The ISO mini-repo only carries the `main` channel — the installer
default subscribes to `main` only, and an ISO-time install never
needs non-free firmware (that's an opt-in `hpm enable
non-free-firmware` post-install).

which (per docs/packages.md and the hpm v3 dep solver) pulls the
entire closure transitively. Alternatively install.hamsh can name
individual components for a slimmer build.

DESIGN — file→package mapping. The mapping lives in this file under
PACKAGE_SPECS (a list of dicts). Each entry declares:
  * name, version, arch, description, target
  * depends/conflicts/provides (PKGINFO + index.json fields)
  * a `files` list of (src_path, target_path) tuples that the staging
    helper copies into <pkg>-<v>/files/<target_path>
  * an optional `extra_files` callable for packages with non-trivial
    layout (linux-debian-12's usrmerge; hamnix-bootloader's SLIM mode)

A future package = one new dict added to PACKAGE_SPECS. The
file-mapping is the source of truth; gen_install_manifest.py can be
extended later to read this same table if the brief's option-1 (per-
package manifest fragments) becomes preferable.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
BUILD = HERE / "build"
USER_DIR = BUILD / "user"
MOD_DIR = BUILD / "mod"
# Output channel tree. Defaults to build/packages/ (a throwaway build
# artifact) but is overridable via HAMNIX_PACKAGES_OUT so the canonical
# package tree can be regenerated directly into the HamnixOS/packages
# submodule (the source of truth served at 255.one, and the tree the
# ISO build embeds as its installer mirror). main() only unlinks stale
# *.tar.gz / index.json — it never rm -rf's this dir, so a submodule's
# .git is safe.
PACKAGES_OUT = Path(os.environ.get("HAMNIX_PACKAGES_OUT", str(BUILD / "packages")))
ETC_DIR = HERE / "etc"
MAN_DIR = ETC_DIR / "man"
KMODS_DIR = HERE / "kernel-modules"
KERNEL_ELF = BUILD / "hamnix-kernel.elf"
EFI_STUB = BUILD / "hamnix-bootx64.efi"
DEBIAN_MINBASE = HERE / "tests" / "distros" / "debian-minbase" / "rootfs"

# v1: every package shares one atomic release version. You don't ship
# a bootloader newer than the base it boots into.
PKG_VERSION = os.environ.get("HAMNIX_PKG_VERSION", "1.0.0")


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

def _say(msg: str) -> None:
    print(f"[build_packages] {msg}", flush=True)


def _stage_dir(staging: Path) -> Path:
    """Create a clean staging dir and return its path."""
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    return staging


def _copy_file(src: Path, dst: Path, mode: int | None = None) -> int:
    """Copy `src` to `dst` (creating parents). Returns size in bytes."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    data = src.read_bytes()
    dst.write_bytes(data)
    if mode is not None:
        dst.chmod(mode)
    else:
        if src.stat().st_mode & 0o111:
            dst.chmod(0o755)
        else:
            dst.chmod(0o644)
    return len(data)


def _write_pkginfo(pkg_root: Path, fields: dict[str, str]) -> None:
    """Emit a PKGINFO file at <pkg_root>/PKGINFO."""
    lines = []
    for key, val in fields.items():
        lines.append(f"{key}: {val}")
    pkg_root.joinpath("PKGINFO").write_text("\n".join(lines) + "\n",
                                            encoding="utf-8")


def _tar_gz(pkg_root: Path, out_path: Path) -> tuple[str, int]:
    """Make a deterministic gzipped tar of pkg_root.

    Returns (sha256_hex, size_bytes).
    """
    if out_path.exists():
        out_path.unlink()
    pkg_dirname = pkg_root.name
    entries: list[Path] = sorted(pkg_root.rglob("*"))
    with tarfile.open(out_path, mode="w:gz", format=tarfile.GNU_FORMAT,
                      compresslevel=9) as tar:
        ti = tarfile.TarInfo(name=pkg_dirname)
        ti.type = tarfile.DIRTYPE
        ti.mode = 0o755
        ti.mtime = 0
        ti.uid = 0
        ti.gid = 0
        ti.uname = "root"
        ti.gname = "root"
        tar.addfile(ti)
        for p in entries:
            rel = p.relative_to(pkg_root)
            arcname = f"{pkg_dirname}/{rel.as_posix()}"
            ti = tar.gettarinfo(name=str(p), arcname=arcname)
            if ti is None:
                continue
            ti.mtime = 0
            ti.uid = 0
            ti.gid = 0
            ti.uname = "root"
            ti.gname = "root"
            if ti.isdir():
                ti.mode = 0o755
                tar.addfile(ti)
            elif ti.isreg():
                ti.mode = 0o755 if (p.stat().st_mode & 0o111) else 0o644
                with p.open("rb") as f:
                    tar.addfile(ti, f)
            elif ti.issym():
                tar.addfile(ti)
            else:
                tar.addfile(ti)
    data = out_path.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    return sha, len(data)


# ---------------------------------------------------------------------
# File mappings — per-package
# ---------------------------------------------------------------------
# Each spec resolves to a `files/` layout. Sources are project-relative;
# missing sources are reported via _say and skipped (the package still
# emits — useful for slim/CI builds where e.g. busybox isn't compiled).

def _add_user_bin(file_map: list[tuple[Path, str]], stem: str,
                  target_subpath: str = "bin") -> None:
    """Add build/user/<stem>.elf at files/<target_subpath>/<stem>."""
    src = USER_DIR / f"{stem}.elf"
    rel = f"{target_subpath}/{stem}"
    file_map.append((src, rel))


def _add_etc_file(file_map: list[tuple[Path, str]], name: str,
                  subdir: str = "") -> None:
    """Add etc/<subdir>/<name> at files/etc/<subdir>/<name>."""
    if subdir:
        src = ETC_DIR / subdir / name
        rel = f"etc/{subdir}/{name}"
    else:
        src = ETC_DIR / name
        rel = f"etc/{name}"
    file_map.append((src, rel))


def _add_ko(file_map: list[tuple[Path, str]], modname: str,
            ko_basename: str | None = None) -> None:
    """Add kernel-modules/<modname>/<modname>.ko at files/lib/modules/.

    Some modules ship under a different ko basename (nvme_core →
    nvme-core.ko). Pass ko_basename to override.
    """
    if ko_basename is None:
        ko_basename = modname
    src = KMODS_DIR / modname / f"{ko_basename}.ko"
    rel = f"lib/modules/{ko_basename}.ko"
    file_map.append((src, rel))


# ---- hamnix-init ----------------------------------------------------
# /init shim + the rc.boot + inittab + etc identity files. Without
# this package there's no PID 1, no boot rc — nothing comes up.

def _files_init() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    # /init shim (special: not under /bin).
    f.append((USER_DIR / "init.elf", "init"))
    # etc boot config + identity.
    for name in ("rc.boot", "inittab", "fstab", "hostname",
                 "host.conf", "hosts", "issue", "issue.net",
                 "login.defs", "lsb-release", "networks",
                 "os-release", "passwd", "group", "shadow",
                 "shells", "profile", "protocols",
                 "resolv.conf", "services", "timezone", "users",
                 "debian_version"):
        _add_etc_file(f, name)
    # /etc/hpm/channels — channel-subscription file. Default contents
    # subscribe to `main` only (the free / first-party channel).
    # `hpm enable non-free-firmware` appends entries post-install.
    _add_etc_file(f, "channels", subdir="hpm")
    return f


# ---- hamnix-hamsh ---------------------------------------------------
# The shell. Pulls in /bin/hamsh + the issue/motd assets that hamsh
# prints on session entry. /etc/profile is in hamnix-init (read by
# every shell at startup, not just hamsh).

def _files_hamsh() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hamsh")
    _add_etc_file(f, "motd")
    # banner is a userland binary (user/banner.ad) — its assets are
    # baked in. The motd file in /etc is the actual greeting.
    _add_user_bin(f, "banner")
    return f


# ---- per-command packages (was: hamnix-coreutils) ------------------
# Every small command the shell expects ships as its OWN package
# (`hamnix-<cmd>`), generated programmatically from COREUTILS_BINS
# below. `hamnix-coreutils` is now a METAPACKAGE that depends on every
# one of them, so anything that pulled `hamnix-coreutils` still gets
# the whole set. Each leaf depends only on the init runtime
# (`hamnix-init`) — a standalone binary needs the ELF loader + PID-1
# runtime, not the shell.

COREUTILS_BINS = (
    "ascii", "awk", "base64", "basename", "cal", "cat", "clear", "cmp",
    "cp", "crond", "crontab", "cut", "date", "df", "diff", "dirname",
    "distrofs", "dmesg",
    "du", "echo", "ed", "env_show", "expr", "false", "find", "free",
    "getty", "grep", "halt", "hamwd", "head", "hostname", "id",
    "insmod", "kill", "less", "ln", "login", "ls", "lsblk", "lsmod",
    "md5sum",
    "mkdir", "more", "motd", "mv", "nsbindprobe", "nsrun", "od",
    "p9srv_demo", "passwd", "pgrep", "poweroff", "preempt_demo",
    "preempt_hog", "printf", "ps", "pwd", "reboot", "rev", "rm",
    "rmmod", "sed", "seq", "sleep", "sort", "strings", "su", "tail",
    "tee", "test", "top", "touch", "tr", "true", "uname", "uptime",
    "u_server", "u_tlstest", "vi", "watch", "wc", "whatis", "which",
    "whoami", "xargs", "yes",
)


def _cmd_pkg_name(stem: str) -> str:
    """Map a command stem to its package name.

    PKGINFO `name` grammar is `[a-z][a-z0-9-]*` (lowercase, hyphens OK,
    NO underscores), so underscored stems get their underscores
    rewritten to hyphens. The installed binary keeps the underscored
    stem; only the PACKAGE name is hyphenated.

        cat       -> hamnix-cat
        env_show  -> hamnix-env-show
        u_server  -> hamnix-u-server
    """
    return "hamnix-" + stem.replace("_", "-")


def _man_one_liner(stem: str) -> str | None:
    """Pull a one-line description from etc/man/<stem>.1.md if present.

    Man pages are markdown. The H1 title line is `# <cmd> - <summary>`
    and the NAME section repeats `<cmd> - <summary>`. Prefer the NAME
    section (canonical whatis source); fall back to the H1. Returns the
    `<summary>` portion, or None if no man page / no parseable line.
    """
    man = MAN_DIR / f"{stem}.1.md"
    if not man.is_file():
        return None
    try:
        lines = man.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None

    def _summary(line: str) -> str | None:
        # Accept `cmd - summary` or `cmd — summary`.
        for sep in (" - ", " — "):
            if sep in line:
                return line.split(sep, 1)[1].strip()
        return None

    # NAME section: the first non-blank line after a `## NAME` header.
    for i, raw in enumerate(lines):
        if raw.strip().lower() == "## name":
            for follow in lines[i + 1:]:
                if follow.strip():
                    s = _summary(follow.strip())
                    if s:
                        return s
                    break
            break
    # Fall back to the H1 title (`# cmd - summary`).
    for raw in lines:
        stripped = raw.strip()
        if stripped.startswith("# "):
            return _summary(stripped[2:].strip())
    return None


def _cmd_description(stem: str) -> str:
    """One-line package description for command `stem`.

    Pulls the real summary from etc/man/<stem>.1.md when available;
    otherwise a sensible default. Don't over-invest — the default is
    fine for the long tail of demo/utility commands.
    """
    man = _man_one_liner(stem)
    if man:
        return f"Hamnix {stem} — {man}"
    return f"Hamnix {stem} command"


def _make_cmd_files_fn(stem: str):
    """Return a files_fn that stages just `build/user/<stem>.elf`."""
    def _files() -> list[tuple[Path, str]]:
        f: list[tuple[Path, str]] = []
        _add_user_bin(f, stem)
        return f
    return _files


def _cmd_specs() -> list[dict]:
    """Generate one PACKAGE_SPEC per command in COREUTILS_BINS."""
    specs: list[dict] = []
    for stem in COREUTILS_BINS:
        specs.append({
            "name": _cmd_pkg_name(stem),
            "files_fn": _make_cmd_files_fn(stem),
            "depends": ["hamnix-init>=1"],
            "description": _cmd_description(stem),
            "target": "#hamnix-system",
        })
    return specs


# ---- hamnix-net -----------------------------------------------------
# Network userland: ifconfig (boot-rc dump), ping, route, httpd. The
# kernel does the actual IP stack; these are the operator-facing tools.

def _files_net() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "ifconfig")
    _add_user_bin(f, "ping")
    _add_user_bin(f, "route")
    _add_user_bin(f, "httpd")
    return f


# ---- hamnix-svc-sshd ------------------------------------------------
# In-tree SSH server. Decoupled from the base because a headless
# embedded board can opt out of remote login.

def _files_svc_sshd() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "sshd")
    _add_etc_file(f, "sshd.hamsh", subdir="svc")
    return f


# ---- hpm ------------------------------------------------------------
# The package manager itself. Split out because a locked-down embedded
# system might ship a frozen image without runtime package mgmt.

def _files_hpm() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hpm")
    return f


# ---- hamnix-fs-ext4 -------------------------------------------------
# Ext4 toolchain: format + per-file install. install_rootfs_from_manifest
# also lives here because it drives the kernel-side install_file ctl.

def _files_fs_ext4() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "mkfs_ext4")
    _add_user_bin(f, "install_file_to_slot")
    _add_user_bin(f, "install_rootfs_from_manifest")
    return f


# ---- hamnix-fs-fat --------------------------------------------------

def _files_fs_fat() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "mkfs_fat")
    return f


# ---- hamnix-drivers-net-e1000e --------------------------------------
# Intel e1000e family (I219 PHY/MAC on most NUCs and laptops).

def _files_drv_e1000e() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_ko(f, "e1000e")
    return f


# ---- hamnix-drivers-block-ahci --------------------------------------
# AHCI SATA stack. libata + libahci are framework deps; scsi_mod +
# scsi_common are the SCSI mid/lower layer the ATA-on-SCSI translator
# pulls in.

def _files_drv_ahci() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_ko(f, "ahci")
    _add_ko(f, "libahci")
    _add_ko(f, "libata")
    _add_ko(f, "scsi_mod")
    _add_ko(f, "scsi_common")
    return f


# ---- hamnix-drivers-block-nvme --------------------------------------

def _files_drv_nvme() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_ko(f, "nvme")
    _add_ko(f, "nvme_core", ko_basename="nvme-core")
    return f


# ---- hamnix-drivers-usb-xhci ----------------------------------------

def _files_drv_xhci() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_ko(f, "xhci_pci")
    _add_ko(f, "xhci_hcd")
    _add_ko(f, "usbcore")
    return f


# ---- hamnix-drivers-snd-hda -----------------------------------------

def _files_drv_snd_hda() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_ko(f, "snd_hda_intel")
    _add_ko(f, "snd_hda_codec")
    _add_ko(f, "snd_hda_core")
    _add_ko(f, "snd_pcm")
    _add_ko(f, "snd")
    return f


# ---- hamnix-installer-tools ----------------------------------------
# Just the partitioner + dd_blk. mkfs_* moved to hamnix-fs-*; hpm is
# its own package; hpm's solver pulls them in via the metapackage.

def _files_installer_tools() -> list[tuple[Path, str]]:
    f: list[tuple[Path, str]] = []
    _add_user_bin(f, "hamnix_partition")
    _add_user_bin(f, "dd_blk")
    return f


# ---------------------------------------------------------------------
# Package spec table — the source of truth.
# ---------------------------------------------------------------------
#
# Each entry: {name, files_fn, depends, conflicts, provides, target,
# description}. files_fn returns the (src, target_rel) tuples.
# Packages with non-trivial layout (bootloader SLIM mode, linux-debian
# usrmerge) are handled by build_*() specials further below.

PACKAGE_SPECS: list[dict] = [
    {
        "name": "hamnix-init",
        "files_fn": _files_init,
        "depends": [],
        "description": "Hamnix init (PID 1 shim + /etc/rc.boot + identity)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-hamsh",
        "files_fn": _files_hamsh,
        "depends": ["hamnix-init>=1"],
        "description": "Hamnix shell — /bin/hamsh + motd/banner",
        "target": "#hamnix-system",
    },
    # hamnix-coreutils is now a METAPACKAGE: zero files, depends on
    # every per-command hamnix-<cmd> package. The per-command leaf
    # specs are spliced in below via _cmd_specs() (after this literal
    # list is defined), and this entry's depends is populated to name
    # all of them. Anything that pulled `hamnix-coreutils` before the
    # split still gets the full command set transitively.
    {
        "name": "hamnix-coreutils",
        "files_fn": lambda: [],
        # depends filled in below from COREUTILS_BINS.
        "depends": ["hamnix-hamsh>=1"]
                   + [f"{_cmd_pkg_name(s)}>={PKG_VERSION}"
                      for s in COREUTILS_BINS],
        "description": ("Hamnix core userland metapackage — pulls in "
                        "every per-command package (cat/ls/echo/ps/...)"),
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-net",
        "files_fn": _files_net,
        "depends": ["hamnix-hamsh>=1"],
        "description": "Hamnix networking userland — ifconfig, ping, route, httpd",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-svc-sshd",
        "files_fn": _files_svc_sshd,
        "depends": ["hamnix-net>=1"],
        "description": "Hamnix in-tree SSH-2 server (sshd + svc definition)",
        "target": "#hamnix-system",
    },
    {
        "name": "hpm",
        "files_fn": _files_hpm,
        "depends": ["hamnix-net>=1"],
        "description": "Hamnix package manager (hpm)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-fs-ext4",
        "files_fn": _files_fs_ext4,
        "depends": ["hamnix-hamsh>=1"],
        "description": "Hamnix ext4 toolchain — mkfs_ext4 + install_file_to_slot",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-fs-fat",
        "files_fn": _files_fs_fat,
        "depends": ["hamnix-hamsh>=1"],
        "description": "Hamnix FAT toolchain — mkfs_fat",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-drivers-net-e1000e",
        "files_fn": _files_drv_e1000e,
        "depends": ["hamnix-init>=1"],
        "description": "Intel e1000e Ethernet driver (.ko)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-drivers-block-ahci",
        "files_fn": _files_drv_ahci,
        "depends": ["hamnix-init>=1"],
        "description": "AHCI SATA block stack (ahci + libata + scsi_mod + ...)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-drivers-block-nvme",
        "files_fn": _files_drv_nvme,
        "depends": ["hamnix-init>=1"],
        "description": "NVMe block driver (nvme + nvme-core)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-drivers-usb-xhci",
        "files_fn": _files_drv_xhci,
        "depends": ["hamnix-init>=1"],
        "description": "USB xHCI host controller stack (xhci_pci + xhci_hcd + usbcore)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-drivers-snd-hda",
        "files_fn": _files_drv_snd_hda,
        "depends": ["hamnix-init>=1"],
        "description": "Intel HDA audio stack (snd_hda_intel + ALSA core)",
        "target": "#hamnix-system",
    },
    {
        "name": "hamnix-installer-tools",
        "files_fn": _files_installer_tools,
        "depends": ["hamnix-fs-ext4>=1", "hamnix-fs-fat>=1"],
        "description": "Hamnix installer tools — partitioner + dd_blk",
        "target": "#hamnix-system",
    },
]

# Splice in one leaf package per command. Generated programmatically
# from COREUTILS_BINS so the table stays maintainable (no hand-written
# 80-odd dict literals). Each leaf is `hamnix-<cmd>` (underscores→
# hyphens), stages just that one binary, and depends only on the init
# runtime. The hamnix-coreutils metapackage above already names them
# all in its depends.
PACKAGE_SPECS.extend(_cmd_specs())


# ---------------------------------------------------------------------
# Generic spec-driven package builder
# ---------------------------------------------------------------------

def _build_spec(spec: dict) -> dict | None:
    """Build the tarball for a PACKAGE_SPECS entry.

    Returns the index.json entry dict, or None if the package was
    skipped (no files staged AND it's not a metapackage).
    """
    pkg_name = spec["name"]
    pkg_dirname = f"{pkg_name}-{PKG_VERSION}"
    staging = _stage_dir(PACKAGES_OUT / "_stage" / pkg_dirname)
    files_root = staging / "files"
    files_root.mkdir()

    total_bytes = 0
    n_files = 0
    skipped: list[str] = []

    file_map = spec["files_fn"]()
    for src, rel in file_map:
        if not src.is_file():
            skipped.append(str(src.relative_to(HERE)) if src.is_relative_to(HERE) else str(src))
            continue
        total_bytes += _copy_file(src, files_root / rel)
        n_files += 1

    if skipped:
        _say(f"{pkg_name}: skipped {len(skipped)} missing source(s) "
             f"(first 3: {', '.join(skipped[:3])}"
             f"{'…' if len(skipped) > 3 else ''})")

    target = spec.get("target", "#hamnix-system")
    description = spec["description"]

    # PKGINFO assembly.
    pkginfo: dict[str, str] = {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "description": description,
        "target": target,
        "maintainer": "HamnixOS",
        "license": "ISC",
        "homepage": "https://255.one/",
    }
    if spec.get("depends"):
        # PKGINFO depends: comma-separated string per docs/packages.md.
        pkginfo["depends"] = ", ".join(spec["depends"])
    if spec.get("conflicts"):
        pkginfo["conflicts"] = ", ".join(spec["conflicts"])
    if spec.get("provides"):
        pkginfo["provides"] = ", ".join(spec["provides"])

    _write_pkginfo(staging, pkginfo)

    out_tar = PACKAGES_OUT / "main" / "packages" / f"{pkg_dirname}.tar.gz"
    sha, size = _tar_gz(staging, out_tar)
    _say(f"built {out_tar.name}: {n_files} files, "
         f"{total_bytes} src bytes, {size} tar bytes, sha={sha[:16]}…")

    entry: dict = {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "channel": "main",
        "url": f"packages/{pkg_dirname}.tar.gz",
        "sha256": sha,
        "size": size,
        "description": description,
        "depends": list(spec.get("depends", [])),
        "target": target,
    }
    if spec.get("conflicts"):
        entry["conflicts"] = list(spec["conflicts"])
    if spec.get("provides"):
        entry["provides"] = list(spec["provides"])
    return entry


# ---------------------------------------------------------------------
# hamnix-base — metapackage. Zero files; depends on every component.
# ---------------------------------------------------------------------

def build_hamnix_base() -> dict:
    pkg_name = "hamnix-base"
    pkg_dirname = f"{pkg_name}-{PKG_VERSION}"
    staging = _stage_dir(PACKAGES_OUT / "_stage" / pkg_dirname)
    files_root = staging / "files"
    files_root.mkdir()

    # Metapackage = `hamnix-base` pulls in every COMPONENT package via
    # depends; hpm's BFS solver pulls the rest transitively. We depend
    # on the hamnix-coreutils metapackage (which fans out to all ~83
    # per-command hamnix-<cmd> leaves) rather than naming every leaf
    # directly — that keeps hamnix-base's depends list to the dozen-ish
    # top-level components and avoids a 100-entry depends string while
    # still resolving the full closure.
    # hamnix-bootloader is also pulled in so a `hpm install hamnix-base`
    # against an ISO mini-repo gets the full OS shape on disk; the
    # installer copies BOOTX64.EFI separately because the ESP isn't a
    # Hamnix-file-server target.
    leaf_names = {_cmd_pkg_name(s) for s in COREUTILS_BINS}
    depends = [f"{s['name']}>={PKG_VERSION}" for s in PACKAGE_SPECS
               if s["name"] not in leaf_names]
    depends.append(f"hamnix-bootloader>={PKG_VERSION}")

    description = ("Hamnix base — metapackage pulling in every "
                   "component (init/hamsh/coreutils/net/sshd/hpm/fs/"
                   "drivers/installer/bootloader)")

    _write_pkginfo(staging, {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "description": description,
        "target": "#hamnix-system",
        "depends": ", ".join(depends),
        "maintainer": "HamnixOS",
        "license": "ISC",
        "homepage": "https://255.one/",
    })

    out_tar = PACKAGES_OUT / "main" / "packages" / f"{pkg_dirname}.tar.gz"
    sha, size = _tar_gz(staging, out_tar)
    _say(f"built {out_tar.name}: METAPACKAGE (0 files, "
         f"{len(depends)} depends), {size} tar bytes, sha={sha[:16]}…")
    return {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "channel": "main",
        "url": f"packages/{pkg_dirname}.tar.gz",
        "sha256": sha,
        "size": size,
        "description": description,
        "depends": depends,
        "target": "#hamnix-system",
    }


# ---------------------------------------------------------------------
# hamnix-bootloader — BOOTX64.EFI + kernel ELF. target=#esp.
# ---------------------------------------------------------------------

def build_hamnix_bootloader() -> dict:
    pkg_name = "hamnix-bootloader"
    pkg_dirname = f"{pkg_name}-{PKG_VERSION}"
    staging = _stage_dir(PACKAGES_OUT / "_stage" / pkg_dirname)
    files_root = staging / "files"
    files_root.mkdir()
    total_bytes = 0
    n_files = 0

    slim_early = os.environ.get("HAMNIX_BOOTLOADER_SLIM") == "1"
    if not slim_early:
        if not KERNEL_ELF.is_file():
            raise SystemExit(
                f"[build_packages] {KERNEL_ELF.relative_to(HERE)} missing — "
                f"run scripts/build_iso.sh first to produce the kernel ELF")
        if not EFI_STUB.is_file():
            raise SystemExit(
                f"[build_packages] {EFI_STUB.relative_to(HERE)} missing — "
                f"run scripts/build_iso.sh first to produce the EFI stub")

    # The ISO mini-repo emits a metadata-only bootloader package (the
    # full BOOTX64.EFI + kernel.elf payload lives in the live ISO's
    # source ESP partition and is copied onto the target ESP via dd_blk
    # by install.hamsh). On the upstream HamnixOS/packages build the
    # full payload IS embedded.
    slim = os.environ.get("HAMNIX_BOOTLOADER_SLIM") == "1"
    if not slim:
        total_bytes += _copy_file(EFI_STUB, files_root / "BOOTX64.EFI",
                                  mode=0o755)
        n_files += 1
        total_bytes += _copy_file(KERNEL_ELF,
                                  files_root / "hamnix-kernel.elf",
                                  mode=0o755)
        n_files += 1
    else:
        _say("hamnix-bootloader: HAMNIX_BOOTLOADER_SLIM=1 — emitting "
             "metadata-only package (no files/)")
        (files_root / "README").write_text(
            "ISO mini-repo slim build. BOOTX64.EFI + kernel.elf live in "
            "the live ISO's source ESP partition and are copied onto "
            "the target ESP by /etc/install.hamsh via dd_blk. The full "
            "payload is published at https://255.one/.\n",
            encoding="ascii")
        n_files += 1

    description = ("Hamnix UEFI bootloader stub + kernel ELF "
                   "(installs onto the ESP)")
    _write_pkginfo(staging, {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "description": description,
        "target": "#esp",
        "depends": "hamnix-init>=1",
        "maintainer": "HamnixOS",
        "license": "ISC",
        "homepage": "https://255.one/",
    })
    out_tar = PACKAGES_OUT / "main" / "packages" / f"{pkg_dirname}.tar.gz"
    sha, size = _tar_gz(staging, out_tar)
    _say(f"built {out_tar.name}: {n_files} files, "
         f"{total_bytes} src bytes, {size} tar bytes, sha={sha[:16]}…")
    return {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "channel": "main",
        "url": f"packages/{pkg_dirname}.tar.gz",
        "sha256": sha,
        "size": size,
        "description": description,
        "depends": ["hamnix-init>=1"],
        "target": "#esp",
    }


# ---------------------------------------------------------------------
# linux-debian-12 — Debian rootfs (unchanged from v1).
# ---------------------------------------------------------------------

LINUX_DEBIAN_FILES = [
    "usr/bin/apt", "usr/bin/apt-get", "usr/bin/apt-cache",
    "usr/bin/apt-config", "usr/bin/apt-mark", "usr/bin/dpkg",
    "usr/bin/dpkg-deb", "usr/bin/dpkg-query", "usr/bin/dpkg-split",
    "usr/lib64/ld-linux-x86-64.so.2",
    "usr/lib/x86_64-linux-gnu/libc.so.6",
    "usr/lib/x86_64-linux-gnu/libm.so.6",
    "usr/lib/x86_64-linux-gnu/libpthread.so.0",
    "usr/lib/x86_64-linux-gnu/libdl.so.2",
    "usr/lib/x86_64-linux-gnu/libresolv.so.2",
    "usr/lib/x86_64-linux-gnu/librt.so.1",
    "usr/lib/x86_64-linux-gnu/libapt-pkg.so.7.0",
    "usr/lib/x86_64-linux-gnu/libapt-pkg.so.7.0.0",
    "usr/lib/x86_64-linux-gnu/libapt-private.so.0.0",
    "usr/lib/x86_64-linux-gnu/libapt-private.so.0.0.0",
    "usr/lib/x86_64-linux-gnu/libstdc++.so.6",
    "usr/lib/x86_64-linux-gnu/libstdc++.so.6.0.33",
    "usr/lib/x86_64-linux-gnu/libgcc_s.so.1",
    "usr/lib/x86_64-linux-gnu/libz.so.1",
    "usr/lib/x86_64-linux-gnu/libz.so.1.3.1",
    "usr/lib/x86_64-linux-gnu/libbz2.so.1.0",
    "usr/lib/x86_64-linux-gnu/libbz2.so.1.0.4",
    "usr/lib/x86_64-linux-gnu/liblzma.so.5",
    "usr/lib/x86_64-linux-gnu/liblzma.so.5.8.1",
    "usr/lib/x86_64-linux-gnu/liblz4.so.1",
    "usr/lib/x86_64-linux-gnu/liblz4.so.1.10.0",
    "usr/lib/x86_64-linux-gnu/libzstd.so.1",
    "usr/lib/x86_64-linux-gnu/libzstd.so.1.5.7",
    "usr/lib/x86_64-linux-gnu/libudev.so.1",
    "usr/lib/x86_64-linux-gnu/libudev.so.1.7.10",
    "usr/lib/x86_64-linux-gnu/libsystemd.so.0",
    "usr/lib/x86_64-linux-gnu/libsystemd.so.0.40.0",
    "usr/lib/x86_64-linux-gnu/libcrypto.so.3",
    "usr/lib/x86_64-linux-gnu/libxxhash.so.0",
    "usr/lib/x86_64-linux-gnu/libxxhash.so.0.8.3",
    "usr/lib/x86_64-linux-gnu/libcap.so.2",
    "usr/lib/x86_64-linux-gnu/libcap.so.2.75",
    "usr/lib/x86_64-linux-gnu/libmd.so.0",
    "usr/lib/x86_64-linux-gnu/libmd.so.0.1.0",
    "usr/lib/x86_64-linux-gnu/libselinux.so.1",
    "usr/lib/x86_64-linux-gnu/libpcre2-8.so.0",
    "usr/lib/x86_64-linux-gnu/libpcre2-8.so.0.14.0",
    "etc/debian_version", "etc/os-release", "etc/passwd", "etc/group",
    "etc/hostname", "etc/apt/sources.list", "etc/apt/apt.conf",
    "var/lib/dpkg/status", "var/lib/dpkg/available",
    "var/lib/dpkg/diversions", "var/lib/dpkg/statoverride",
    "usr/share/keyrings/debian-archive-keyring.gpg",
    "etc/apt/trusted.gpg.d/debian-archive-keyring.gpg",
]

LINUX_DEBIAN_USRMERGE = {
    "usr/bin/":   "bin/",
    "usr/sbin/":  "sbin/",
    "usr/lib/":   "lib/",
    "usr/lib64/": "lib64/",
}


def build_linux_debian_12() -> dict | None:
    pkg_name = "linux-debian-12"
    pkg_dirname = f"{pkg_name}-{PKG_VERSION}"
    staging = _stage_dir(PACKAGES_OUT / "_stage" / pkg_dirname)
    files_root = staging / "files"
    files_root.mkdir()
    total_bytes = 0
    n_files = 0

    slim = os.environ.get("HAMNIX_LINUX_DEBIAN_SLIM") == "1"

    if not DEBIAN_MINBASE.is_dir() and not slim:
        _say(f"WARN: {DEBIAN_MINBASE.relative_to(HERE)} absent — "
             f"linux-debian-12 will be SKIPPED. Run "
             f"tests/distros/debian-minbase/BUILD.sh first.")
        return None

    if slim:
        _say("linux-debian-12: HAMNIX_LINUX_DEBIAN_SLIM=1 — emitting "
             "metadata-only package (no files/)")
        (files_root / "README").write_text(
            "ISO mini-repo slim build of linux-debian-12. The real "
            "Debian closure lives in the live ISO's source rootfs "
            "partition and is copied onto the target rootfs by "
            "/etc/install.hamsh via the manifest installer. The full "
            "payload is at https://255.one/.\n", encoding="ascii")
        (files_root / ".hamnix-roots").write_text("distro    .\n",
                                                  encoding="ascii")
        n_files = 2
    else:
        missing: list[str] = []
        for rel in LINUX_DEBIAN_FILES:
            src = DEBIAN_MINBASE / rel
            if not src.is_file():
                missing.append(rel)
                continue
            try:
                data = src.read_bytes()
            except (OSError, PermissionError) as e:
                missing.append(f"{rel} ({e})")
                continue
            mode = 0o755 if (src.stat().st_mode & 0o111) else 0o644
            dst = files_root / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(data)
            dst.chmod(mode)
            total_bytes += len(data)
            n_files += 1
            for prefix, alias_prefix in LINUX_DEBIAN_USRMERGE.items():
                if rel.startswith(prefix):
                    alias_rel = alias_prefix + rel[len(prefix):]
                    adst = files_root / alias_rel
                    adst.parent.mkdir(parents=True, exist_ok=True)
                    adst.write_bytes(data)
                    adst.chmod(mode)
                    total_bytes += len(data)
                    n_files += 1
                    break
        if missing:
            _say(f"linux-debian-12: skipped {len(missing)} optional files "
                 f"(first 3: {', '.join(missing[:3])}{'…' if len(missing) > 3 else ''})")

        (files_root / ".hamnix-roots").write_text("distro    .\n",
                                                  encoding="ascii")
        n_files += 1

    description = "Debian 12 (bookworm) rootfs for the Linux namespace"
    _write_pkginfo(staging, {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "description": description,
        "target": "#distro",
        "depends": "hamnix-init>=1",
        "provides": "linux-distro",
        "maintainer": "HamnixOS",
        "license": "various (Debian)",
        "homepage": "https://debian.org/",
    })

    out_tar = PACKAGES_OUT / "main" / "packages" / f"{pkg_dirname}.tar.gz"
    sha, size = _tar_gz(staging, out_tar)
    _say(f"built {out_tar.name}: {n_files} files"
         f"{' (SLIM)' if slim else ''}, "
         f"{total_bytes} src bytes, {size} tar bytes, sha={sha[:16]}…")
    return {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "channel": "main",
        "url": f"packages/{pkg_dirname}.tar.gz",
        "sha256": sha,
        "size": size,
        "description": description,
        "depends": ["hamnix-init>=1"],
        "provides": ["linux-distro"],
        "target": "#distro",
    }


# ---------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------

def main() -> int:
    if not BUILD.is_dir():
        raise SystemExit(
            "[build_packages] build/ missing — run scripts/build_iso.sh "
            "first to produce the artifacts this script repackages.")
    PACKAGES_OUT.mkdir(parents=True, exist_ok=True)
    # Channel subdirs: main/ holds every first-party / free package;
    # non-free/ and non-free-firmware/ exist as placeholders so `hpm
    # refresh` against an opt-in enabled channel returns an empty list
    # cleanly (no 404 from GitHub Pages). The contrib channel is
    # reserved (created on-demand when a package needs it).
    main_dir = PACKAGES_OUT / "main"
    main_pkgs = main_dir / "packages"
    main_pkgs.mkdir(parents=True, exist_ok=True)
    (PACKAGES_OUT / "non-free").mkdir(parents=True, exist_ok=True)
    (PACKAGES_OUT / "non-free-firmware").mkdir(parents=True, exist_ok=True)

    # Clean stale outputs (both the old flat shape AND any prior
    # channel-dir build artefacts).
    for old in PACKAGES_OUT.glob("*.tar.gz"):
        old.unlink()
    if (PACKAGES_OUT / "packages").is_dir():
        # Legacy flat layout: remove the bare `packages/` dir if it
        # exists (we now write under main/packages/).
        for old in (PACKAGES_OUT / "packages").glob("*.tar.gz"):
            old.unlink()
    for old in main_pkgs.glob("*.tar.gz"):
        old.unlink()
    for stale in (PACKAGES_OUT / "index.json",
                  main_dir / "index.json",
                  PACKAGES_OUT / "non-free" / "index.json",
                  PACKAGES_OUT / "non-free-firmware" / "index.json"):
        if stale.exists():
            stale.unlink()

    entries: list[dict] = []

    # Build the component packages first (per PACKAGE_SPECS order).
    for spec in PACKAGE_SPECS:
        entry = _build_spec(spec)
        if entry is not None:
            entries.append(entry)

    # Then the bootloader (target=#esp) and the Debian distro.
    entries.append(build_hamnix_bootloader())
    deb_entry = build_linux_debian_12()
    if deb_entry is not None:
        entries.append(deb_entry)

    # Finally hamnix-base (metapackage). It depends on the others, so
    # the index lists it last for human-eyeball reading order.
    entries.append(build_hamnix_base())

    # Cleanup staging area after a successful build.
    stage_root = PACKAGES_OUT / "_stage"
    if stage_root.is_dir() and os.environ.get("HAMNIX_KEEP_STAGE") != "1":
        shutil.rmtree(stage_root)

    updated = os.environ.get("HAMNIX_PKG_DATE", "2026-05-27")
    main_index = {
        "schema": 1,
        "repo": "HamnixOS/packages",
        "channel": "main",
        "url": "https://255.one/main/",
        "updated": updated,
        "description": ("Hamnix main channel — first-party free "
                        "software (hamnix-base + hamnix-coreutils "
                        "metapackages + one hamnix-<cmd> package per "
                        "command + components + bootloader + "
                        "linux-debian-12)"),
        "packages": entries,
    }
    (main_dir / "index.json").write_text(
        json.dumps(main_index, indent=2,
                   ensure_ascii=False) + "\n", encoding="utf-8")
    _say(f"wrote {main_dir / 'index.json'} "
         f"({len(entries)} package entries)")

    # Empty channel indexes. Each opt-in channel has a stub index so
    # `hpm refresh` returns `0 packages` cleanly when subscribed but
    # the channel has no contents yet. The day a non-free-firmware
    # package lands the build pipeline replaces this stub.
    for ch_name, ch_desc in (
        ("non-free",
         "Hamnix non-free channel — placeholder (no packages yet)"),
        ("non-free-firmware",
         "Hamnix non-free firmware channel — placeholder"),
    ):
        stub = {
            "schema": 1,
            "repo": "HamnixOS/packages",
            "channel": ch_name,
            "url": f"https://255.one/{ch_name}/",
            "updated": updated,
            "description": ch_desc,
            "packages": [],
        }
        (PACKAGES_OUT / ch_name / "index.json").write_text(
            json.dumps(stub, indent=2,
                   ensure_ascii=False) + "\n", encoding="utf-8")
        _say(f"wrote {PACKAGES_OUT / ch_name / 'index.json'} "
             f"(0 package entries — empty channel)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
