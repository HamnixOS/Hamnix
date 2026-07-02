#!/usr/bin/env bash
# scripts/stage_weston_term.sh — host-side, one-time: stage the UNMODIFIED
# Debian `weston-terminal` (+ `weston-simple-shm`) and their REAL runtime
# shared-object closure + a usable monospace font into the debian-minbase
# fixture rootfs, so the full-mirror live image (HAMNIX_LIVE_MINIMAL=0)
# carries a real INTERACTIVE libwayland client for the Phase-4b input rung.
#
# weston-terminal is a pure-SHM cairo/pango client (NO GL) — its ldd
# closure is ~45 small libs (~6 MiB), NOT the ~900 MB mesa/LLVM/ffmpeg
# stack that the `weston` package DEPENDS on (libweston/GL). We compute
# weston-terminal's ACTUAL DT_NEEDED transitive closure and copy only
# that, keeping the ESP FAT under its ceiling.
#
# Requirements (Debian/Ubuntu host): apt-get download access to the
# Debian mirror + dpkg-deb + readelf. No sudo, no install into the host.
#
# Idempotent: safe to re-run; overwrites the staged files in place.
#
# Env:
#   ROOTFS  target rootfs (default: tests/distros/debian-minbase/rootfs)
#   WORK    scratch dir for .deb download/extract (default: mktemp)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$HERE/tests/distros/debian-minbase/rootfs}"
WORK="${WORK:-$(mktemp -d --tmpdir hamnix-weston.XXXXXX)}"

if [ ! -d "$ROOTFS" ]; then
    echo "[stage-weston] ERROR: $ROOTFS absent."
    echo "[stage-weston]   Run tests/distros/debian-minbase/BUILD.sh (or"
    echo "[stage-weston]   scripts/stage_host_dpkg_rootfs.sh) to populate it first."
    exit 1
fi

DEBS="$WORK/debs"; WSROOT="$WORK/wsroot"
mkdir -p "$DEBS" "$WSROOT"

# --- 1. download weston + weston-terminal's runtime closure packages ---
# Curated to weston-terminal's ACTUAL closure (readelf-walked below) — NO
# GL/EGL/mesa/gbm/drm/ffmpeg/pipewire (the heavy `weston` Depends set).
PKGS=(
  weston
  libwayland-client0 libwayland-cursor0
  libpixman-1-0 libxkbcommon0
  libcairo2 libcairo-gobject2 libpng16-16t64
  libpango-1.0-0 libpangocairo-1.0-0 libpangoft2-1.0-0
  libglib2.0-0t64 libfontconfig1 libfreetype6
  libjpeg62-turbo libwebp7 libffi8
  libxcb1 libxcb-shm0 libxcb-render0
  libx11-6 libx11-data libxrender1 libxext6 libxau6 libxdmcp6
  libexpat1 libbrotli1 libbz2-1.0 libpcre2-8-0 zlib1g
  libharfbuzz0b libfribidi0 libgraphite2-3 libthai0 libthai-data
  libdatrie1 libsharpyuv0 libselinux1 libblkid1 libmount1 libuuid1
  libatomic1
  fontconfig-config fonts-dejavu-core fonts-dejavu-mono
  xkb-data
)
echo "[stage-weston] downloading ${#PKGS[@]} packages into $DEBS ..."
( cd "$DEBS" && apt-get download "${PKGS[@]}" >/dev/null 2>&1 ) || {
    echo "[stage-weston] ERROR: apt-get download failed (need mirror access)."; exit 1; }

