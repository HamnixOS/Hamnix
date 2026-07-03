#!/usr/bin/env bash
# scripts/stage_xwayland.sh — host-side, one-time: stage the UNMODIFIED
# Debian `Xwayland` X server (the `xwayland` package, /usr/bin/Xwayland) +
# its REAL runtime shared-object closure + a couple of tiny GL-free X11
# clients (xdpyinfo/xset for a display-liveness probe; xeyes/xclock for a
# rendered window) + the X core fonts the server needs, into the
# debian-minbase fixture rootfs. The full-mirror live image
# (HAMNIX_LIVE_MINIMAL=0) then carries a real X server that is itself a
# libwayland CLIENT of the native in-kernel Wayland compositor — the
# "one server protocol -> both Wayland AND X11 apps" (design-doc Phase 4)
# bridge, and the runway to Firefox-under-XWayland.
#
# Xwayland renders X client damage into wl_shm buffers with pixman
# (SOFTWARE — no GPU). It DT_NEEDED-links libGL/libgbm/libepoxy/libdrm
# (glamor acceleration), but those are the vendor-neutral libglvnd stubs:
# the heavy mesa swrast_dri/LLVM backend is dlopen'd LAZILY only when
# glamor is used, and Xwayland falls back to the pixman shm path when no
# DRM render node exists (Hamnix has none). So the closure is ~10 MiB of
# small libs, NOT the ~900 MB mesa/LLVM stack — we readelf-walk Xwayland's
# ACTUAL DT_NEEDED transitive closure and copy only that (ESP FAT ceiling).
#
# Run scripts/stage_weston_term.sh FIRST (or ensure the rootfs already
# carries the weston closure): this script REUSES the glibc upgrade, the
# xkb-data (/usr/share/X11/xkb) and the fontconfig cache that script
# stages, and only adds the X-specific delta.
#
# Requirements (Debian/Ubuntu host): apt-get download access to the Debian
# mirror + dpkg-deb + readelf. No sudo, no install into the host.
#
# Idempotent: safe to re-run; overwrites the staged files in place.
#
# Env:
#   ROOTFS  target rootfs (default: tests/distros/debian-minbase/rootfs)
#   WORK    scratch dir for .deb download/extract (default: mktemp)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$HERE/tests/distros/debian-minbase/rootfs}"
WORK="${WORK:-$(mktemp -d --tmpdir hamnix-xwayland.XXXXXX)}"

if [ ! -d "$ROOTFS" ]; then
    echo "[stage-xwl] ERROR: $ROOTFS absent."
    echo "[stage-xwl]   Populate it (BUILD.sh / stage_host_dpkg_rootfs.sh) and"
    echo "[stage-xwl]   run scripts/stage_weston_term.sh first."
    exit 1
fi

DEBS="$WORK/debs"; XWROOT="$WORK/xwroot"
mkdir -p "$DEBS" "$XWROOT"

