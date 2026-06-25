#!/usr/bin/env bash
# scripts/stage_host_dpkg_rootfs.sh
#
# Populate tests/distros/debian-minbase/rootfs/ with a MINIMAL but REAL
# dpkg/apt closure copied from the (Debian/Ubuntu) HOST, as a fast
# substitute for a full `debootstrap` (BUILD.sh) when the host has no
# network / sudo. Enough to exercise `dpkg -i` + `apt-get install` of the
# dependency-free `hamhello` local package inside `enter linux { ... }`.
#
# This is a DEV/CI convenience for reproducing the apt-install e2e path;
# it copies host-owned GPL/LGPL binaries into a gitignored tree (same as
# BUILD.sh), so nothing here is committed except this generator.
#
# Idempotent: refuses to clobber a debootstrap-built rootfs (presence of
# /etc/debian_version that we did NOT write). Safe to re-run otherwise.
set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$PROJ_ROOT/tests/distros/debian-minbase/rootfs}"
MARK="$ROOTFS/.staged-from-host"

mkdir -p "$ROOTFS"
if [ -f "$ROOTFS/etc/debian_version" ] && [ ! -f "$MARK" ]; then
    echo "[stage] $ROOTFS looks debootstrap-built; refusing to clobber." >&2
    exit 0
fi

# --- binaries we need at runtime -------------------------------------
BINS="
/usr/bin/dpkg
/usr/bin/dpkg-deb
/usr/bin/dpkg-split
/usr/bin/dpkg-query
/usr/bin/apt-get
/usr/bin/apt
/usr/bin/dash
/usr/bin/bash
/usr/bin/rm
/usr/bin/tar
/usr/bin/gzip
/usr/bin/gunzip
/usr/bin/cat
/usr/bin/sh
/usr/bin/ls
/usr/bin/cp
/usr/bin/mv
/usr/bin/mkdir
/usr/bin/rmdir
/usr/bin/chmod
/usr/bin/ln
/usr/bin/head
/usr/bin/tail
/usr/bin/wc
/usr/bin/sort
/usr/bin/uniq
/usr/bin/cut
/usr/bin/tr
/usr/bin/env
/usr/bin/printf
/usr/bin/echo
/usr/bin/date
/usr/bin/stat
/usr/bin/du
/usr/bin/df
/usr/bin/id
/usr/bin/whoami
/usr/bin/pwd
/usr/bin/basename
/usr/bin/dirname
/usr/bin/seq
/usr/bin/grep
/usr/bin/sed
/usr/bin/find
/usr/bin/xargs
/usr/bin/diff
/usr/bin/comm
/usr/bin/touch
/usr/bin/true
/usr/bin/false
/usr/bin/yes
/usr/bin/expr
/usr/bin/readlink
/usr/bin/realpath
/usr/bin/md5sum
/usr/bin/sha256sum
/usr/bin/od
/usr/bin/nl
/usr/bin/tee
/usr/bin/sleep
/usr/bin/uname
"
# Optional / larger binaries — staged best-effort if present on host.
# Missing ones are skipped silently by copy_with_libs so the matrix
# simply records them absent (no host gawk/perl/python3/xz != failure).
OPT_BINS="
/usr/bin/awk
/usr/bin/gawk
/usr/bin/mawk
/usr/bin/perl
/usr/bin/python3
/usr/bin/xz
/usr/bin/unxz
/usr/bin/bzip2
/usr/bin/zcat
"
# apt's file:// fetch method binary + helpers
APT_METHODS="/usr/lib/apt/methods/file /usr/lib/apt/methods/copy /usr/lib/apt/methods/store /usr/lib/apt/methods/gpgv"

copy_with_libs() {
    # Copy a binary plus its full shared-object closure into $ROOTFS,
    # preserving the host's absolute paths so the embedded ld.so finds
    # everything without LD_LIBRARY_PATH.
    local f="$1"
    [ -e "$f" ] || { echo "[stage]   skip missing $f"; return 0; }
    local real; real="$(readlink -f "$f")"
    install -D -m0755 "$real" "$ROOTFS/$f"
    # closure. Some tools (gunzip/zcat/bunzip2) are SHELL SCRIPTS, not
    # ELFs — `ldd` on them exits non-zero and the closure grep matches
    # nothing. Guard the whole pipeline (|| true) so a script-shaped
    # tool doesn't abort the run under `set -euo pipefail`.
    local libs
    libs="$(ldd "$real" 2>/dev/null | awk '/=>/ {print $3} /ld-linux/ {print $1}' \
            | grep -E '^/' | sort -u || true)"
    local lib
    for lib in $libs; do
        [ -e "$lib" ] || continue
        local lr; lr="$(readlink -f "$lib")"
        install -D -m0755 "$lr" "$ROOTFS/$lib"
        # also reproduce the symlink name if it differs (e.g. libc.so.6)
        if [ "$lib" != "$lr" ]; then
            install -D -m0755 "$lr" "$ROOTFS/$lib"
        fi
    done
}

echo "[stage] copying binaries + library closures into $ROOTFS"
for b in $BINS $OPT_BINS $APT_METHODS; do copy_with_libs "$b"; done

# Dynamic linker (PT_INTERP path). Stage at BOTH the usrmerge canonical
# usr/lib64/ (what build_initramfs.py's REAL_DEBIAN slice pins + aliases)
# AND the non-usr lib64/ spelling, so whichever path the embed/glob picks
# up resolves to real ld.so bytes.
LDSO="$(readlink -f /lib64/ld-linux-x86-64.so.2)"
install -D -m0755 "$LDSO" "$ROOTFS/usr/lib64/ld-linux-x86-64.so.2"
install -D -m0755 "$LDSO" "$ROOTFS/lib64/ld-linux-x86-64.so.2"

