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
    bb_applets = [
        "sh", "ash",
        "ls", "cat", "echo", "cp", "mv", "rm", "mkdir",
        "pwd", "grep", "head", "tail", "wc",
        "true", "false", "env", "printf", "date",
        "sleep", "basename", "dirname",
    ]
    for applet in bb_applets:
        link = bb_dir / applet
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to("busybox")
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
    minbase = HERE / "tests" / "distros" / "debian-minbase" / "rootfs"
    real_debian_raw = os.environ.get("HAMNIX_DEFAULT_REAL_DEBIAN", "1")
    if real_debian_raw in ("0", "", "off", "no"):
        print(f"[build_rootfs_img] HAMNIX_DEFAULT_REAL_DEBIAN={real_debian_raw}: "
              f"skipping real Debian closure", flush=True)
    elif not minbase.is_dir():
        print(f"[build_rootfs_img] WARN: {minbase.relative_to(HERE)} "
              f"absent — distro/ subtree will contain only busybox",
              flush=True)
    else:
        n, b = _stage_real_debian(distro, minbase)
        print(f"[build_rootfs_img] staged {n} Debian apt/dpkg files "
              f"({b/(1<<20):.1f} MiB) into distro/ from "
              f"{minbase.relative_to(HERE)}", flush=True)
    _stage_busybox(distro)

    # --- sysroot/ subtree: native Adder tools + /etc -----------------
    tn, tb = _stage_adder_tools(sysroot)
    print(f"[build_rootfs_img] staged {tn} Adder tools "
          f"({tb/(1<<20):.1f} MiB) into sysroot/bin/", flush=True)
    _stage_init_shim(sysroot)
    en = _stage_sysroot_etc(sysroot)
    print(f"[build_rootfs_img] staged {en} sysroot/etc files "
          f"(incl. rc.boot.full)", flush=True)

    _stage_hamnix_roots(staging)


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


def _pick_size_mb(staging_bytes: int) -> int:
    raw = os.environ.get("HAMNIX_ROOTFS_SIZE_MB", "").strip()
    if raw:
        try:
            return int(raw)
        except ValueError:
            raise SystemExit(
                f"HAMNIX_ROOTFS_SIZE_MB={raw!r}: must be an integer")
    # Auto-size: staging bytes + 64 MiB ext4 metadata + 32 MiB future
    # apt-install scratch headroom. Floor at 96 MiB so an empty image
    # still has comfortable headroom for an apt cache.
    staged_mib = (staging_bytes + (1 << 20) - 1) // (1 << 20)
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
        _stage_directory(staging)

        staged_bytes = _du_bytes(staging)
        size_mib = _pick_size_mb(staged_bytes)
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
        cmd = [
            mkfs,
            "-F",
            "-L", "hamnix-rootfs",
            "-O", "^has_journal,^huge_file,^metadata_csum",
            "-E", "packed_meta_blocks=1",
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