# --- 1. download Xwayland + its runtime closure + GL-free X11 clients ---
# Curated to the readelf-walked closure of Xwayland + xdpyinfo/xset +
# xeyes/xclock. libgl1/libgbm1/libepoxy0/libdrm2 are the libglvnd/mesa
# FRONT stubs (see header); their heavy backends are dlopen'd lazily and
# never triggered on the shm software path. xfonts-base ships the X core
# 'fixed'/'cursor' fonts the server opens at startup (FatalError without
# them). x11-xkb-utils ships xkbcomp (Xwayland forks it to build keymaps;
# a warning without it, but cheap to include).
PKGS=(
  xwayland xserver-common
  x11-utils x11-apps x11-xkb-utils
  xfonts-base xfonts-encodings
  # --- Xwayland DT_NEEDED closure (front stubs; mesa backend stays lazy) --
  libgl1 libglx0 libglvnd0 libgbm1 libepoxy0 libdrm2
  libxshmfence1 libxcvt0 libxfont2 libfontenc1
  libtirpc3t64 libgcrypt20 libgpg-error0 libdecor-0-0
  # libtirpc pulls in GSS-API (RPC auth) -> Xwayland DT_NEEDED-links
  # libgssapi_krb5.so.2 transitively; without its krb5 closure Xwayland's
  # ld.so aborts "error while loading shared libraries: libgssapi_krb5.so.2"
  # (exit 127) before it ever connects to the Wayland server.
  libgssapi-krb5-2 libkrb5-3 libk5crypto3 libcom-err2 libkrb5support0 libkeyutils1
  libwayland-client0 libwayland-server0 libpixman-1-0
  # --- X protocol / toolkit libs (clients) --------------------------------
  libx11-6 libx11-xcb1 libxcb1 libxext6 libxtst6 libxi6 libxrender1
  libxcomposite1 libxinerama1 libxxf86vm1 libxxf86dga1 libxfixes3
  libxcb-present0 libxcb-xfixes0 libxcb-damage0 libxcb-shm0 libxcb-render0
  libxcb-sync1 libxcb-randr0 libxcb-shape0 libxcb-glx0
  libxmu6 libxmuu1 libxt6t64 libxaw7 libxft2 libxpm4 libxkbfile1
  libsm6 libice6 libxcursor1 libxrandr2
  libxau6 libxdmcp6 libbsd0 libmd0
  libfontconfig1 libfreetype6 libexpat1 libuuid1 libbz2-1.0 libpng16-16t64
  libbrotli1 zlib1g
)
echo "[stage-xwl] downloading ${#PKGS[@]} packages into $DEBS ..."
( cd "$DEBS" && apt-get download "${PKGS[@]}" >/dev/null 2>&1 ) || {
    echo "[stage-xwl] ERROR: apt-get download failed (need mirror access)."; exit 1; }