# /bin/sh -> dash (Debian default); dpkg maintainer scripts use /bin/sh.
mkdir -p "$ROOTFS/bin"
ln -sf /usr/bin/dash "$ROOTFS/bin/sh"   2>/dev/null || true
ln -sf dash          "$ROOTFS/bin/dash" 2>/dev/null || true

# --- dpkg + apt admin skeleton ---------------------------------------
mkdir -p \
  "$ROOTFS/var/lib/dpkg/info" \
  "$ROOTFS/var/lib/dpkg/updates" \
  "$ROOTFS/var/lib/dpkg/triggers" \
  "$ROOTFS/var/cache/apt/archives/partial" \
  "$ROOTFS/var/lib/apt/lists/partial" \
  "$ROOTFS/etc/apt/sources.list.d" \
  "$ROOTFS/etc/apt/preferences.d" \
  "$ROOTFS/etc/apt/apt.conf.d" \
  "$ROOTFS/etc/dpkg/dpkg.cfg.d" \
  "$ROOTFS/usr/share/dpkg" \
  "$ROOTFS/usr/bin" "$ROOTFS/usr/sbin" "$ROOTFS/sbin" \
  "$ROOTFS/tmp" "$ROOTFS/run"

: > "$ROOTFS/var/lib/dpkg/status"
: > "$ROOTFS/var/lib/dpkg/available"
echo "0" > "$ROOTFS/var/lib/dpkg/info/format" 2>/dev/null || true

# dpkg triggers admin files it expects to exist.
: > "$ROOTFS/var/lib/dpkg/triggers/File"
: > "$ROOTFS/var/lib/dpkg/triggers/Unincorp"

# arch so dpkg --print-architecture works.
mkdir -p "$ROOTFS/var/lib/dpkg"
echo "amd64" > "$ROOTFS/var/lib/dpkg/arch"

# --- dpkg architecture tables (libapt reads these DIRECTLY) -----------
# apt-get does NOT learn the arch only from `dpkg --print-architecture`;
# libapt-pkg ALSO opens /usr/share/dpkg/{cputable,tupletable,
# triplettable,...} itself to build its multiarch/CPU table. With those
# absent, apt prints "Error reading the CPU table" and refuses to
# resolve any package (the arch list comes out empty), so EVERY
# `apt-get install` aborts before it ever fetches from the repo. Stage
# the full set of *table data files from the host's dpkg-dev/dpkg data
# dir. (triplettable is the legacy name; modern dpkg ships tupletable —
# copy whichever exist so old + new libapt are both satisfied.)
echo "[stage] copying /usr/share/dpkg/*table (apt CPU/arch tables)"
for t in cputable tupletable triplettable ostable abitable; do
    src="/usr/share/dpkg/$t"
    [ -f "$src" ] && install -D -m0644 "$src" "$ROOTFS/usr/share/dpkg/$t"
done
# Some libapt versions look for triplettable specifically; if the host
# only ships the newer tupletable, mirror it under the legacy name so
# the triplettable->tupletable fallback can't miss either way.
if [ ! -f "$ROOTFS/usr/share/dpkg/triplettable" ] \
   && [ -f "$ROOTFS/usr/share/dpkg/tupletable" ]; then
    cp "$ROOTFS/usr/share/dpkg/tupletable" \
       "$ROOTFS/usr/share/dpkg/triplettable"
fi

# --- apt config dir --------------------------------------------------
# apt opendir()s /etc/apt/apt.conf.d/ at startup and warns
# "Unable to read /etc/apt/apt.conf.d/ ..." when the directory is
# missing. The directory is created above; drop one inert .conf so the
# dir is non-empty and to pin the namespace arch to amd64 (belt-and-
# braces with the cputable + /var/lib/dpkg/arch above).
cat > "$ROOTFS/etc/apt/apt.conf.d/00hamnix" <<'EOF'
APT::Architecture "amd64";
APT::Architectures "amd64";
// Offline local repo: it is [trusted=yes] but has no signature, so let
// apt-get install/update proceed unauthenticated WITHOUT needing the
// long `-o Acquire::AllowInsecureRepositories=true ...` flags on the
// command line (keeps the driven `enter linux { apt-get install ... }`
// line SHORT — hamsh's line editor echoes ~1 char per readline tick).
Acquire::AllowInsecureRepositories "true";
APT::Get::AllowUnauthenticated "true";
EOF

# os markers. debian_version starts with "12." so the coverage sweep's
# `cat /etc/debian_version` -> "12." assertion passes regardless of the
# build host's own /etc/debian_version (this is the NAMESPACE's distro
# marker, not the host's).
echo "12.5" > "$ROOTFS/etc/debian_version"

# /etc/os-release — a real multi-line Debian marker file the coverage
# sweep reads with head/wc/sort. Stage a canonical Debian one (the host
# copy if present, else a minimal hand-written one). Both contain the
# token "Debian" and "BUG_REPORT_URL" the sweep asserts on.
if [ -f /etc/os-release ] && grep -qi debian /etc/os-release; then
    install -D -m0644 /etc/os-release "$ROOTFS/etc/os-release"
else
    cat > "$ROOTFS/etc/os-release" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION="12 (bookworm)"
VERSION_CODENAME=bookworm
ID=debian
HOME_URL="https://www.debian.org/"
SUPPORT_URL="https://www.debian.org/support"
BUG_REPORT_URL="https://bugs.debian.org/"
EOF
fi

touch "$MARK"
echo "[stage] done. rootfs staged at $ROOTFS"
echo "[stage] next: scripts/build_local_apt_repo.sh then the apt e2e test"
