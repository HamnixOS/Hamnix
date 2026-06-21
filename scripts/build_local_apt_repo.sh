#!/usr/bin/env bash
# scripts/build_local_apt_repo.sh
#
# Build a tiny OFFLINE `file://` apt repository inside the debian-minbase
# fixture so `apt-get install` (and `dpkg -i`) can be exercised WITHOUT a
# network inside `enter linux { ... }`.
#
# The Linux namespace has no routed network to deb.debian.org, so the only
# credible way to prove "apt installs a package" is a local repo served by
# apt's built-in `file` method off a path under the Debian root. This script
# stages, fully reproducibly:
#
#   <rootfs>/opt/localrepo/
#       pool/main/h/hamhello/hamhello_1.0_amd64.deb   the leaf .deb
#       dists/local/main/binary-amd64/Packages(.gz)    package index
#       dists/local/Release                            suite Release file
#   <rootfs>/etc/apt/sources.list.d/local.list         deb [trusted=yes] file:///opt/localrepo local main
#   <rootfs>/var/cache/apt/archives/hamhello_1.0_amd64.deb  copy for `dpkg -i`
#
# The package `hamhello` is a dependency-free leaf whose installed program
# /usr/bin/hamhello prints a UNIQUE marker (HAMHELLO_INSTALLED_AND_RAN_OK).
# A test asserts that marker AFTER an install, proving the install populated
# the live filesystem and the installed binary runs. It is a /bin/sh script
# (the Debian /bin/sh -> dash is staged into the namespace), so it needs no
# extra shared-object closure of its own.
#
# Idempotent: safe to re-run; it rebuilds the repo from scratch each time.
# Requires host tooling: dpkg-deb, gzip, and either apt-ftparchive or
# dpkg-scanpackages (both ship with dpkg-dev / apt on the build host).
#
# This is gitignored output (the whole rootfs/ tree is gitignored — it is a
# host-built debootstrap fixture), so committing this GENERATOR is how the
# local repo becomes reproducible on any host that has run BUILD.sh.

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$PROJ_ROOT/tests/distros/debian-minbase/rootfs}"

if [ ! -d "$ROOTFS" ]; then
    echo "[build_local_apt_repo] SKIP: $ROOTFS absent — run BUILD.sh first." >&2
    exit 0
fi

for tool in dpkg-deb gzip; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "[build_local_apt_repo] ERROR: missing host tool '$tool'." >&2
        exit 1
    }
done

REPO="$ROOTFS/opt/localrepo"
PKG=hamhello
VER=1.0
ARCH=amd64
MARKER="HAMHELLO_INSTALLED_AND_RAN_OK"

echo "[build_local_apt_repo] (1/5) Stage the .deb build tree"
WORK="$(mktemp -d /tmp/hamhello-deb.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/DEBIAN" "$WORK/usr/bin"

# The installed program: a /bin/sh leaf that prints the unique marker.
cat > "$WORK/usr/bin/$PKG" <<EOF
#!/bin/sh
echo $MARKER
EOF
chmod 0755 "$WORK/usr/bin/$PKG"

cat > "$WORK/DEBIAN/control" <<EOF
Package: $PKG
Version: $VER
Architecture: $ARCH
Maintainer: Hamnix <root@hamnix>
Section: misc
Priority: optional
Description: Hamnix offline apt-install proof package
 A dependency-free leaf package whose installed program prints a
 unique marker, used to prove apt-get install works from a local
 file:// repo inside the Linux namespace.
EOF

echo "[build_local_apt_repo] (2/5) dpkg-deb --build"
DEB="$WORK/${PKG}_${VER}_${ARCH}.deb"
# --root-owner-group keeps the tar members root:root without needing fakeroot.
dpkg-deb --root-owner-group --build "$WORK" "$DEB" >/dev/null

echo "[build_local_apt_repo] (3/5) Lay out pool/ + dists/"
rm -rf "$REPO"
POOLDIR="$REPO/pool/main/h/$PKG"
IDXDIR="$REPO/dists/local/main/binary-$ARCH"
mkdir -p "$POOLDIR" "$IDXDIR"
cp "$DEB" "$POOLDIR/${PKG}_${VER}_${ARCH}.deb"

echo "[build_local_apt_repo] (4/5) Generate Packages + Release indices"
# Generate the binary Packages index. Prefer apt-ftparchive; fall back to
# dpkg-scanpackages. Both emit a Filename: relative to the repo root.
(
    cd "$REPO"
    if command -v apt-ftparchive >/dev/null 2>&1; then
        apt-ftparchive packages pool > "$IDXDIR/Packages"
    elif command -v dpkg-scanpackages >/dev/null 2>&1; then
        dpkg-scanpackages --multiversion pool /dev/null > "$IDXDIR/Packages" 2>/dev/null
    else
        echo "[build_local_apt_repo] ERROR: need apt-ftparchive or dpkg-scanpackages." >&2
        exit 1
    fi
)
gzip -9 -c "$IDXDIR/Packages" > "$IDXDIR/Packages.gz"

# Minimal Release file for the `local` suite. apt with [trusted=yes] does not
# require a signature, but it DOES read the Release file to learn the suite's
# Components/Architectures and to checksum the Packages index.
gen_release() {
    cat <<EOF
Origin: Hamnix-Local
Label: Hamnix-Local
Suite: local
Codename: local
Architectures: $ARCH
Components: main
Description: Hamnix offline local apt repository
EOF
    # Emit MD5Sum + SHA256 sections over the index files (apt verifies the
    # Packages hash against Release even for trusted=yes repos).
    for algo in MD5Sum:md5sum SHA256:sha256sum; do
        label="${algo%%:*}"; cmd="${algo##*:}"
        echo "$label:"
        for f in main/binary-$ARCH/Packages main/binary-$ARCH/Packages.gz; do
            sz=$(stat -c%s "$REPO/dists/local/$f")
            sum=$($cmd "$REPO/dists/local/$f" | awk '{print $1}')
            printf ' %s %s %s\n' "$sum" "$sz" "$f"
        done
    done
}
gen_release > "$REPO/dists/local/Release"

echo "[build_local_apt_repo] (5/5) Wire apt sources + dpkg-i cache copy"
mkdir -p "$ROOTFS/etc/apt/sources.list.d"
cat > "$ROOTFS/etc/apt/sources.list.d/local.list" <<EOF
deb [trusted=yes] file:///opt/localrepo local main
EOF

# Also drop a copy where `dpkg -i` can find it directly (the shorter
# install fork chain: dpkg -> dpkg-deb -> tar -> gzip, no apt method).
mkdir -p "$ROOTFS/var/cache/apt/archives"
cp "$DEB" "$ROOTFS/var/cache/apt/archives/${PKG}_${VER}_${ARCH}.deb"

echo "[build_local_apt_repo] DONE: file:///opt/localrepo serves $PKG $VER"
echo "    repo:    $REPO"
echo "    sources: $ROOTFS/etc/apt/sources.list.d/local.list"
echo "    deb:     $ROOTFS/var/cache/apt/archives/${PKG}_${VER}_${ARCH}.deb"
echo "    marker:  $MARKER"