echo "[stage-xwl] extracting .debs into merged staging tree ..."
for d in "$DEBS"/*.deb; do dpkg-deb -x "$d" "$XWROOT"; done

# --- 2. walk the transitive DT_NEEDED closure --------------------------
# Resolve each soname against the merged staging tree first, then the
# existing rootfs (libc/ld.so + the weston closure already live there).
# Copy only what resolves in the staging tree; rootfs-provided libs stay.
python3 - "$XWROOT" "$ROOTFS" <<'PY'
import os, sys, subprocess, shutil
XWROOT, ROOTFS = sys.argv[1], sys.argv[2]
LIBDIRS = ["usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu",
           "usr/lib","lib","usr/lib64","lib64"]
BINS = ["usr/bin/Xwayland","usr/bin/xdpyinfo","usr/bin/xset",
        "usr/bin/xeyes","usr/bin/xclock","usr/bin/xkbcomp",
        "usr/bin/xwininfo","usr/bin/xlsclients"]

def needed(p):
    try: out=subprocess.check_output(["readelf","-d",p],stderr=subprocess.DEVNULL).decode()
    except Exception: return []
    return [l.split("[")[1].split("]")[0] for l in out.splitlines()
            if "(NEEDED)" in l and "[" in l]

def find(soname):
    for tree in (XWROOT, ROOTFS):
        for d in LIBDIRS:
            c=os.path.join(tree,d,soname)
            if os.path.exists(c): return os.path.realpath(c), tree
    return None,None

seen=set(); work=[]; copied=0; missing=set(); staged_bins=[]
for b in BINS:
    bp=os.path.join(XWROOT,b)
    if os.path.exists(bp):
        work += needed(bp); staged_bins.append(b)
while work:
    so=work.pop()
    if so in seen: continue
    seen.add(so)
    rp,tree=find(so)
    if rp is None: missing.add(so); continue
    if tree==XWROOT:
        dst=os.path.join(ROOTFS,"usr/lib/x86_64-linux-gnu",so)
        os.makedirs(os.path.dirname(dst),exist_ok=True)
        shutil.copy2(rp,dst); copied+=1
        dst2=os.path.join(ROOTFS,"lib/x86_64-linux-gnu",so)
        os.makedirs(os.path.dirname(dst2),exist_ok=True); shutil.copy2(rp,dst2)
    work += needed(rp)
# copy the client + server binaries that exist in the staging tree
for b in staged_bins:
    src=os.path.join(XWROOT,b)
    dst=os.path.join(ROOTFS,b)
    os.makedirs(os.path.dirname(dst),exist_ok=True)
    shutil.copy2(src,dst); os.chmod(dst,0o755)
print(f"[stage-xwl] staged {copied} closure libs + {len(staged_bins)} binaries: "
      + " ".join(os.path.basename(b) for b in staged_bins))
if missing:
    print("[stage-xwl] WARNING unresolved sonames:", sorted(missing))
    # A missing GL/glamor stub is tolerable (lazy dlopen path); a missing
    # core lib is fatal. Warn but don't hard-fail — the render test surfaces
    # a real ld.so failure on serial.
PY

# --- 3. X core fonts ---------------------------------------------------
# The X server opens the 'fixed' and 'cursor' fonts at startup and
# FatalError's ("could not open default font 'fixed'") without them.
# xfonts-base ships them (PCF) under /usr/share/fonts/X11/{misc,75dpi,...}
# with prebuilt fonts.dir indices. /usr/share/fonts is NOT pruned.
if [ -d "$XWROOT/usr/share/fonts/X11" ]; then
    mkdir -p "$ROOTFS/usr/share/fonts/X11"
    cp -a "$XWROOT/usr/share/fonts/X11/." "$ROOTFS/usr/share/fonts/X11/"
    echo "[stage-xwl] staged X core fonts (/usr/share/fonts/X11: $(ls "$ROOTFS/usr/share/fonts/X11" | tr '\n' ' '))"
else
    echo "[stage-xwl] WARNING: xfonts-base fonts absent — Xwayland may FatalError on 'fixed'."
fi
# fontenc encodings the PCF fonts reference.
if [ -d "$XWROOT/usr/share/fonts/X11/encodings" ]; then :; fi
if [ -d "$XWROOT/usr/share/X11/locale" ]; then
    cp -a "$XWROOT/usr/share/X11/locale" "$ROOTFS/usr/share/X11/" 2>/dev/null || true
fi

# --- 4. xkb rules (xkbcomp / server keymap build) ----------------------
# /usr/share/X11/xkb is already staged by stage_weston_term.sh (libxkbcommon
# include path). xkbcomp additionally needs the rules/ + the compiled keymap
# path; the weston stage copies the whole tree, so this is usually present.
# Re-copy from the staging tree if xserver-common/x11-xkb-utils shipped a
# newer/rules subset the weston copy lacked.
if [ -d "$XWROOT/usr/share/X11/xkb" ]; then
    cp -a "$XWROOT/usr/share/X11/xkb/." "$ROOTFS/usr/share/X11/xkb/" 2>/dev/null || true
    echo "[stage-xwl] refreshed /usr/share/X11/xkb (rules + keymap data)"
fi

# --- 5. X11 unix-socket + lock dirs ------------------------------------
# Xwayland binds /tmp/.X11-unix/X0 (path AF_UNIX socket) + the abstract
# "@/tmp/.X11-unix/X0" and writes /tmp/.X<n>-lock. The path bind resolves
# through the in-kernel AF_UNIX name registry (no VFS node), but Xwayland's
# transport code mkdir()s /tmp/.X11-unix and creates the lock file, so the
# dir must exist + be writable at runtime. build_rootfs_img.py re-plants
# /tmp (mode 1777) into the pruned live image; we add /tmp/.X11-unix there
# and also seed it in the rootfs here (belt + suspenders for a direct boot).
mkdir -p "$ROOTFS/tmp/.X11-unix"
chmod 1777 "$ROOTFS/tmp" 2>/dev/null || true
chmod 1777 "$ROOTFS/tmp/.X11-unix" 2>/dev/null || true
echo "[stage-xwl] seeded /tmp/.X11-unix (1777)"

echo "[stage-xwl] DONE. rootfs now carries Xwayland + closure + X core fonts."
echo "[stage-xwl]   verify: readelf -d $ROOTFS/usr/bin/Xwayland | grep NEEDED"
echo "[stage-xwl] Next: HAMNIX_LIVE_MINIMAL=0 bash scripts/build_installer_img.sh"
[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"
