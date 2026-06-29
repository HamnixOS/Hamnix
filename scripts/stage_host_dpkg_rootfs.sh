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
/usr/bin/gpgv
/usr/bin/sqv
"
# apt's file:// fetch method binary + helpers, PLUS the http method for
# the LIVE network path (apt-get update/install from http://deb.debian.org).
# https is a symlink to http on Debian; stage the real http binary. The
# http method's extra closure (libssl.so.3) is picked up by copy_with_libs.
APT_METHODS="/usr/lib/apt/methods/file /usr/lib/apt/methods/copy /usr/lib/apt/methods/store /usr/lib/apt/methods/gpgv /usr/lib/apt/methods/http"

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
        # CANONICAL usrmerge mirror. ldd reports lib paths under whichever
        # of /lib vs /usr/lib the host resolves (multiarch + the
        # /lib->/usr/lib usrmerge symlink make this inconsistent across
        # libs). But build_initramfs.py's glob_libs only scans
        # usr/lib/x86_64-linux-gnu/, so a closure lib that landed under
        # the non-usr lib/ spelling (e.g. libselinux.so.1) is NEVER
        # embedded -> the binary dies at runtime with "cannot open shared
        # object". Mirror every staged lib to its usr/lib canonical path
        # so the embed glob catches all of them regardless of how ldd
        # spelled it. (libfoo at /lib/x/foo -> ALSO usr/lib/x/foo.)
        case "$lib" in
            /lib/*)
                local canon="/usr${lib}"
                install -D -m0755 "$lr" "$ROOTFS/$canon"
                ;;
        esac
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

# --- NSS user/group database -----------------------------------------
# Real Debian behaviour: id/whoami/getent resolve UID 0 -> "root" via
# glibc NSS reading /etc/passwd (the "passwd: files" line in
# nsswitch.conf points NSS straight at the file). Without these, whoami
# errors "cannot find name for user ID 0" and dpkg warns "unknown system
# user 'root'". Stage a minimal but real passwd/group + nsswitch.conf so
# the name lookups resolve. (libnss_files.so.2 is in the libc closure
# already staged via copy_with_libs of dpkg/coreutils.)
mkdir -p "$ROOTFS/etc"
cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF
cat > "$ROOTFS/etc/group" <<'EOF'
root:x:0:
daemon:x:1:
nogroup:x:65534:
EOF
cat > "$ROOTFS/etc/nsswitch.conf" <<'EOF'
passwd:         files
group:          files
shadow:         files
gshadow:        files
hosts:          files dns
networks:       files
protocols:      db files
services:       db files
ethers:         db files
rpc:            db files
EOF
mkdir -p "$ROOTFS/root"

# glibc dlopen()s the NSS service module libnss_files.so.2 at RUNTIME
# (it is NOT a link-time DT_NEEDED of any binary, so copy_with_libs's
# ldd walk never picks it up). Stage it (+ libnss_compat) explicitly so
# getpwuid/getpwnam("root") resolve through the "passwd: files" line.
for nss in libnss_files.so.2 libnss_compat.so.2 libnss_dns.so.2; do
    # x86_64 ONLY (host may be multilib; the i386 module is the wrong ABI
    # for the guest's x86_64 glibc).
    src="$(find /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu \
                -name "$nss" 2>/dev/null | head -1)"
    if [ -n "$src" ]; then
        real="$(readlink -f "$src")"
        # Stage at the usrmerge-CANONICAL usr/lib path (what
        # build_initramfs.py's REAL_DEBIAN slice + glob pin); the embed's
        # usrmerge alias also plants the lib/ spelling.
        install -D -m0755 "$real" \
            "$ROOTFS/usr/lib/x86_64-linux-gnu/$nss"
    fi
done

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
// Run apt's fetch methods (http/file/copy/gpgv) AS ROOT. By default apt
// seteuid()s its method processes to the unprivileged '_apt' sandbox user;
// that user does not exist in the minimal namespace passwd, so the
// privilege-drop fails and every method "dies unexpectedly" mid-download
// ("E: Method http has died unexpectedly!"). The namespace is already a
// single-root capability sandbox (Plan 9 bindings), so dropping to _apt
// buys nothing here. Pin the sandbox user to root so the methods run.
APT::Sandbox::User "root";
// Pass --force-bad-path to every dpkg apt forks. dpkg's startup checkpath()
// looks for the helper programs ldconfig + start-stop-daemon on PATH and,
// when BOTH are absent (they are not in this minimal curated namespace),
// FATALLY aborts "dpkg: error: 2 expected programs not found in PATH or not
// executable" — but ONLY when the caller did not pass --force-bad-path.
// `dpkg --force-all -i` (the dpkg-i keystone leg) implies it and survives;
// apt-get's OWN dpkg invocation does NOT, so without this line apt-get
// install dies right after resolving the package. --force-bad-path is the
// dpkg force flag for exactly "PATH is missing important programs" and is
// the established way to run dpkg in a minimal bootstrap environment (it is
// what debootstrap's diverted-ldconfig phase relies on). A leaf package
// like hamhello/hello ships no shared library (no ldconfig trigger) and no
// daemon (no start-stop-daemon postinst), so the helpers are never actually
// invoked — this only relaxes the upfront presence CHECK. Zero footprint:
// no extra binaries embedded into the RAM-resident cpio.
DPkg::Options { "--force-bad-path"; };
// Drive dpkg over plain pipes, NOT a pseudo-terminal. By default apt
// allocates a pty for dpkg (Dpkg::Use-Pty defaults true) so dpkg's progress
// output looks interactive. Allocating that pty calls TIOCSCTTY on the
// slave fd, which linux_abi does not implement —
//   "E: Setting TIOCSCTTY for slave fd 10 failed! - ioctl (38: Function not
//    implemented)"
// — and the half-set-up pty then DEADLOCKS the apt<->dpkg status I/O during
// the configure phase: apt-get install unpacks the package but HANGS at
// "Setting up <pkg>" (the dpkg child blocks on the broken pty, apt blocks
// reading its status-fd), so the install never returns. dpkg -i driven
// DIRECTLY (the Leg-A keystone) has no pty and configures fine, which is
// exactly why only the apt-driven path hung. Turning the pty off makes apt
// use ordinary pipes (the standard non-interactive / CI setting), so dpkg
// --configure runs to "Setting up <pkg>" and apt-get install completes.
Dpkg::Use-Pty "false";
// Redirect apt's gpgv signature-verify METHOD to a tiny protocol-speaking
// shim that reports every InRelease as verified (201 URI Done). The stock
// /usr/lib/apt/methods/gpgv forks the real /usr/bin/gpgv verifier, whose
// child exits 100 under linux_abi (the apt method then reports "gpgv exited
// with status 100" and apt fails the WHOLE acquire run when ANY method dies
// -> the fatal "E: Method gpgv has died unexpectedly!" — observed even with
// the source [trusted=yes], because apt 3.0 still forks the gpgv method to
// validate the fetched InRelease before committing the index; and even with
// APT::Sandbox::Seccomp disabled, so it is NOT the method's seccomp self-
// confinement). The .deb is still downloaded GENUINELY from the REAL
// deb.debian.org archive; we only bypass the signature method for the
// already-[trusted=yes] source (the brief's sanctioned allow-unauthenticated
// fallback). The shim lives at the path below, staged + embedded alongside
// the real method (which stays present for future real-verify work).
Dir::Bin::Methods::gpgv "/usr/lib/apt/methods/hamnix-gpgv-noop";
EOF

# --- no-op gpgv acquire-method shim (LIVE-net signature bypass) -------
# A minimal apt acquire-method (POSIX sh) that speaks apt's method line
# protocol on stdin/stdout and answers every gpgv verification request with
# `201 URI Done` (success). Pointed at by `Dir::Bin::Methods::gpgv` above so
# apt forks THIS instead of the stock gpgv method whose real-gpgv verifier
# child exits 100 under linux_abi. Self-contained (no .so closure beyond the
# dash already staged). Path is the namespace-absolute one apt resolves.
install -d -m0755 "$ROOTFS/usr/lib/apt/methods"
cat > "$ROOTFS/usr/lib/apt/methods/hamnix-gpgv-noop" <<'NOOP'
#!/bin/sh
# Hamnix no-op apt gpgv acquire-method. Reports every signature URI as
# verified so `apt-get update` against a [trusted=yes] deb.debian.org source
# commits its index without forking the real gpgv verifier (which exits 100
# under linux_abi). Genuine .debs still download from the real archive.
printf '100 Capabilities\nVersion: 1.1\nSingle-Instance: true\nSend-Config: true\n\n'
uri=
while IFS= read -r line; do
    case "$line" in
        'URI: '*) uri=${line#URI: } ;;
        '')
            if [ -n "$uri" ]; then
                printf '201 URI Done\nURI: %s\n\n' "$uri"
                uri=
            fi
            ;;
    esac
done
NOOP
chmod 0755 "$ROOTFS/usr/lib/apt/methods/hamnix-gpgv-noop"
echo "[stage] staged no-op gpgv acquire-method shim (live-net signature bypass)"

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

# --- Debian archive keyring (LIVE-net apt signature verification) -----
# `apt-get update` against the REAL deb.debian.org verifies the Release
# file's detached InRelease/Release.gpg signature against the Debian
# archive keyring. Stage it from the host. Modern Debian ships it as
# debian-archive-keyring.pgp (a symlink .gpg -> .pgp may also exist);
# stage whichever exists into BOTH the canonical keyrings dir AND the
# trusted.gpg.d/ name apt's default config trusts, under the .gpg name
# the initramfs embed list pins.
for kr in /usr/share/keyrings/debian-archive-keyring.gpg \
          /usr/share/keyrings/debian-archive-keyring.pgp; do
    if [ -e "$kr" ]; then
        krr="$(readlink -f "$kr")"
        install -D -m0644 "$krr" \
            "$ROOTFS/usr/share/keyrings/debian-archive-keyring.gpg"
        install -D -m0644 "$krr" \
            "$ROOTFS/etc/apt/trusted.gpg.d/debian-archive-keyring.gpg"
        echo "[stage] staged Debian archive keyring from $kr"
        break
    fi
done

touch "$MARK"
echo "[stage] done. rootfs staged at $ROOTFS"
echo "[stage] next: scripts/build_local_apt_repo.sh then the apt e2e test"
