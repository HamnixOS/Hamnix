#!/usr/bin/env python3
"""
scripts/gen_install_manifest.py — emit etc/install/rootfs.manifest.

The installer (etc/install.hamsh) reads this manifest at install time
and pipes each (target_path, source_path) pair through the userland
`install_rootfs_from_manifest` tool, which delivers each file onto the
freshly-formatted target ext4 via the kernel's install_file ctl verb.
This is the per-file replacement for the old `dd_blk /dev/blk/vdap4
/dev/blk/vdbp2` partition-clobber: each file is created independently
with proper ext4 metadata (inode, extent, dirent) so the install path
no longer assumes byte-equivalent source and target.

The file list mirrors scripts/build_rootfs_img.py:
  * .hamnix-roots                        (the sentinel — required first)
  * REAL_DEBIAN_FILES                    (curated apt/dpkg closure)
  * USRMERGE_ALIASES duplicates          (legacy /bin/, /lib/, /lib64/)
  * bin/busybox (+ applet symlinks)      (Linux ns shell — skipped if
                                          the host's musl-busybox isn't
                                          pre-built; install_rootfs_from_
                                          manifest tolerates missing
                                          source paths)

Source paths point at /n/distros/<rel>: at install time the live ISO
has the source rootfs partition mounted there. The installer
(etc/install.hamsh) binds '#distro' /n/distros ITSELF at startup —
NOT the boot rc, which deliberately keeps the distro tree out of the
ambient namespace for isolation (see etc/rc.boot.full). So the
installer reads bytes from the live mount rather than re-extracting a
SLIM-mode package payload.

Manifest format (one entry per line; '#' comments allowed):

    <target_path>     <source_path>

Both paths are whitespace-free. The kernel-side install_file ctl
walks <target_path>'s parent dirs mkdir-p style, so the manifest can
include arbitrary depths without pre-creating intermediates.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent

# Mirror REAL_DEBIAN_FILES from scripts/build_rootfs_img.py. Keep this
# list in sync: if a file is added to the curated closure there, add
# it here so it lands on the installed target.
REAL_DEBIAN_FILES = [
    # Genuine Debian shells (real /bin/sh -> dash, plus bash).
    "usr/bin/dash",
    "usr/bin/bash",
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
    # bash's extra .so dep (terminal handling).
    "usr/lib/x86_64-linux-gnu/libtinfo.so.6",
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

USRMERGE_ALIASES = {
    "usr/bin/":   "bin/",
    "usr/sbin/":  "sbin/",
    "usr/lib/":   "lib/",
    "usr/lib64/": "lib64/",
}

# Busybox + applet names. The applets are symlinks on the source FS;
# we re-create them as plain files (each pointing to the busybox bytes)
# because the installer's install_file_to_slot path doesn't synthesize
# symlinks yet. install_rootfs_from_manifest tolerates missing source
# paths so a host without u_busybox_musl will skip these entries
# without failing the install.
BUSYBOX_APPLETS = [
    "sh", "ash",
    "ls", "cat", "echo", "cp", "mv", "rm", "mkdir",
    "pwd", "grep", "head", "tail", "wc",
    "true", "false", "env", "printf", "date",
    "sleep", "basename", "dirname",
]


def main() -> int:
    # Source root the installer reads from. The installer
    # (etc/install.hamsh) binds '#distro' /n/distros itself at startup
    # (the boot rc no longer does — isolation invariant). Manifests
    # reference absolute paths under that mount.
    src_root = os.environ.get("HAMNIX_MANIFEST_SRC_ROOT", "/n/distros")

    # Target output (defaults to etc/install/rootfs.manifest under the
    # project root). build_initramfs.py picks up etc/install/* into
    # the cpio at /etc/install/* via its etc-walker.
    out_default = HERE / "etc" / "install" / "rootfs.manifest"
    out_path = Path(os.environ.get("HAMNIX_MANIFEST_OUT",
                                   str(out_default)))
    out_path.parent.mkdir(parents=True, exist_ok=True)

    lines: list[str] = []
    lines.append("# /etc/install/rootfs.manifest — generated by")
    lines.append("# scripts/gen_install_manifest.py at ISO build time.")
    lines.append("#")
    lines.append("# Format: <target_path> <source_path>")
    lines.append("# Comments + blank lines ignored.")
    lines.append("#")
    lines.append("# Read by /bin/install_rootfs_from_manifest, which")
    lines.append("# routes each entry through the kernel's install_file")
    lines.append("# ctl verb on the target /dev/blk/<dev>/ctl.")
    lines.append("")

    # Always plant .hamnix-roots first — without this sentinel,
    # init/main.ad::mount_rootfs_partition can't register #distro on
    # the installed boot.
    lines.append("# Plan 9 sentinel (mount_rootfs_partition reads this)")
    lines.append(f".hamnix-roots    {src_root}/.hamnix-roots")
    lines.append("")

    lines.append("# --- curated apt/dpkg closure (mirrors")
    lines.append("# scripts/build_rootfs_img.py::REAL_DEBIAN_FILES) ---")
    for rel in REAL_DEBIAN_FILES:
        lines.append(f"{rel}    {src_root}/{rel}")
        # usrmerge aliases: same bytes, also planted at the legacy
        # short-prefix path.
        for prefix, alias_prefix in USRMERGE_ALIASES.items():
            if rel.startswith(prefix):
                alias_rel = alias_prefix + rel[len(prefix):]
                # Source is the alias path on the live mount — the
                # rootfs build already plants both copies.
                lines.append(
                    f"{alias_rel}    {src_root}/{alias_rel}")
                break

    lines.append("")
    lines.append("# --- man pages (discovery system) ---")
    lines.append("# Source bytes live in etc/man/ in the Hamnix tree;")
    lines.append("# scripts/build_initramfs.py stages them into the cpio")
    lines.append("# at /usr/share/man/. The live ISO therefore exposes")
    lines.append("# every page at that path (the kernel cpio is mounted")
    lines.append("# as the root tmpfs name lookup), so the manifest can")
    lines.append("# source them from /usr/share/man/<topic>.<N>.md and")
    lines.append("# write them to the target ext4 at the same path.")
    man_dir = HERE / "etc" / "man"
    if man_dir.is_dir():
        for mp in sorted(man_dir.iterdir()):
            if mp.is_file() and mp.suffix == ".md":
                rel = f"usr/share/man/{mp.name}"
                # Source: live-cpio path (not /n/distros — man pages
                # are in the cpio, not the rootfs partition).
                lines.append(f"{rel}    /usr/share/man/{mp.name}")

    lines.append("")
    lines.append("# --- busybox + applets (the Linux-ns shell) ---")
    lines.append("# Source paths under /n/distros/bin/. Applet entries")
    lines.append("# install the busybox binary at each applet name.")
    lines.append("# install_rootfs_from_manifest silently skips missing")
    lines.append("# sources, so a host without u_busybox_musl is fine.")
    lines.append(f"bin/busybox    {src_root}/bin/busybox")
    # On the source rootfs each applet is a symlink → busybox. We
    # install the underlying busybox bytes at each applet name on the
    # target (the kernel-side install_file path doesn't write symlinks
    # yet). The source is the live applet path so the install reads
    # whatever the symlink points at.
    for applet in BUSYBOX_APPLETS:
        lines.append(f"bin/{applet}    {src_root}/bin/{applet}")

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"[gen_install_manifest] wrote {out_path} "
          f"({sum(1 for ln in lines if ln and not ln.startswith('#'))} "
          f"entries)", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
