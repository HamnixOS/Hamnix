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
/usr/bin/rm
/usr/bin/tar
/usr/bin/gzip
/usr/bin/cat
/usr/bin/sh
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
    # closure
    ldd "$real" 2>/dev/null | awk '/=>/ {print $3} /ld-linux/ {print $1}' \
      | grep -E '^/' | sort -u | while read -r lib; do
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
for b in $BINS $APT_METHODS; do copy_with_libs "$b"; done

# /lib64/ld-linux-x86-64.so.2 canonical name (PT_INTERP path).
LDSO="$(readlink -f /lib64/ld-linux-x86-64.so.2)"
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
  "$ROOTFS/etc/dpkg/dpkg.cfg.d" \
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

# os markers
echo "trixie/sid" > "$ROOTFS/etc/debian_version"

touch "$MARK"
echo "[stage] done. rootfs staged at $ROOTFS"
echo "[stage] next: scripts/build_local_apt_repo.sh then the apt e2e test"
