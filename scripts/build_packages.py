#!/usr/bin/env python3
"""
scripts/build_packages.py — build the v1 Hamnix package tarballs.

This is the Debian-installer-shape pivot: the install process becomes
a series of `hpm install <pkg>` calls instead of dd_blk-based partition
copies. To make that work, the current Hamnix build outputs (kernel ELF,
initramfs cpio content, framework .kos, the Debian-minbase rootfs tree)
have to be repackaged as v1 hpm packages (per docs/packages.md).

Outputs (under build/packages/):

  * hamnix-base-<v>.tar.gz          — the OS userland (init, hamsh, ed,
                                       services, framework .kos, rc.boot).
                                       target: #hamnix-system
  * hamnix-bootloader-<v>.tar.gz    — BOOTX64.EFI + the kernel ELF.
                                       target: #esp
  * hamnix-installer-tools-<v>.tar.gz — the binaries install.hamsh itself
                                       drives (mkfs_ext4, mkfs_fat,
                                       hamnix_partition, dd_blk, hpm).
                                       target: #hamnix-system
  * linux-debian-12-<v>.tar.gz      — the curated Debian rootfs tree the
                                       Linux namespace mounts.
                                       target: #distro
  * index.json                      — repo index in the schema specified
                                       by docs/packages.md.

After this script runs the ISO builder can stage build/packages/ at
/mnt/iso-packages/ on the cpio (Phase 3) and the installer can run

    hpm --repo=file:///mnt/iso-packages --target-prefix=/mnt/newroot \
        install hamnix-base hamnix-installer-tools linux-debian-12

instead of dd_blk'ing whole partitions.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
BUILD = HERE / "build"
USER_DIR = BUILD / "user"
MOD_DIR = BUILD / "mod"
PACKAGES_OUT = BUILD / "packages"
ETC_DIR = HERE / "etc"
KMODS_DIR = HERE / "kernel-modules"
KERNEL_ELF = BUILD / "hamnix-kernel.elf"
EFI_STUB = BUILD / "hamnix-bootx64.efi"
DEBIAN_MINBASE = HERE / "tests" / "distros" / "debian-minbase" / "rootfs"

# v1: hold every package at the same version. The four-package set is
# one atomic release (you don't ship a bootloader newer than the base
# it boots into).
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
        # Preserve executability.
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
    # tarfile defaults aren't fully deterministic (mtime, ordering),
    # so we explicitly sort and pin mtimes.
    if out_path.exists():
        out_path.unlink()
    pkg_dirname = pkg_root.name
    # Collect all entries, sorted by relative path.
    entries: list[Path] = sorted(pkg_root.rglob("*"))
    with tarfile.open(out_path, mode="w:gz", format=tarfile.GNU_FORMAT,
                      compresslevel=9) as tar:
        # Add the top-level directory first.
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
                # Preserve exec bit.
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
# hamnix-base
# ---------------------------------------------------------------------
# The boot-essential userland. Mirrors the "lean cpio" set in
# scripts/build_initramfs.py: init shim, hamsh, ed, distrofs, motd,
# sshd, ifconfig — basically what /etc/rc.boot calls early. We also
# carry every framework .ko (kernel-modules/<X>/*.ko) and the
# /etc/* config tree. This is what `hpm install hamnix-base` lays
# down on a fresh disk.

BASE_USER_KEEP = {
    # The /init shim and the shell.
    "init.elf",
    "hamsh.elf",
    # Distrofs + boot-time services.
    "distrofs.elf",
    "motd.elf",
    "sshd.elf",
    "ed.elf",
    "ifconfig.elf",
    # cat is used by /etc/rc.boot probes.
    "cat.elf",
}


def build_hamnix_base() -> dict:
    pkg_name = "hamnix-base"
    pkg_dirname = f"{pkg_name}-{PKG_VERSION}"
    staging = _stage_dir(PACKAGES_OUT / "_stage" / pkg_dirname)
    files_root = staging / "files"
    files_root.mkdir()
    total_bytes = 0
    n_files = 0

    # /init shim + /bin/<core userland>
    if USER_DIR.is_dir():
        for elf in sorted(USER_DIR.glob("*.elf")):
            if elf.name == "init.elf":
                total_bytes += _copy_file(elf, files_root / "init",
                                          mode=0o755)
                n_files += 1
                continue
            if elf.name not in BASE_USER_KEEP:
                continue
            bin_name = "bin/" + elf.stem
            total_bytes += _copy_file(elf, files_root / bin_name,
                                      mode=0o755)
            n_files += 1
    else:
        _say(f"WARN: {USER_DIR.relative_to(HERE)} missing — "
             f"hamnix-base will lack userland binaries")

    # /etc/* config tree (one level + svc/*.hamsh).
    if ETC_DIR.is_dir():
        for ef in sorted(ETC_DIR.iterdir()):
            if ef.is_file():
                # Skip install.hamsh — that script lives in the live ISO's
                # initramfs, not on the installed system.
                if ef.name == "install.hamsh":
                    continue
                total_bytes += _copy_file(
                    ef, files_root / "etc" / ef.name)
                n_files += 1
            elif ef.is_dir():
                for sub in sorted(ef.iterdir()):
                    if sub.is_file():
                        rel = f"etc/{ef.name}/{sub.name}"
                        total_bytes += _copy_file(sub, files_root / rel)
                        n_files += 1

    # Framework .kos under /lib/modules. We mirror the cpio's "auto"
    # subtree convention: kernel-modules/<X>/*.ko at /lib/modules/<X>.ko.
    # Plus the special-cased e1000e.
    e1000e_ko = KMODS_DIR / "e1000e" / "e1000e.ko"
    if e1000e_ko.is_file():
        total_bytes += _copy_file(e1000e_ko,
                                  files_root / "lib/modules/e1000e.ko",
                                  mode=0o644)
        n_files += 1

    out_tar = PACKAGES_OUT / "packages" / f"{pkg_dirname}.tar.gz"
    _write_pkginfo(staging, {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "description": ("Hamnix base userland — init, hamsh, services, "
                        "framework .kos"),
        "target": "#hamnix-system",
        "maintainer": "HamnixOS",
        "license": "ISC",
        "homepage": "https://255.one/",
    })
    sha, size = _tar_gz(staging, out_tar)
    _say(f"built {out_tar.name}: {n_files} files, "
         f"{total_bytes} src bytes, {size} tar bytes, sha={sha[:16]}…")
    return {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "url": f"packages/{pkg_dirname}.tar.gz",
        "sha256": sha,
        "size": size,
        "description": ("Hamnix base userland — init, hamsh, services, "
                        "framework .kos"),
        "depends": [],
        "target": "#hamnix-system",
    }


# ---------------------------------------------------------------------
# hamnix-bootloader
# ---------------------------------------------------------------------
# BOOTX64.EFI + the kernel ELF. target=#esp — the installer extracts
# the package, then copies BOOTX64.EFI + hamnix-kernel.elf onto the
# freshly-formatted FAT ESP partition. hpm itself doesn't write the
# ESP (it's not a file-server-addressable target); the installer
# handles that specially.

def build_hamnix_bootloader() -> dict:
    pkg_name = "hamnix-bootloader"
    pkg_dirname = f"{pkg_name}-{PKG_VERSION}"
    staging = _stage_dir(PACKAGES_OUT / "_stage" / pkg_dirname)
    files_root = staging / "files"
    files_root.mkdir()
    total_bytes = 0
    n_files = 0

    if not KERNEL_ELF.is_file():
        raise SystemExit(
            f"[build_packages] {KERNEL_ELF.relative_to(HERE)} missing — "
            f"run scripts/build_iso.sh first to produce the kernel ELF")
    if not EFI_STUB.is_file():
        raise SystemExit(
            f"[build_packages] {EFI_STUB.relative_to(HERE)} missing — "
            f"run scripts/build_iso.sh first to produce the EFI stub")

    # The full-fat bootloader payload (BOOTX64.EFI + the kernel ELF)
    # lives in upstream HamnixOS/packages so a fresh-install user can
    # `hpm install hamnix-bootloader` and get a real kernel. But ON THE
    # ISO mini-repo (which is what build_iso.sh stages at
    # /mnt/iso-packages), we cannot embed the kernel.elf inside the
    # cpio that lives inside the kernel.elf — that's a 73 MB recursion
    # bomb. The installer copies BOOTX64.EFI + kernel.elf onto the
    # target ESP via dd_blk from the live ISO's source ESP (which is
    # byte-equivalent), so hpm doesn't need the tarball's payload to
    # complete the install.
    #
    # HAMNIX_BOOTLOADER_SLIM=1 — emit a metadata-only tarball (PKGINFO
    # only, no files/). build_iso.sh sets this when assembling the
    # mini-repo. The upstream HamnixOS/packages build (no env var)
    # produces the full tarball so direct https://255.one/ downloads
    # have a complete payload.
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
        # Plant a README so the empty files/ tree is non-empty.
        (files_root / "README").write_text(
            "This is the ISO mini-repo slim build of hamnix-bootloader. "
            "The real BOOTX64.EFI + kernel.elf payload lives in the live "
            "ISO's source ESP partition and is copied onto the target "
            "ESP by /etc/install.hamsh via dd_blk. The full-payload "
            "package is published at https://255.one/.\n",
            encoding="ascii")
        n_files += 1

    out_tar = PACKAGES_OUT / "packages" / f"{pkg_dirname}.tar.gz"
    _write_pkginfo(staging, {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "description": ("Hamnix UEFI bootloader stub + kernel ELF "
                        "(installs onto the ESP)"),
        "target": "#esp",
        "depends": "hamnix-base>=1",
        "maintainer": "HamnixOS",
        "license": "ISC",
        "homepage": "https://255.one/",
    })
    sha, size = _tar_gz(staging, out_tar)
    _say(f"built {out_tar.name}: {n_files} files, "
         f"{total_bytes} src bytes, {size} tar bytes, sha={sha[:16]}…")
    return {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "url": f"packages/{pkg_dirname}.tar.gz",
        "sha256": sha,
        "size": size,
        "description": ("Hamnix UEFI bootloader stub + kernel ELF "
                        "(installs onto the ESP)"),
        "depends": ["hamnix-base>=1"],
        "target": "#esp",
    }


# ---------------------------------------------------------------------
# hamnix-installer-tools
# ---------------------------------------------------------------------
# Binaries the installer drives. We ship them as a separate package
# so a freshly-installed system has them available for re-installing /
# repartitioning later, AND so /etc/install.hamsh on the ISO can `hpm
# install` them onto /mnt/newroot before laying down the boot files.

INSTALLER_BIN_KEEP = [
    "mkfs_ext4.elf",
    "mkfs_fat.elf",
    "hamnix_partition.elf",
    "dd_blk.elf",
    "hpm.elf",
]


def build_hamnix_installer_tools() -> dict:
    pkg_name = "hamnix-installer-tools"
    pkg_dirname = f"{pkg_name}-{PKG_VERSION}"
    staging = _stage_dir(PACKAGES_OUT / "_stage" / pkg_dirname)
    files_root = staging / "files"
    files_root.mkdir()
    total_bytes = 0
    n_files = 0

    for binname in INSTALLER_BIN_KEEP:
        src = USER_DIR / binname
        if not src.is_file():
            _say(f"WARN: {src.relative_to(HERE)} missing — "
                 f"installer tools will lack {binname}")
            continue
        # bin/<stem>
        dst_rel = "bin/" + binname.removesuffix(".elf")
        total_bytes += _copy_file(src, files_root / dst_rel, mode=0o755)
        n_files += 1

    out_tar = PACKAGES_OUT / "packages" / f"{pkg_dirname}.tar.gz"
    _write_pkginfo(staging, {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "description": ("Hamnix installer tools — partitioner, mkfs, "
                        "dd_blk, hpm"),
        "target": "#hamnix-system",
        "depends": "hamnix-base>=1",
        "maintainer": "HamnixOS",
        "license": "ISC",
        "homepage": "https://255.one/",
    })
    sha, size = _tar_gz(staging, out_tar)
    _say(f"built {out_tar.name}: {n_files} files, "
         f"{total_bytes} src bytes, {size} tar bytes, sha={sha[:16]}…")
    return {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "url": f"packages/{pkg_dirname}.tar.gz",
        "sha256": sha,
        "size": size,
        "description": ("Hamnix installer tools — partitioner, mkfs, "
                        "dd_blk, hpm"),
        "depends": ["hamnix-base>=1"],
        "target": "#hamnix-system",
    }


# ---------------------------------------------------------------------
# linux-debian-12
# ---------------------------------------------------------------------
# The Debian rootfs the Linux namespace mounts. We reuse the curated
# closure list from scripts/build_rootfs_img.py so the package mirrors
# what the ext4 rootfs.img used to carry — except now hpm lays the
# tree down at install time instead of dd_blk-copying a whole ext4
# partition.

# Mirrors REAL_DEBIAN_FILES + USRMERGE_ALIASES from build_rootfs_img.py.
LINUX_DEBIAN_FILES = [
    # Package managers proper.
    "usr/bin/apt",
    "usr/bin/apt-get",
    "usr/bin/apt-cache",
    "usr/bin/apt-config",
    "usr/bin/apt-mark",
    "usr/bin/dpkg",
    "usr/bin/dpkg-deb",
    "usr/bin/dpkg-query",
    "usr/bin/dpkg-split",
    # Dynamic linker + libc.
    "usr/lib64/ld-linux-x86-64.so.2",
    "usr/lib/x86_64-linux-gnu/libc.so.6",
    "usr/lib/x86_64-linux-gnu/libm.so.6",
    "usr/lib/x86_64-linux-gnu/libpthread.so.0",
    "usr/lib/x86_64-linux-gnu/libdl.so.2",
    "usr/lib/x86_64-linux-gnu/libresolv.so.2",
    "usr/lib/x86_64-linux-gnu/librt.so.1",
    # apt's .so closure.
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
    # dpkg's .so closure.
    "usr/lib/x86_64-linux-gnu/libmd.so.0",
    "usr/lib/x86_64-linux-gnu/libmd.so.0.1.0",
    "usr/lib/x86_64-linux-gnu/libselinux.so.1",
    "usr/lib/x86_64-linux-gnu/libpcre2-8.so.0",
    "usr/lib/x86_64-linux-gnu/libpcre2-8.so.0.14.0",
    # /etc essentials.
    "etc/debian_version",
    "etc/os-release",
    "etc/passwd",
    "etc/group",
    "etc/hostname",
    "etc/apt/sources.list",
    "etc/apt/apt.conf",
    # dpkg's admindir scaffolding.
    "var/lib/dpkg/status",
    "var/lib/dpkg/available",
    "var/lib/dpkg/diversions",
    "var/lib/dpkg/statoverride",
    # Trusted GPG keyring.
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

    # Slim mode for the ISO mini-repo: emit metadata-only, no files/.
    # The full Debian closure (~24 MB) is in the live ISO's source
    # rootfs partition and gets dd_blk'd onto the target rootfs.
    # Embedding the tarball in the cpio inside kernel.elf would blow
    # past the 32 MB FAT12 ESP ceiling. The upstream
    # HamnixOS/packages build (no env var) produces the full payload.
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
            "/etc/install.hamsh via dd_blk. The full payload is at "
            "https://255.one/.\n", encoding="ascii")
        (files_root / ".hamnix-roots").write_text("distro    .\n",
                                                  encoding="ascii")
        n_files = 2
        out_tar = PACKAGES_OUT / "packages" / f"{pkg_dirname}.tar.gz"
        _write_pkginfo(staging, {
            "name": pkg_name,
            "version": PKG_VERSION,
            "arch": "x86_64",
            "description": ("Debian 12 (bookworm) rootfs for the Linux "
                            "namespace"),
            "target": "#distro",
            "depends": "hamnix-base>=1",
            "provides": "linux-distro",
            "maintainer": "HamnixOS",
            "license": "various (Debian)",
            "homepage": "https://debian.org/",
        })
        sha, size = _tar_gz(staging, out_tar)
        _say(f"built {out_tar.name}: {n_files} files (SLIM), "
             f"{size} tar bytes, sha={sha[:16]}…")
        return {
            "name": pkg_name,
            "version": PKG_VERSION,
            "arch": "x86_64",
            "url": f"packages/{pkg_dirname}.tar.gz",
            "sha256": sha,
            "size": size,
            "description": ("Debian 12 (bookworm) rootfs for the Linux "
                            "namespace"),
            "depends": ["hamnix-base>=1"],
            "provides": ["linux-distro"],
            "target": "#distro",
        }

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
        # Primary placement.
        dst = files_root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(data)
        dst.chmod(mode)
        total_bytes += len(data)
        n_files += 1
        # Usrmerge aliases.
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

    # Plant `.hamnix-roots` at the package files/ root so when hpm
    # extracts it under the /distro target prefix, the file server
    # discovers the named root entry at boot time.
    (files_root / ".hamnix-roots").write_text("distro    .\n",
                                              encoding="ascii")
    n_files += 1

    out_tar = PACKAGES_OUT / "packages" / f"{pkg_dirname}.tar.gz"
    _write_pkginfo(staging, {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "description": ("Debian 12 (bookworm) rootfs for the Linux "
                        "namespace"),
        "target": "#distro",
        "depends": "hamnix-base>=1",
        "provides": "linux-distro",
        "maintainer": "HamnixOS",
        "license": "various (Debian)",
        "homepage": "https://debian.org/",
    })
    sha, size = _tar_gz(staging, out_tar)
    _say(f"built {out_tar.name}: {n_files} files, "
         f"{total_bytes} src bytes, {size} tar bytes, sha={sha[:16]}…")
    return {
        "name": pkg_name,
        "version": PKG_VERSION,
        "arch": "x86_64",
        "url": f"packages/{pkg_dirname}.tar.gz",
        "sha256": sha,
        "size": size,
        "description": ("Debian 12 (bookworm) rootfs for the Linux "
                        "namespace"),
        "depends": ["hamnix-base>=1"],
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
    # tarballs land under packages/ to match index.json's `url:
    # packages/<name>-<v>.tar.gz` paths (and the upstream repo layout
    # at https://255.one/).
    (PACKAGES_OUT / "packages").mkdir(parents=True, exist_ok=True)
    # Wipe stale tarballs but keep _stage so we can inspect on failure.
    for old in PACKAGES_OUT.glob("*.tar.gz"):
        old.unlink()
    for old in (PACKAGES_OUT / "packages").glob("*.tar.gz"):
        old.unlink()
    if (PACKAGES_OUT / "index.json").exists():
        (PACKAGES_OUT / "index.json").unlink()

    entries: list[dict] = []
    entries.append(build_hamnix_base())
    entries.append(build_hamnix_bootloader())
    entries.append(build_hamnix_installer_tools())
    deb_entry = build_linux_debian_12()
    if deb_entry is not None:
        entries.append(deb_entry)

    # Cleanup staging area after a successful build.
    stage_root = PACKAGES_OUT / "_stage"
    if stage_root.is_dir() and os.environ.get("HAMNIX_KEEP_STAGE") != "1":
        shutil.rmtree(stage_root)

    index = {
        "schema": 1,
        "repo": "HamnixOS/packages",
        "url": "https://255.one/",
        "updated": os.environ.get("HAMNIX_PKG_DATE", "2026-05-26"),
        "description": ("Hamnix package repository — v1 release "
                        "(hamnix-base + bootloader + installer-tools + "
                        "linux-debian-12)"),
        "packages": entries,
    }
    (PACKAGES_OUT / "index.json").write_text(
        json.dumps(index, indent=2) + "\n", encoding="utf-8")
    _say(f"wrote {PACKAGES_OUT / 'index.json'} "
         f"({len(entries)} package entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