echo "[stage-weston] extracting .debs into merged staging tree ..."
for d in "$DEBS"/*.deb; do dpkg-deb -x "$d" "$WSROOT"; done

# --- 2. walk weston-terminal's transitive DT_NEEDED closure ------------
# Resolve each soname against the merged tree first, then the existing
# rootfs (libc/ld.so/libm already staged there). Copy only what resolves
# in the merged tree (host-fresh libs); rootfs-provided libs stay as-is.
python3 - "$WSROOT" "$ROOTFS" <<'PY'
import os, sys, subprocess, shutil
WSROOT, ROOTFS = sys.argv[1], sys.argv[2]
LIBDIRS = ["usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu",
           "usr/lib","lib","usr/lib64","lib64"]
BINS = ["usr/bin/weston-terminal","usr/bin/weston-simple-shm"]

def needed(p):
    try: out=subprocess.check_output(["readelf","-d",p],stderr=subprocess.DEVNULL).decode()
    except Exception: return []
    return [l.split("[")[1].split("]")[0] for l in out.splitlines()
            if "(NEEDED)" in l and "[" in l]

def find(soname):
    for tree in (WSROOT, ROOTFS):
        for d in LIBDIRS:
            c=os.path.join(tree,d,soname)
            if os.path.exists(c): return os.path.realpath(c), tree
    return None,None

seen=set(); work=[]; copied=0; missing=set()
for b in BINS:
    bp=os.path.join(WSROOT,b)
    if os.path.exists(bp): work += needed(bp)
while work:
    so=work.pop()
    if so in seen: continue
    seen.add(so)
    rp,tree=find(so)
    if rp is None: missing.add(so); continue
    if tree==WSROOT:
        # canonical usrmerge path so build_initramfs.py's glob catches it
        dst=os.path.join(ROOTFS,"usr/lib/x86_64-linux-gnu",so)
        os.makedirs(os.path.dirname(dst),exist_ok=True)
        shutil.copy2(rp,dst); copied+=1
        # mirror the /lib spelling too (belt + suspenders)
        dst2=os.path.join(ROOTFS,"lib/x86_64-linux-gnu",so)
        os.makedirs(os.path.dirname(dst2),exist_ok=True); shutil.copy2(rp,dst2)
    work += needed(rp)
# copy the two client binaries
for b in BINS:
    src=os.path.join(WSROOT,b)
    if os.path.exists(src):
        dst=os.path.join(ROOTFS,b)
        os.makedirs(os.path.dirname(dst),exist_ok=True)
        shutil.copy2(src,dst); os.chmod(dst,0o755)
print(f"[stage-weston] staged {copied} closure libs + {len(BINS)} client binaries")
if missing:
    print("[stage-weston] WARNING unresolved sonames:", sorted(missing))
    sys.exit(2)
PY

# --- 2b. glibc upgrade -------------------------------------------------
# The debootstrap base rootfs ships an OLDER glibc (bookworm 2.36) than the
# trixie weston-terminal closure requires (libX11/glib/harfbuzz/pango/expat
# reference GLIBC_2.38+). glibc is backward-compatible (newer libc runs the
# older apt/dpkg/bash binaries), and libc.so.6 + ld-linux must upgrade as a
# matched pair, so stage the HOST's complete glibc runtime over the rootfs
# copy. Covers libc/ld.so/libm/libpthread/libdl/librt/libresolv + the NSS
# modules glibc dlopen's at runtime.
echo "[stage-weston] upgrading rootfs glibc to host version (weston needs GLIBC_2.38+)"
for so in libc.so.6 libm.so.6 libmvec.so.1 libpthread.so.0 libdl.so.2 \
          librt.so.1 libresolv.so.2 libutil.so.1 libanl.so.1 \
          libnss_files.so.2 libnss_compat.so.2 libnss_dns.so.2 \
          libBrokenLocale.so.1; do
    src="/lib/x86_64-linux-gnu/$so"
    [ -e "$src" ] || src="/usr/lib/x86_64-linux-gnu/$so"
    [ -e "$src" ] || continue
    real="$(readlink -f "$src")"
    install -D -m0755 "$real" "$ROOTFS/usr/lib/x86_64-linux-gnu/$so"
    install -D -m0755 "$real" "$ROOTFS/lib/x86_64-linux-gnu/$so"
done
# Dynamic linker (PT_INTERP) — must match the upgraded libc exactly.
LDSO="$(readlink -f /lib64/ld-linux-x86-64.so.2)"
[ -e "$LDSO" ] || LDSO="$(readlink -f /usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2)"
install -D -m0755 "$LDSO" "$ROOTFS/usr/lib64/ld-linux-x86-64.so.2"
install -D -m0755 "$LDSO" "$ROOTFS/lib64/ld-linux-x86-64.so.2"
install -D -m0755 "$LDSO" "$ROOTFS/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"

# --- 3. font + fontconfig ----------------------------------------------
# DejaVu Sans Mono is weston-terminal's ideal monospace face. Stage the
# TTF + a minimal fontconfig conf so libfontconfig resolves "monospace"
# without the full doc/cache tooling. fonts under usr/share/fonts are NOT
# pruned by FULL_DEBIAN_PRUNE.
FONT_SRC="$WSROOT/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
if [ -f "$FONT_SRC" ]; then
    install -D -m0644 "$FONT_SRC" \
        "$ROOTFS/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
    # keep the sans face too (pango may fall back for the titlebar glyphs)
    for f in DejaVuSans.ttf; do
        s="$WSROOT/usr/share/fonts/truetype/dejavu/$f"
        [ -f "$s" ] && install -D -m0644 "$s" \
            "$ROOTFS/usr/share/fonts/truetype/dejavu/$f"
    done
    echo "[stage-weston] staged DejaVu TTF fonts"
else
    echo "[stage-weston] WARNING: DejaVuSansMono.ttf not found in fonts-dejavu-mono"
fi

# Minimal fontconfig: a <dir> for our TTF, a writable cache dir, and a
# generic monospace alias so weston-terminal's default face resolves.
#
# CACHEDIR ORDER MATTERS. fontconfig walks <cachedir> entries in order and
# needs at least ONE that (a) SHIPS a valid prebuilt cache so the first font
# use does NOT trigger a full font-dir scan (which HANGS under the Linux-ABI,
# see below), and (b) is WRITABLE at runtime, or FcInit warns "Fontconfig
# error: No writable cache directories" and weston-terminal aborts (exit 1)
# BEFORE it rasterizes a single glyph / attaches a render buffer. The earlier
# config listed ONLY /var/cache/fontconfig (no prebuilt cache, no writable
# dir) and had NO <cachedir prefix="xdg"> entry, so setting XDG_CACHE_HOME had
# no effect — the error persisted.
#
# CRUCIAL: build_rootfs_img.py's FULL_DEBIAN_PRUNE strips /run, /tmp AND
# /var/cache from the live image, so a prebuilt cache staged under either of
# those is DROPPED and never reaches the guest, and /run does not even exist
# at boot. Therefore the FIRST cachedir is /etc/fonts/cache — /etc is NOT
# pruned, so the prebuilt cache SHIPS, and the live root is a RAM-backed ext4
# so /etc/fonts/cache is also WRITABLE at runtime (fontconfig can refresh it).
# /run/fontconfig follows (the launch wrapper mkdir's it — `/` is writable so
# `mkdir -p /run/fontconfig` succeeds even though /run was pruned), then the
# xdg-prefixed dir (honours XDG_CACHE_HOME=/run/fontconfig), then
# /var/cache/fontconfig as a legacy fallback.
mkdir -p "$ROOTFS/etc/fonts/cache" "$ROOTFS/var/cache/fontconfig" \
         "$ROOTFS/run/fontconfig"
chmod 0777 "$ROOTFS/etc/fonts/cache" "$ROOTFS/run/fontconfig" 2>/dev/null || true
cat > "$ROOTFS/etc/fonts/fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>/usr/share/fonts</dir>
  <cachedir>/etc/fonts/cache</cachedir>
  <cachedir>/run/fontconfig</cachedir>
  <cachedir prefix="xdg">fontconfig</cachedir>
  <cachedir>/var/cache/fontconfig</cachedir>
  <alias><family>monospace</family><prefer><family>DejaVu Sans Mono</family></prefer></alias>
  <alias><family>sans-serif</family><prefer><family>DejaVu Sans</family></prefer></alias>
  <alias><family>serif</family><prefer><family>DejaVu Sans</family></prefer></alias>
  <config></config>
</fontconfig>
EOF

# PRE-BUILD the fontconfig cache into the rootfs. weston-terminal's FIRST
# font use (cairo_select_font_face in terminal_create) triggers FcInit ->
# a full font-dir SCAN (FcFreeTypeQuery on every TTF) + a cache WRITE guarded
# by fontconfig's file-locking. Under the Linux-ABI that build-and-lock path
# HANGS SILENTLY: the terminal maps its xdg_toplevel but never reaches the
# forkpty/first-render, so no shm buffer is ever committed. Priming the cache
# on the host (same libfontconfig version staged into the rootfs, so the
# cache-format version matches) with --sysroot keys the cache to the GUEST-
# absolute font paths and lets the in-guest fontconfig hit a ready cache
# instead of scanning+writing. Best-effort: a missing host fc-cache just
# falls back to the (hanging) runtime build, so warn loudly.
if command -v fc-cache >/dev/null 2>&1; then
    rm -f "$ROOTFS/etc/fonts/cache"/*.cache-* \
          "$ROOTFS/run/fontconfig"/*.cache-* \
          "$ROOTFS/var/cache/fontconfig"/*.cache-* 2>/dev/null || true
    # fc-cache --sysroot writes to the FIRST writable <cachedir> in the
    # staged fonts.conf = /etc/fonts/cache (which SHIPS; /run + /var/cache are
    # pruned from the live image). The cache is keyed to the GUEST-absolute
    # font paths (/usr/share/fonts/...).
    fc-cache --sysroot="$ROOTFS" -f >/dev/null 2>&1 || true
    # Belt + suspenders: mirror the primed cache into the other cachedirs too
    # (harmless — /run + /var/cache are pruned at image-build, but keeping the
    # copies makes a direct rootfs boot / a future un-pruned build work too).
    PRIMED_DIR=""
    for d in "$ROOTFS/etc/fonts/cache" "$ROOTFS/run/fontconfig" "$ROOTFS/var/cache/fontconfig"; do
        if ls "$d"/*.cache-* >/dev/null 2>&1; then PRIMED_DIR="$d"; break; fi
    done
    if [ -n "$PRIMED_DIR" ]; then
        for d in "$ROOTFS/etc/fonts/cache" "$ROOTFS/run/fontconfig" "$ROOTFS/var/cache/fontconfig"; do
            [ "$d" = "$PRIMED_DIR" ] && continue
            cp -f "$PRIMED_DIR"/*.cache-* "$d/" 2>/dev/null || true
        done
        echo "[stage-weston] primed fontconfig cache ($(ls "$PRIMED_DIR"/*.cache-* | wc -l) files from $PRIMED_DIR; mirrored to all cachedirs)"
    else
        echo "[stage-weston] WARNING: fc-cache produced no cache — runtime font"
        echo "[stage-weston]   scan may HANG weston-terminal before it renders."
    fi
else
    echo "[stage-weston] WARNING: host fc-cache absent — cannot prime fontconfig"
    echo "[stage-weston]   cache; weston-terminal may HANG in font setup at runtime."
fi

# --- 3b. XKB keymap data ----------------------------------------------
# libxkbcommon's xkb_context_new adds /usr/share/X11/xkb as its default
# include path and FAILS (returns NULL) if it is absent — weston-terminal's
# display_create() then returns NULL and main() reports it (confusingly) as
# "failed to create display: No such file or directory" (errno=ENOENT from
# the missing include dir). The client compiles the SERVER-sent keymap fd
# with this data, so keyboard input needs it. /usr/share/X11 is NOT pruned.
if [ -d "$WSROOT/usr/share/X11/xkb" ]; then
    cp -a "$WSROOT/usr/share/X11" "$ROOTFS/usr/share/"
    echo "[stage-weston] staged xkb-data (/usr/share/X11/xkb)"
else
    echo "[stage-weston] WARNING: xkb-data not found (weston-terminal XKB will fail)"
fi

# weston-terminal draws its OWN client-side window decorations (titlebar +
# min/max/close buttons) via toytoolkit's frame_create(), which loads button
# icon PNGs from $DATADIR/weston/ (compiled DATADIR=/usr/share) with
# cairo_image_surface_create_from_png(). If those PNGs are absent,
# frame_button_create() returns NULL -> frame_create() returns NULL ->
# window_frame_create() returns NULL -> terminal->widget = NULL ->
# widget_set_transparent(terminal->widget, 0) DEREFS NULL and the client
# SIGSEGVs (write to NULL+0x138) in terminal_create(), BEFORE it ever maps a
# window (display_run never runs, so the queued xdg_surface/toplevel/commit
# requests are never flushed to the server). Stage the decoration icon set
# (icon_window/sign_close/sign_maximize/sign_minimize + the rest of the small
# UI PNGs) so the frame builds and the terminal maps + renders.
if [ -d "$WSROOT/usr/share/weston" ]; then
    mkdir -p "$ROOTFS/usr/share/weston"
    # Copy only the small UI PNGs the decoration path needs; skip the large
    # background/wallpaper assets (background.png ~132 KiB etc.) to keep the
    # ESP FAT under its ceiling. The decoration icons are all < 4 KiB.
    for p in icon_window sign_close sign_maximize sign_minimize \
             icon_terminal terminal home; do
        s="$WSROOT/usr/share/weston/$p.png"
        [ -f "$s" ] && install -D -m0644 "$s" "$ROOTFS/usr/share/weston/$p.png"
    done
    echo "[stage-weston] staged weston decoration icons (/usr/share/weston/*.png)"
else
    echo "[stage-weston] WARNING: /usr/share/weston not found — client-side"
    echo "[stage-weston]   decorations will fail and weston-terminal will SIGSEGV."
fi

echo "[stage-weston] DONE. rootfs now carries weston-terminal + closure + fonts."
echo "[stage-weston]   verify: readelf -d $ROOTFS/usr/bin/weston-terminal | grep NEEDED"
echo "[stage-weston] Next: HAMNIX_LIVE_MINIMAL=0 bash scripts/build_installer_img.sh"
[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"
