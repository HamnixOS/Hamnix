#!/usr/bin/env python3
"""
scripts/build_rootfs_img.py — stage the Hamnix "distrofs" file-server
image into an ext4 partition (default build/hamnix-rootfs.img).

Plan 9-shape: this is NOT a global rootfs. The kernel discovers the
ext4 partition at boot, reads the `.hamnix-roots` sentinel file
planted at the partition root, and posts a named file server for
each declared sentinel entry. The init namespace (the shell's normal
view) does NOT mount it; only the `linux = ns clean { bind '#distro'
/ ... }` namespace recipe attaches the server, isolating any
apt-installed state to the Linux namespace's private view. See
docs/rootfs_partition.md.

Sentinel: a single text file at the partition root, planted by this
script, named `.hamnix-roots`. Format is `<word> <relpath>` per line.
For the boot rootfs we declare one entry — the whole partition IS
the distro tree:

    distro    .

The kernel's init/main.ad::mount_rootfs_partition() walks this file
and calls name_push("distro", chan_ref, partuuid, ".") so userspace
`bind '#distro' /n/distros` succeeds. Adding more entries (e.g.
`apt-cache var/cache/apt/`) carves out subdirectories as their own
named file servers without changing the partition layout.

Sizing target: minimal Debian — just the apt/dpkg closure + busybox.
Goal is ~60-80 MiB image, NOT a full 200+ MiB debootstrap tree.

Sources mirrored into the image:

  /  (image root)
  ├── usr/bin/apt, apt-get, dpkg, dpkg-deb, ...
  ├── usr/lib/x86_64-linux-gnu/libc.so.6 + dynamic-linker closure
  ├── usr/lib64/ld-linux-x86-64.so.2
  ├── etc/{apt,debian_version,passwd,group,os-release,...}
  ├── var/lib/dpkg/{status,available,...}
  ├── usr/share/keyrings/debian-archive-keyring.gpg
  ├── bin/busybox + applet symlinks  (Linux runtime shell)
  └── lib/, lib64/, bin/, sbin/      (usrmerge aliases that mirror
                                      usr/lib/, usr/lib64/, usr/bin/,
                                      usr/sbin/ — keeps PT_INTERP and
                                      DT_NEEDED happy without needing
                                      directory-symlink walking.)

ENV:
  HAMNIX_ROOTFS_OUT       image path        (default: build/hamnix-rootfs.img)
  HAMNIX_ROOTFS_SIZE_MB   override size     (default: auto-size)
  HAMNIX_DEFAULT_REAL_DEBIAN  0/1           (default: 1)
                          When 0, skip the real Debian closure; image
                          contains only busybox. The kernel still posts
                          the file server, just with less content.
  HAMNIX_ROOTFS_LIVE      0/1               (default: 0)
                          When 1, build the LIVE-medium distro image
                          (#410 Item 2): ONLY the distro/ subtree + a
                          `distro distro` sentinel — no sysroot/ (the
                          live system's native userland rides in the
                          installer cpio, not on this image). This
                          image is packed into /rootfs.sqfs, extracted
                          to a RAM block device at live boot, and
                          posted as the #distro named root so `enter
                          linux { ... }` works with NO install and NO
                          media read. Auto-sizing uses a tighter
                          headroom because every byte is boot RAM.

NOT in the image (out of scope for the file server — these live in the
init namespace, served from cpio or '#' devices):
  /dev, /proc, /sys, /tmp, /run, /srv, /n
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent.parent
OUT_DEFAULT = HERE / "build" / "hamnix-rootfs.img"


# Curated apt/dpkg closure. Mirrors the REAL_DEBIAN_FILES list that
# scripts/build_initramfs.py used to embed into the cpio. Each path is
# RELATIVE to tests/distros/debian-minbase/rootfs/ AND lands at the
# same relative path inside the rootfs image (no /var/lib/distros/
# default/ prefix — the linux ns recipe handles the namespacing).
#
# Keep this list short and targeted: every file is bytes on disk.
REAL_DEBIAN_FILES = [
    # GENUINE Debian shells. `enter linux { /bin/dash }` (real Debian
    # /bin/sh -> dash) and `/bin/bash` run the actual Debian shell, not
    # just the busybox fallback. dash needs only ld.so + libc (staged
    # below); bash also needs libtinfo (added to the .so closure). The
    # usrmerge alias plants each at /bin/<x> so `/bin/dash` resolves.
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

# Usrmerge: Debian binaries reference /lib64/ld-linux-x86-64.so.2 etc.
# directly. Without directory-component symlink walking we plant the
# same bytes at both /usr/<x>/Y and /<x>/Y, matching how the cpio path
# previously did it.
USRMERGE_ALIASES = {
    "usr/bin/":   "bin/",
    "usr/sbin/":  "sbin/",
    "usr/lib/":   "lib/",
    "usr/lib64/": "lib64/",
}


def _stage_real_debian(staging: Path, src_root: Path) -> tuple[int, int]:
    """Plant the curated apt/dpkg closure into `staging`.

    Returns (files_planted, bytes_planted).
    """
    n_files = 0
    n_bytes = 0
    missing: list[str] = []
    for rel in REAL_DEBIAN_FILES:
        src = src_root / rel
        if not src.is_file():
            missing.append(rel)
            continue
        try:
            data = src.read_bytes()
        except (OSError, PermissionError) as e:
            missing.append(f"{rel} (unreadable: {e})")
            continue
        mode = (0o755 if src.stat().st_mode & 0o111 else 0o644)
        # Primary path
        dst = staging / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(data)
        dst.chmod(mode)
        n_files += 1
        n_bytes += len(data)
        # Usrmerge aliases
        for prefix, alias_prefix in USRMERGE_ALIASES.items():
            if rel.startswith(prefix):
                alias_rel = alias_prefix + rel[len(prefix):]
                adst = staging / alias_rel
                adst.parent.mkdir(parents=True, exist_ok=True)
                adst.write_bytes(data)
                adst.chmod(mode)
                n_files += 1
                n_bytes += len(data)
                break
    if missing:
        print(f"[build_rootfs_img] missing optional files ({len(missing)}): "
              f"{', '.join(missing[:5])}"
              f"{'...' if len(missing) > 5 else ''}", flush=True)
    return n_files, n_bytes


# Subtrees pruned when mirroring the FULL debootstrap tree. Pure
# runtime/scratch mounts (the linux ns binds #c,#p,#s etc. over them
# anyway) or many MiB of locale/doc/man that burn live-boot RAM without
# changing what `ls /` shows. Each entry is RELATIVE to the debootstrap
# root. Pruning keeps the live RAM image practical while the tree stays
# unmistakably Debian (real coreutils/bash/apt/dpkg + Debian layout).
FULL_DEBIAN_PRUNE = {
    "proc", "sys", "dev", "run", "tmp", "mnt", "media", "boot", "srv",
    "usr/share/doc", "usr/share/man", "usr/share/locale",
    "usr/share/info", "usr/share/zoneinfo", "usr/share/i18n",
    "usr/share/common-licenses",
    "var/cache", "var/log",
    # apt's downloaded package-index lists (~55 MiB) are pure cache — an
    # `apt update` re-fetches them. The installed-package DB (var/lib/
    # dpkg) is KEPT: it is genuinely part of looking like Debian.
    "var/lib/apt/lists",
}

# Debian usrmerge: these top-level names are DIRECTORY symlinks into
# /usr (e.g. /bin -> usr/bin). The kernel's ext4/distrofs path does not
# walk directory-component symlinks, so they are recreated as REAL
# directories duplicating their /usr target (the only way a lookup of
# /bin/ls or /lib64/ld-linux-x86-64.so.2 resolves with no symlink walk).
#
# /bin and /sbin alias every executable (cheap, all referenced by PATH).
# /lib aliases ONLY the shared-object closure dir (x86_64-linux-gnu) +
# the dynamic linker — the rest of /usr/lib (apt/, dpkg/, perl5/, ...)
# is referenced exclusively via /usr/lib/... paths, never /lib/..., so
# duplicating it would waste ~17 MiB of boot RAM for no resolution
# benefit. A None value means "whole target"; a tuple means "only these
# child subdirs of the target".
USRMERGE_DIR_LINKS = {
    "bin": None,
    "sbin": None,
    "lib": ("x86_64-linux-gnu",),
    "lib64": None,
}


def _copy_tree_deref(src: Path, dst: Path, prune_abs: set) -> tuple[int, int]:
    """Copy a directory subtree, NOT following directory symlinks (so no
    usrmerge re-walk / cycles). Regular files are copied; file symlinks
    are dereferenced to their target bytes when that target is a regular
    file (the kernel can't follow them either); special files and
    dangling links are skipped. Returns (files, bytes)."""
    n_files = 0
    n_bytes = 0
    for dirpath, dirnames, filenames in os.walk(src, followlinks=False):
        d = Path(dirpath)
        rel_dir = d.relative_to(src)
        # Prune declared subtrees + any nested directory symlink (avoid
        # re-walking /usr through an alias). Keep file symlinks (handled
        # below); only directory symlinks are dropped from the descent.
        kept = []
        for dn in dirnames:
            child = d / dn
            if child.resolve() in prune_abs:
                continue
            if child.is_symlink():
                continue          # don't descend a dir symlink
            kept.append(dn)
        dirnames[:] = kept
        (dst / rel_dir).mkdir(parents=True, exist_ok=True)
        for fn in filenames:
            sp = d / fn
            try:
                st = sp.stat()    # follow a file symlink to its target
            except OSError:
                continue          # dangling / unreadable
            if st.st_mode & 0o170000 != 0o100000:
                continue          # not a regular file
            try:
                data = sp.read_bytes()
            except (OSError, PermissionError):
                continue
            op = dst / rel_dir / fn
            op.write_bytes(data)
            op.chmod(0o755 if st.st_mode & 0o111 else 0o644)
            n_files += 1
            n_bytes += len(data)
    return n_files, n_bytes


def _stage_real_debian_full(staging: Path, src_root: Path) -> tuple[int, int]:
    """Mirror the debootstrap tree into `staging` so `enter linux
    { ls / }` shows a genuine Debian root (real /bin/ls, /bin/bash,
    coreutils, apt, dpkg, /etc/debian_version, /var/lib/dpkg, the full
    shared-object closure under /usr/lib, ...) that is materially
    distinct from the native Hamnix root — not a one-marker stub.

    Strategy (no symlink cycles, no double-count):
      1. Copy every NON-symlink top-level subtree verbatim (usr, etc,
         var, root, home, opt), pruning FULL_DEBIAN_PRUNE.
      2. Recreate the four usrmerge directory symlinks (/bin,/sbin,/lib,
         /lib64) as REAL directories mirroring their /usr targets, so the
         kernel resolves /bin/ls and /lib64/ld-linux-x86-64.so.2 with no
         directory-symlink walk.

    Returns (entries_planted, bytes_planted).
    """
    prune_abs = {(src_root / p).resolve() for p in FULL_DEBIAN_PRUNE}
    n_files = 0
    n_bytes = 0
    # 1. Top-level non-symlink subtrees (and top-level regular files).
    for entry in sorted(src_root.iterdir()):
        name = entry.name
        if entry.resolve() in prune_abs:
            continue
        if entry.is_symlink():
            continue              # usrmerge dir links handled in step 2
        if entry.is_dir():
            f, b = _copy_tree_deref(entry, staging / name, prune_abs)
            n_files += f
            n_bytes += b
        elif entry.is_file():
            data = entry.read_bytes()
            (staging / name).write_bytes(data)
            (staging / name).chmod(
                0o755 if entry.stat().st_mode & 0o111 else 0o644)
            n_files += 1
            n_bytes += len(data)
    # 2. usrmerge aliases -> real directories duplicating the /usr target
    #    (whole target, or only the named child subdirs for /lib).
    for link, only_children in USRMERGE_DIR_LINKS.items():
        lp = src_root / link
        if not lp.is_symlink():
            continue
        target = (src_root / os.readlink(lp))
        if not target.is_dir():
            continue
        if only_children is None:
            f, b = _copy_tree_deref(target, staging / link, prune_abs)
            n_files += f
            n_bytes += b
        else:
            (staging / link).mkdir(parents=True, exist_ok=True)
            for child in only_children:
                csrc = target / child
                if csrc.is_dir():
                    f, b = _copy_tree_deref(
                        csrc, staging / link / child, prune_abs)
                    n_files += f
                    n_bytes += b
    return n_files, n_bytes


def _stage_busybox(staging: Path) -> bool:
    """Plant musl-static-PIE busybox + applet symlinks at the image root.

    The Linux ns mounts the image at `/` inside its private namespace,
    so /bin/sh inside `enter linux { ... }` resolves to the busybox here.
    """
    bb_src = HERE / "tests" / "u-binary" / "u_busybox_musl"
    if not bb_src.is_file():
        print(f"[build_rootfs_img] WARN: {bb_src.relative_to(HERE)} "
              f"absent — `enter linux {{ /bin/sh }}` will not work",
              flush=True)
        return False
    bb_dir = staging / "bin"
    bb_dir.mkdir(parents=True, exist_ok=True)
    bb_target = bb_dir / "busybox"
    shutil.copy2(bb_src, bb_target)
    bb_target.chmod(0o755)
    # Minimal-but-usable working set. Every name here is confirmed
    # present in the staged musl busybox's compiled-in applet table
    # (busybox --list). The fixture is built from `make defconfig`
    # (all sensible applets ON) minus a small DISABLE_APPLETS set
    # (see tests/u-binary/src/musl_busybox/Makefile) — so e.g. `mount`,
    # `awk`, `sed`, `tar`, `vi`, `ip`, `ping` are intentionally ABSENT
    # from the binary and are NOT listed here (a link for a missing
    # applet would just print "applet not found"). This is the small
    # live root, not the full mirror; keep it lean.
    bb_applets = [
        # shell
        "sh", "ash",
        # file listing / IO
        "ls", "cat", "echo", "cp", "mv", "rm", "mkdir", "rmdir",
        "ln", "touch", "chmod", "chown", "chgrp", "stat", "readlink",
        # text
        "pwd", "grep", "head", "tail", "wc", "sort", "cut", "tr",
        "uniq", "find", "which",
        # disk / fs info
        "du", "df", "sync",
        # scripting primitives
        "true", "false", "env", "printf", "date", "sleep", "usleep",
        "basename", "dirname", "mktemp",
        # system / identity
        "uname", "id", "whoami", "hostname", "groups", "who", "users",
        # process
        "ps", "kill", "free", "uptime",
    ]
    # Plant each applet as a HARD link to the busybox binary, NOT a
    # symlink. The kernel's distrofs/ext4 exec path does not traverse
    # file-component symlinks (same reason the real-Debian closure
    # dereferences /bin/sh -> dash to dash's bytes), so a symlinked
    # /bin/printf would resolve to a 7-byte "busybox" string the kernel
    # won't follow and `enter linux { /bin/printf ... }` would silently
    # exec nothing. A hard link shares busybox's inode (zero extra data
    # blocks) and is a real executable entry the kernel execs directly;
    # busybox still multiplexes on argv[0] (the applet name). mkfs.ext4
    # -d preserves hard links across the staging dir.
    for applet in bb_applets:
        link = bb_dir / applet
        if link.exists() or link.is_symlink():
            link.unlink()
        try:
            os.link(bb_target, link)
        except OSError:
            # Fallback (e.g. cross-device staging): a real byte copy is
            # still a directly-execable entry, unlike a symlink.
            shutil.copy2(bb_target, link)
            link.chmod(0o755)
    # Debian-shape skeleton dirs. When the curated REAL_DEBIAN closure is
    # present these get populated for real; when it is absent (host
    # without tests/distros/debian-minbase/rootfs/) they still give the
    # distro root top-level entries — sbin/, lib64/, var/ — that the
    # native sysroot/ does NOT carry. That asymmetry is what
    # scripts/test_img_distro_isolation.sh keys on to prove the two `/`s
    # are distinct file servers, so the isolation gate does not depend on
    # a host-only Debian tree being available.
    for skel in ("sbin", "lib", "lib64", "var/lib/dpkg", "usr/bin"):
        (staging / skel).mkdir(parents=True, exist_ok=True)
    print(f"[build_rootfs_img] staged busybox ({bb_target.stat().st_size} "
          f"bytes) + {len(bb_applets)} applets at /bin/ "
          f"(+ Debian-shape skeleton dirs)", flush=True)
    return True


# Names under build/user/ that must NOT be staged into sysroot/bin —
# init.elf is the kernel's boot entrypoint (lands at /init in the cpio,
# not /bin), never a PATH-resolved tool.
SYSROOT_BIN_SKIP = {
    "init.elf",
}

# etc/ files that must NOT be staged onto the partition's sysroot/etc.
#
# rc.boot IS staged on the partition now (cpio-less installed disk):
# the kernel ELF-loads sysroot/init off ext4, which execs `/bin/hamsh
# /etc/rc.boot`, and with the kernel's `bind '#sysroot' /` already
# applied that resolves to sysroot/etc/rc.boot on the partition. The
# bootstrap rc applies the device binds (#s,#p,#/), re-asserts the
# sysroot bind (harmless / idempotent — the kernel already did it),
# and `source`s rc.boot.full. Nothing here is skipped today; the set
# is kept for future cpio-only files.
SYSROOT_ETC_SKIP: set[str] = set()


def _stage_adder_tools(sysroot: Path) -> tuple[int, int]:
    """Stage every build/user/*.elf as sysroot/bin/<name>.

    These are the ~110 native Adder userland tools (ls, cp, cat, ...).
    On the ISO path the lean cpio omits them; the kernel binds
    `#sysroot` at `/` so /bin/<name> resolves to this subtree on the
    partition. Returns (files, bytes).
    """
    user_dir = HERE / "build" / "user"
    if not user_dir.is_dir():
        print(f"[build_rootfs_img] WARN: {user_dir.relative_to(HERE)} "
              f"absent — sysroot/bin will be empty (run build_user.sh)",
              flush=True)
        return 0, 0
    bindir = sysroot / "bin"
    bindir.mkdir(parents=True, exist_ok=True)
    n_files = 0
    n_bytes = 0
    for elf in sorted(user_dir.glob("*.elf")):
        if elf.name in SYSROOT_BIN_SKIP:
            continue
        data = elf.read_bytes()
        dst = bindir / elf.stem
        dst.write_bytes(data)
        dst.chmod(0o755)
        n_files += 1
        n_bytes += len(data)
    return n_files, n_bytes


def _stage_init_shim(sysroot: Path) -> bool:
    """Stage build/user/init.elf as sysroot/init (the boot entrypoint).

    The kernel ELF-loads `/init` at boot. On a cpio-less installed
    disk the kernel binds `#sysroot` at `/` first, so `/init` resolves
    to this `sysroot/init` file on the ext4 partition (NOT the bin/
    tools — init is the first-task entrypoint, exec'd by the kernel,
    never PATH-resolved). The shim then execs `/bin/hamsh
    /etc/rc.boot`, both of which resolve off sysroot/ through the same
    bind. Returns True if staged.
    """
    init_src = HERE / "build" / "user" / "init.elf"
    if not init_src.is_file():
        print(f"[build_rootfs_img] WARN: {init_src.relative_to(HERE)} "
              f"absent — sysroot/init missing (run build_user.sh); "
              f"a cpio-less disk will not boot", flush=True)
        return False
    dst = sysroot / "init"
    dst.write_bytes(init_src.read_bytes())
    dst.chmod(0o755)
    print(f"[build_rootfs_img] staged init shim "
          f"({dst.stat().st_size} bytes) at sysroot/init", flush=True)
    return True


def _stage_sysroot_etc(sysroot: Path) -> int:
    """Mirror the source-tree etc/ into sysroot/etc on the partition.

    Admins persist /etc edits across boots because /etc lives on the
    sysroot partition (not the read-only cpio). The full boot rc is
    staged as sysroot/etc/rc.boot.full; the cpio bootstrap rc `source`s
    it once `#sysroot` is bound at /. Sub-directories (svc/, man/) are
    walked one level deep, matching the cpio layout.
    """
    etc_src = HERE / "etc"
    if not etc_src.is_dir():
        return 0
    etc_dst = sysroot / "etc"
    etc_dst.mkdir(parents=True, exist_ok=True)
    n = 0
    for ef in sorted(etc_src.iterdir()):
        if ef.is_file():
            if ef.name in SYSROOT_ETC_SKIP:
                continue
            data = ef.read_bytes()
            if ef.name == "rc.boot.full":
                # PARTITION-EXEC KEYSTONE PROOF. The source-tree
                # etc/rc.boot.full is ALSO embedded in the (lean) cpio,
                # so its own banners cannot distinguish "sourced from the
                # partition through bind '#sysroot' /" from "sourced from
                # the cpio fallback". Append a sentinel echo HERE — only
                # to the partition copy — whose text exists nowhere in
                # the cpio. If this line lands on the console, the
                # bootstrap rc's `source /etc/rc.boot.full` MUST have
                # resolved through the named-root bind to ext4. A cpio
                # fallback physically cannot emit it. scripts/
                # test_iso_shell.sh asserts exactly this marker as the
                # keystone. (Appended at the very top so it prints even
                # if a later line in the rc later faults.)
                sentinel = b"echo 'HAMNIX_PARTITION_RC_SOURCED_OK'\n"
                data = sentinel + data
            (etc_dst / ef.name).write_bytes(data)
            n += 1
        elif ef.is_dir():
            if ef.name == "man":
                # Manpages are consumed at /usr/share/man/<topic> (same
                # convention the cpio uses); stage them there too.
                man_dst = sysroot / "usr" / "share" / "man"
                man_dst.mkdir(parents=True, exist_ok=True)
                for sub in sorted(ef.iterdir()):
                    if sub.is_file():
                        (man_dst / sub.name).write_bytes(sub.read_bytes())
                        n += 1
                continue
            sub_dst = etc_dst / ef.name
            sub_dst.mkdir(parents=True, exist_ok=True)
            for sub in sorted(ef.iterdir()):
                if sub.is_file():
                    (sub_dst / sub.name).write_bytes(sub.read_bytes())
                    n += 1
    return n


# Debian release the busybox-only fallback advertises. Kept in sync with
# tests/distros/debian-minbase (bookworm). Only used when the real
# debootstrap tree is absent (this host) or LIVE-MINIMAL trims it away.
_MINIMAL_DEBIAN_VERSION = "12.9"


def _stage_minimal_etc(distro: Path) -> int:
    """Plant a minimal-but-REAL Debian /etc (+ /var/lib/dpkg/status).

    The busybox-only staging paths (LIVE-MINIMAL, or a host with no
    debootstrap tree) previously left the distro root with NO /etc at
    all, so `enter linux { ls / }` showed no /etc and
    `cat /etc/debian_version` failed — breaking apt / config / passwd /
    login inside the Linux namespace. The full real-Debian closures do
    stage /etc from tests/distros/debian-minbase, so this helper ONLY
    writes files that are not already present: it never clobbers a
    genuine staged /etc, and it makes the busybox-only namespace
    Debian-shaped enough for basic config/identity tooling.

    Returns the number of files planted.
    """
    files: dict[str, str] = {
        "etc/debian_version": _MINIMAL_DEBIAN_VERSION + "\n",
        "etc/os-release": (
            'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n'
            'NAME="Debian GNU/Linux"\n'
            'VERSION_ID="12"\n'
            'VERSION="12 (bookworm)"\n'
            'VERSION_CODENAME=bookworm\n'
            "ID=debian\n"
            'HOME_URL="https://www.debian.org/"\n'
            'SUPPORT_URL="https://www.debian.org/support"\n'
            'BUG_REPORT_URL="https://bugs.debian.org/"\n'
        ),
        "etc/hostname": "hamnix\n",
        "etc/passwd": (
            "root:x:0:0:root:/root:/bin/sh\n"
            "daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n"
            "bin:x:2:2:bin:/bin:/usr/sbin/nologin\n"
            "sys:x:3:3:sys:/dev:/usr/sbin/nologin\n"
            "nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n"
        ),
        "etc/group": (
            "root:x:0:\n"
            "daemon:x:1:\n"
            "bin:x:2:\n"
            "sys:x:3:\n"
            "adm:x:4:\n"
            "sudo:x:27:\n"
            "nogroup:x:65534:\n"
        ),
        "etc/apt/sources.list": (
            "deb http://deb.debian.org/debian bookworm main\n"
            "deb http://deb.debian.org/debian bookworm-updates main\n"
            "deb http://security.debian.org/debian-security "
            "bookworm-security main\n"
        ),
        "etc/apt/apt.conf": (
            'APT::Architecture "amd64";\n'
        ),
        # dpkg admindir scaffolding — an empty status DB is a valid,
        # queryable "no packages installed" state (dpkg -l works).
        "var/lib/dpkg/status": "",
        "var/lib/dpkg/available": "",
    }
    n = 0
    for rel, content in files.items():
        dst = distro / rel
        if dst.exists():
            continue                    # never clobber a real staged /etc
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(content, encoding="ascii")
        dst.chmod(0o644)
        n += 1
    return n


def _plant_distro_provenance(distro: Path) -> None:
    """Plant a PROVENANCE marker file at the distro root.

    This file exists ONLY in the Debian distro tree, never in the native
    Hamnix sysroot. It is the cheapest unambiguous proof that
    `enter linux { ls / }` is bound to a DIFFERENT file server than the
    user-mode `/` (the isolation gate asserts it appears in the linux ns
    and is ABSENT from the native root). The bulk content differs too
    (real Debian coreutils/apt/dpkg vs native Adder tools); this marker
    is just the single deterministic needle the serial gates grep for.
    """
    (distro / "PROVENANCE").write_text(
        "hamnix-distro-namespace: real Debian root (debootstrap minbase)\n"
        "This tree backs '#distro' / inside `enter linux { ... }`.\n"
        "It is a SEPARATE file server from the native Hamnix '/'.\n",
        encoding="ascii")


def _stage_distro(distro: Path, live: bool = False) -> None:
    """Stage the distro/ subtree: a genuine Debian root + busybox fallback.

    LIVE-MINIMAL (size budget). The live in-RAM distro is extracted into a
    CONTIGUOUS RAM block device at boot, so every staged MiB is boot RAM.
    Under the user's `-m 1G` boot only ~316 MiB is free, but the FULL
    debootstrap mirror is ~360 MiB — the contiguous live-root alloc fails
    (`memblock_alloc(...) failed`), the rootfs half-loads, and DE app spawns
    hit `elf: OOM`. So when `live` is true we DEFAULT to staging ONLY the
    busybox minimal namespace (HAMNIX_LIVE_MINIMAL!=0): `enter linux` still
    runs basic Debian-shape binaries (/bin/sh, cat, ls, ...) but the heavy
    apt/dpkg/libapt-pkg closure and the full Debian tree are EXCLUDED from
    the RAM image. The heavy closure belongs on the persistent INSTALLED
    disk (not RAM-constrained) or in a dedicated apt-test image built with
    HAMNIX_LIVE_MINIMAL=0. Set HAMNIX_LIVE_MINIMAL=0 to opt back into the
    full real-Debian closure for the live distro (apt-install e2e image).

    Content selection (most-faithful first):
      * live build with HAMNIX_LIVE_MINIMAL!=0 (default) -> busybox only.
      * HAMNIX_DEFAULT_REAL_DEBIAN in {0,off,no,""} -> busybox only.
      * else, when the debootstrap tree (tests/distros/debian-minbase/
        rootfs) is present:
          - HAMNIX_DEBIAN_FULL!=0 (default): mirror the WHOLE tree (minus
            bulky locale/doc/man + runtime mounts) so `ls /` is a real
            Debian root. This is what the user asked for: a `/` that
            looks like Debian and shares NOTHING with the native root.
          - HAMNIX_DEBIAN_FULL=0: stage only the curated apt/dpkg closure
            (the lean legacy slice) for size-constrained builds.
      * else (no debootstrap tree on this host): busybox only, and the
        Debian-shape skeleton dirs from _stage_busybox keep the tree
        recognisably non-native.

    A PROVENANCE marker is ALWAYS planted (even busybox-only) so the
    isolation gates have a deterministic distro-only needle.
    """
    minbase = HERE / "tests" / "distros" / "debian-minbase" / "rootfs"
    real_debian_raw = os.environ.get("HAMNIX_DEFAULT_REAL_DEBIAN", "1")
    full_raw = os.environ.get("HAMNIX_DEBIAN_FULL", "1")
    want_full = full_raw not in ("0", "", "off", "no")
    live_minimal_raw = os.environ.get("HAMNIX_LIVE_MINIMAL", "1")
    live_minimal = live and live_minimal_raw not in ("0", "", "off", "no")
    if live_minimal:
        print(f"[build_rootfs_img] LIVE-MINIMAL "
              f"(HAMNIX_LIVE_MINIMAL={live_minimal_raw}): live distro = "
              f"busybox namespace only; heavy real-Debian apt/dpkg closure "
              f"EXCLUDED from the RAM image (set HAMNIX_LIVE_MINIMAL=0 for "
              f"the full closure, e.g. the apt-install e2e image).",
              flush=True)
    elif real_debian_raw in ("0", "", "off", "no"):
        print(f"[build_rootfs_img] HAMNIX_DEFAULT_REAL_DEBIAN={real_debian_raw}: "
              f"skipping real Debian closure", flush=True)
    elif not minbase.is_dir():
        print(f"[build_rootfs_img] WARN: {minbase.relative_to(HERE)} "
              f"absent — distro/ subtree will contain only busybox "
              f"(run tests/distros/debian-minbase/BUILD.sh for a real "
              f"Debian root)", flush=True)
    elif want_full:
        n, b = _stage_real_debian_full(distro, minbase)
        print(f"[build_rootfs_img] mirrored FULL Debian root: {n} files "
              f"({b/(1<<20):.1f} MiB) into distro/ from "
              f"{minbase.relative_to(HERE)} (real /bin/ls,/bin/bash,apt,"
              f"dpkg; usrmerge dereferenced; locale/doc/man pruned)",
              flush=True)
    else:
        n, b = _stage_real_debian(distro, minbase)
        print(f"[build_rootfs_img] staged {n} curated Debian apt/dpkg files "
              f"({b/(1<<20):.1f} MiB) into distro/ from "
              f"{minbase.relative_to(HERE)} (HAMNIX_DEBIAN_FULL=0)",
              flush=True)
    _stage_busybox(distro)
    # Guarantee a minimal-but-real Debian /etc (+ dpkg status) exists even
    # on the busybox-only paths (LIVE-MINIMAL / no debootstrap tree). Runs
    # AFTER the real-Debian staging above so it only fills in files that
    # closure did not already provide — a full mirror keeps its own /etc.
    en = _stage_minimal_etc(distro)
    if en:
        print(f"[build_rootfs_img] planted {en} minimal /etc + dpkg files "
              f"(debian_version={_MINIMAL_DEBIAN_VERSION}) into distro/ "
              f"(busybox-only fallback — real closure absent/trimmed)",
              flush=True)
    _plant_distro_provenance(distro)


def _stage_directory(staging: Path):
    """Mirror the multi-root file-server contents into `staging`.

    The partition's TOP LEVEL is a set of named subtree roots (Plan 9
    shape, docs/rootfs_partition.md), each declared in .hamnix-roots:

        sysroot/   native Hamnix admin filesystem (bin/, etc/, usr/)
        distro/    the real Debian tree (apt/dpkg/busybox closure)
        .hamnix-roots

    The kernel posts each subtree as a named file server (#sysroot,
    #distro). The bootstrap rc binds #sysroot at /, and the linux ns
    binds #distro at / inside its hermetic recipe.
    """
    sysroot = staging / "sysroot"
    distro = staging / "distro"
    sysroot.mkdir(parents=True, exist_ok=True)
    distro.mkdir(parents=True, exist_ok=True)

    # --- distro/ subtree: the real Debian closure + busybox ----------
    _stage_distro(distro)

    # --- sysroot/ subtree: native Adder tools + /etc -----------------
    tn, tb = _stage_adder_tools(sysroot)
    print(f"[build_rootfs_img] staged {tn} Adder tools "
          f"({tb/(1<<20):.1f} MiB) into sysroot/bin/", flush=True)
    _stage_init_shim(sysroot)
    en = _stage_sysroot_etc(sysroot)
    print(f"[build_rootfs_img] staged {en} sysroot/etc files "
          f"(incl. rc.boot.full)", flush=True)

    _stage_hamnix_roots(staging)


def _stage_directory_live(staging: Path):
    """Stage the LIVE-medium distro image (#410 Item 2).

    Layout (vs. the installed multi-root image): ONLY the Debian distro
    subtree, posted as #distro. There is NO sysroot/ — on the live
    medium the native Adder userland + /etc ride in the installer
    kernel's cpio (firmware-loaded, no media read), so duplicating them
    here would only burn boot RAM. The sentinel declares the single
    root:

        distro    distro
    """
    distro = staging / "distro"
    distro.mkdir(parents=True, exist_ok=True)
    _stage_distro(distro, live=True)
    # Re-plant the runtime/scratch mounts that FULL_DEBIAN_PRUNE strips, as
    # EMPTY world-writable (mode 1777, sticky) dirs. On a normal Debian these
    # are tmpfs mount points; here the live root is the only writable fs, so a
    # regular-user client needs them present + writable: /run is
    # XDG_RUNTIME_DIR (weston-terminal os_create_anonymous_file fallback, the
    # wl socket dir), /tmp is scratch, /var/cache holds the fontconfig cache
    # fallback. Without these, `mkdir -p /run/...` fails ENOENT and
    # XDG_RUNTIME_DIR points at a non-existent dir.
    # tmp/.X11-unix: Xwayland's X11 unix-socket + lock dir. The path
    # AF_UNIX bind rendezvouses through the in-kernel registry (no VFS
    # node), but Xwayland's transport mkdir()s /tmp/.X11-unix + writes
    # /tmp/.X<n>-lock, so the dir must exist + be writable at runtime.
    for rel in ("run", "run/fontconfig", "tmp", "tmp/.X11-unix",
                "var/cache", "var/cache/fontconfig"):
        d = distro / rel
        d.mkdir(parents=True, exist_ok=True)
        os.chmod(d, 0o1777)
    print("[build_rootfs_img] planted writable runtime dirs "
          "(/run,/tmp,/var/cache; mode 1777) into live distro/", flush=True)
    sentinel = staging / ".hamnix-roots"
    sentinel.write_text("distro    distro\n", encoding="ascii")
    print("[build_rootfs_img] planted LIVE .hamnix-roots sentinel "
          "(declares #distro -> distro/ only)", flush=True)


def _stage_hamnix_roots(staging: Path) -> None:
    """Plant `.hamnix-roots` at the partition root (multi-root layout).

    Two named subtree roots, one `<name> <relpath>` line each:

        sysroot   sysroot
        distro    distro

    The kernel's init/main.ad::mount_rootfs_partition() parses this and
    calls name_push() for each, posting #sysroot and #distro in the
    named file-server stack. The bootstrap rc then binds #sysroot at /
    (so /bin/<tool> resolves to sysroot/bin/<tool> on the partition) and
    the linux ns binds #distro at / inside its hermetic recipe.

    Per-user homes (GROUNDWORK — not yet emitted here): when adduser
    creates a top-level <username>/ folder it appends a
    `<username>  <username>` line to this sentinel and the kernel
    name_push()es a #<username> root, which that user's session binds as
    their home. See init/main.ad::_register_user_root() and the
    docstring in scripts/build_rootfs_img.py near _stage_user_home().
    """
    sentinel = staging / ".hamnix-roots"
    sentinel.write_text("sysroot   sysroot\ndistro    distro\n",
                        encoding="ascii")
    print(f"[build_rootfs_img] planted .hamnix-roots sentinel "
          f"(declares #sysroot -> sysroot/, #distro -> distro/)",
          flush=True)


def _stage_user_home(staging: Path, username: str) -> None:
    """GROUNDWORK: create a top-level per-user home subtree + sentinel
    entry.

    Each non-hostowner user's home is its own TOP-LEVEL partition folder
    named by username, registered as its own named root (#<username>)
    and bound as that user's home in their session — giving them the
    partition's free space. The HOSTOWNER's home stays in sysroot/.

    This helper lays the build-time groundwork: it creates the folder
    and appends a `<username>  <username>` line to .hamnix-roots. The
    matching RUNTIME path — a top-level folder becoming a #<username>
    named root via name_push at adduser time — is stubbed in
    init/main.ad::_register_user_root(). Full dynamic adduser is a
    documented follow-up; nothing calls this yet (the load-bearing
    deliverable is sysroot + distro).
    """
    home = staging / username
    home.mkdir(parents=True, exist_ok=True)
    sentinel = staging / ".hamnix-roots"
    line = f"{username}   {username}\n"
    with open(sentinel, "a", encoding="ascii") as f:
        f.write(line)
    print(f"[build_rootfs_img] staged per-user home subtree "
          f"{username}/ (+ sentinel entry #{username})", flush=True)


def _du_bytes(path: Path) -> int:
    """Recursive size in bytes (follows symlinks within the tree only)."""
    total = 0
    for p in path.rglob("*"):
        try:
            if p.is_symlink():
                continue                    # symlinks are link-sized
            if p.is_file():
                total += p.stat().st_size
        except OSError:
            pass
    return total


def _pick_size_mb(staging_bytes: int, live: bool = False) -> int:
    raw = os.environ.get("HAMNIX_ROOTFS_SIZE_MB", "").strip()
    if raw:
        try:
            return int(raw)
        except ValueError:
            raise SystemExit(
                f"HAMNIX_ROOTFS_SIZE_MB={raw!r}: must be an integer")
    staged_mib = (staging_bytes + (1 << 20) - 1) // (1 << 20)
    if live:
        # Live image is extracted to a RAM block device at boot, so every
        # MiB here is boot RAM — but the live root is the ONLY writable
        # filesystem a live-session process sees, and REGULAR-user clients
        # (the DE terminal + weston-terminal run as uid 1001) need real
        # writable scratch: fontconfig cache refresh, ~/.config, per-app
        # runtime state, XDG_RUNTIME_DIR, /tmp. The old +16 MiB scratch left
        # only ~12 MiB free — BELOW the 5% reserved-block floor — so every
        # regular-user write failed ENOSPC. Give a comfortable scratch
        # margin (default 128 MiB; override via HAMNIX_LIVE_SCRATCH_MB) on
        # top of +16 MiB ext4 metadata. Combined with mkfs `-m 0` (below)
        # this makes the whole margin usable by non-root clients.
        try:
            scratch = int(os.environ.get("HAMNIX_LIVE_SCRATCH_MB", "128"))
        except ValueError:
            scratch = 128
        size_mib = staged_mib + 16 + scratch
        return max(size_mib, 48)
    # Auto-size: staging bytes + 64 MiB ext4 metadata + 32 MiB future
    # apt-install scratch headroom. Floor at 96 MiB so an empty image
    # still has comfortable headroom for an apt cache.
    size_mib = staged_mib + 64 + 32
    if size_mib < 96:
        size_mib = 96
    return size_mib


def build_image(out_path: Path) -> Path:
    out_path = out_path.resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Stage under build/.rootfs-stage/ (project disk, NEVER /tmp tmpfs).
    stage_root = HERE / "build" / ".rootfs-stage"
    if stage_root.is_dir():
        shutil.rmtree(stage_root)
    stage_root.mkdir(parents=True)
    try:
        staging = stage_root / "rootfs"
        staging.mkdir(parents=True)
        live = os.environ.get("HAMNIX_ROOTFS_LIVE", "0") == "1"
        if live:
            _stage_directory_live(staging)
        else:
            _stage_directory(staging)

        staged_bytes = _du_bytes(staging)
        size_mib = _pick_size_mb(staged_bytes, live=live)
        print(f"[build_rootfs_img] staged {staged_bytes/(1<<20):.1f} MiB; "
              f"creating {size_mib} MiB ext4 image at {out_path}",
              flush=True)

        with open(out_path, "wb") as f:
            f.truncate(size_mib * (1 << 20))

        mkfs = "/sbin/mkfs.ext4"
        if not Path(mkfs).is_file():
            mkfs = shutil.which("mkfs.ext4")
            if mkfs is None:
                raise SystemExit("[build_rootfs_img] mkfs.ext4 not found "
                                 "in /sbin or PATH (apt install e2fsprogs)")
        # -O ^has_journal: read-mostly; saves space + boot time
        # -O ^huge_file:    don't need >2 TiB files
        # -O ^metadata_csum:fs/ext4.ad doesn't validate CRCs (yet)
        # -E packed_meta_blocks=1: compact metadata at the front
        # -m 0 (live only): the default 5% reserved-block pool is a root-
        #   only reserve that would make the ENTIRE scratch margin invisible
        #   to the regular-user live clients (weston-terminal/DE terminal run
        #   as uid 1001) — every non-root write would ENOSPC. The live image
        #   is a throwaway RAM root, so reserve nothing and hand the full
        #   free margin to non-root writers.
        cmd = [
            mkfs,
            "-F",
            "-L", "hamnix-rootfs",
            "-O", "^has_journal,^huge_file,^metadata_csum",
            "-E", "packed_meta_blocks=1",
        ]
        if live:
            cmd += ["-m", "0"]
        cmd += [
            "-d", str(staging),
            str(out_path),
        ]
        print(f"[build_rootfs_img] $ {' '.join(cmd)}", flush=True)
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.stdout:
            for line in result.stdout.splitlines()[:5]:
                print(f"  [mkfs] {line}", flush=True)
        if result.returncode != 0:
            print(result.stderr, file=sys.stderr)
            raise SystemExit(
                f"[build_rootfs_img] mkfs.ext4 failed rc={result.returncode}")
    finally:
        if os.environ.get("HAMNIX_KEEP_STAGE") != "1":
            shutil.rmtree(stage_root, ignore_errors=True)

    final_size = out_path.stat().st_size
    print(f"[build_rootfs_img] DONE: {out_path} ({final_size} bytes, "
          f"{final_size/(1<<20):.1f} MiB)", flush=True)
    return out_path


def main():
    out = Path(os.environ.get("HAMNIX_ROOTFS_OUT", str(OUT_DEFAULT)))
    build_image(out)


if __name__ == "__main__":
    main()
