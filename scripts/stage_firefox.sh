#!/usr/bin/env bash
# scripts/stage_firefox.sh — host-side, one-time: stage the UNMODIFIED
# Debian `firefox-esr` browser + its REAL runtime shared-object closure
# (GTK3/GDK, gdk-pixbuf + its dlopen'd loaders, cairo/pango/harfbuzz/
# pixman/fontconfig/freetype, glib/gobject/gio/dbus, libwayland-client/
# cursor) into the debian-minbase fixture rootfs. The full-mirror live
# image (HAMNIX_LIVE_MINIMAL=0) then carries a real Firefox that runs as a
# NATIVE Wayland CLIENT of the in-kernel Wayland compositor via
# MOZ_ENABLE_WAYLAND=1 — bypassing Xwayland entirely (whose rootful X
# render is blocked in this GL-free environment). weston-terminal already
# renders as a native wl client, so the Wayland transport is proven; this
# script provisions the (much larger) GTK3/Firefox client on the same path.
#
# SOFTWARE RENDER ONLY. Firefox draws its chrome with cairo/pixman on the
# CPU and composites into a wl_shm buffer — no Mesa/GL/GBM/DRM. It
# DT_NEEDED-links no GL; WebRender runs in its software (swgl) fallback,
# selected at launch by MOZ_ACCELERATED=0 / LIBGL_ALWAYS_SOFTWARE=1 (see
# the launch test). Firefox SELF-CONTAINS its NSS/NSPR/sqlite/vpx/av-codec
# (bundled under /usr/lib/firefox-esr), so the external closure is "just"
# the GTK3 desktop stack — much of which the weston fixture already stages.
#
# Run scripts/stage_weston_term.sh FIRST (glibc upgrade + fontconfig cache
# + xkb + DejaVu fonts + the wayland/cairo/pango/freetype base closure).
# This script REUSES all of that and adds the Firefox + GTK3 delta.
#
# The firefox-esr payload (/usr/lib/firefox-esr, ~260 MiB — libxul.so
# alone is ~164 MiB) is copied WHOLESALE (it is not DT_NEEDED-discoverable:
# libxul dlopen's omni.ja resources + the bundled NSS libs by name). The
# EXTERNAL closure is readelf-walked from the firefox launcher + libxul +
# the bundled libs, and only unresolved sonames are copied from the staging
# tree (rootfs-provided libs stay). Because of the 260 MiB payload the live
# ext4 rootfs must be grown:  HAMNIX_ROOTFS_SIZE_MB=768 (or more).
#
# Requirements (Debian/Ubuntu host): apt-get download access to the Debian
# mirror + dpkg-deb + readelf + gdk-pixbuf-query-loaders + glib-compile-
# schemas. No sudo, no install into the host. If the mirror's firefox-esr
# has rotated out of the pool (security pool 404), the script falls back to
# copying the host's INSTALLED /usr/lib/firefox-esr (this host ships one).
#
# Idempotent: safe to re-run; overwrites the staged files in place.
#
# Env:
#   ROOTFS  target rootfs (default: tests/distros/debian-minbase/rootfs)
#   WORK    scratch dir for .deb download/extract (default: mktemp)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$HERE/tests/distros/debian-minbase/rootfs}"
WORK="${WORK:-$(mktemp -d --tmpdir hamnix-firefox.XXXXXX)}"

if [ ! -d "$ROOTFS" ]; then
    echo "[stage-ff] ERROR: $ROOTFS absent."
    echo "[stage-ff]   Populate it (BUILD.sh / stage_host_dpkg_rootfs.sh) and"
    echo "[stage-ff]   run scripts/stage_weston_term.sh first."
    exit 1
fi
if [ ! -e "$ROOTFS/usr/bin/weston-terminal" ]; then
    echo "[stage-ff] WARNING: weston closure not detected in $ROOTFS."
    echo "[stage-ff]   Run scripts/stage_weston_term.sh first for the shared"
    echo "[stage-ff]   GTK/font/wayland base; continuing (delta may be larger)."
fi

DEBS="$WORK/debs"; FFROOT="$WORK/ffroot"
mkdir -p "$DEBS" "$FFROOT"

TARGET_LIB="usr/lib/x86_64-linux-gnu"

# --- 1. download the EXTERNAL GTK3 closure (firefox self-contains NSS) --
# Curated to the readelf-walked closure of libxul.so + the firefox launcher.
# Most low-level libs (cairo/pango/harfbuzz/pixman/freetype/fontconfig/
# glib/gobject/wayland) already live in the rootfs from stage_weston_term;
# they resolve against ROOTFS and are NOT re-copied. The GTK3/GDK/ATK/
# gdk-pixbuf front + a few Firefox-specific DT_NEEDED libs (libevent,
# libvpx, libdbus, libasound, libXdamage) are the real delta.
PKGS=(
  libgtk-3-0t64 libgtk-3-common libgdk-pixbuf-2.0-0 libgdk-pixbuf2.0-bin
  libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64
  libcairo2 libcairo-gobject2
  libpango-1.0-0 libpangocairo-1.0-0 libpangoft2-1.0-0
  libharfbuzz0b libfribidi0 libthai0 libdatrie1 libgraphite2-3
  libpixman-1-0 libepoxy0
  libglib2.0-0t64
  # NSPR (libnspr4/libplc4/libplds4): firefox bundles NSS but NOT NSPR —
  # libxul DT_NEEDED-links libnspr4.so/libplc4.so; absent => ld.so abort.
  libnspr4
  libdbus-1-3 libdbus-glib-1-2
  libwayland-client0 libwayland-cursor0 libwayland-egl1
  # libgtk-3.so.0 DT_NEEDED-links libcloudproviders.so.0; without it the
  # dlopen of libmozgtk.so at Firefox's XPCOMGlueLoad fails and the
  # launcher aborts with "Couldn't load XPCOM." before libxul even loads.
  libcloudproviders0
  libevent-2.1-7t64 libvpx9 libasound2t64
  libx11-6 libx11-xcb1 libxcb1 libxcb-shm0 libxext6 libxfixes3
  libxcomposite1 libxdamage1 libxrandr2 libxi6 libxrender1 libxcursor1
  libxkbcommon0 libxinerama1 libxau6 libxdmcp6 libbsd0 libmd0
  libffi8 libpng16-16t64 libfreetype6 libfontconfig1 libexpat1 zlib1g
  libstdc++6 libgcc-s1
  # gsettings schemas (GTK reads org.gtk.Settings.* at startup)
  gsettings-desktop-schemas
  # svg pixbuf loader (GTK themes/icons); optional but harmless
  librsvg2-common
  shared-mime-info
)
echo "[stage-ff] downloading ${#PKGS[@]} closure packages into $DEBS ..."
( cd "$DEBS" && apt-get download "${PKGS[@]}" >/dev/null 2>&1 ) || {
    echo "[stage-ff] WARNING: some closure downloads failed (mirror rotation?)."
    echo "[stage-ff]   Retrying individually; missing libs surface at run time."
    for p in "${PKGS[@]}"; do ( cd "$DEBS" && apt-get download "$p" >/dev/null 2>&1 ) || echo "[stage-ff]   - skip $p"; done
}

# --- 1b. firefox-esr itself: mirror download, else host-install copy ----
FF_SRC=""
echo "[stage-ff] fetching firefox-esr ..."
if ( cd "$DEBS" && apt-get download firefox-esr >/dev/null 2>&1 ) && ls "$DEBS"/firefox-esr_*.deb >/dev/null 2>&1; then
    echo "[stage-ff]   got firefox-esr .deb from mirror."
    FF_SRC="deb"
elif [ -d /usr/lib/firefox-esr ] && [ -e /usr/lib/firefox-esr/libxul.so ]; then
    echo "[stage-ff]   mirror firefox-esr unavailable; copying HOST /usr/lib/firefox-esr."
    FF_SRC="host"
else
    echo "[stage-ff] ERROR: firefox-esr not downloadable AND not installed on host." >&2
    echo "[stage-ff]   apt-get install firefox-esr on the host, or fix mirror access." >&2
    exit 1
fi

echo "[stage-ff] extracting closure .debs into merged staging tree ..."
for d in "$DEBS"/*.deb; do dpkg-deb -x "$d" "$FFROOT"; done

# --- 2. copy the firefox-esr payload WHOLESALE -------------------------
# /usr/lib/firefox-esr is a self-contained bundle (libxul + omni.ja +
# bundled NSS/NSPR/sqlite/vpx/av-codec + dependentlibs.list). It is NOT
# DT_NEEDED-discoverable, so copy the whole tree verbatim.
echo "[stage-ff] staging /usr/lib/firefox-esr payload (~260 MiB) ..."
mkdir -p "$ROOTFS/usr/lib"
if [ "$FF_SRC" = "deb" ]; then
    rm -rf "$ROOTFS/usr/lib/firefox-esr"
    cp -a "$FFROOT/usr/lib/firefox-esr" "$ROOTFS/usr/lib/firefox-esr"
else
    rm -rf "$ROOTFS/usr/lib/firefox-esr"
    cp -a /usr/lib/firefox-esr "$ROOTFS/usr/lib/firefox-esr"
fi
# /usr/bin/firefox-esr -> ../lib/firefox-esr/firefox-esr (Debian layout).
mkdir -p "$ROOTFS/usr/bin"
ln -sf ../lib/firefox-esr/firefox-esr "$ROOTFS/usr/bin/firefox-esr"
FF_DU="$(du -sh "$ROOTFS/usr/lib/firefox-esr" | awk '{print $1}')"
echo "[stage-ff]   firefox-esr payload staged ($FF_DU)."

# --- 3. walk the transitive DT_NEEDED closure --------------------------
# Seed from the firefox launcher + every bundled .so; resolve each soname
# against the merged staging tree first, then the existing rootfs (libc/
# ld.so + the weston closure already live there). Copy only what resolves
# in the staging tree; rootfs-provided libs stay.
python3 - "$FFROOT" "$ROOTFS" <<'PY'
import os, sys, subprocess, shutil, glob
FFROOT, ROOTFS = sys.argv[1], sys.argv[2]
LIBDIRS = ["usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu",
           "usr/lib","lib","usr/lib64","lib64"]
# Seed binaries: the firefox launcher + all bundled firefox .so (they pull
# the external GTK/pango/etc closure), resolved from the STAGED payload.
SEED = [os.path.join(ROOTFS,"usr/lib/firefox-esr/firefox-esr")]
SEED += sorted(glob.glob(os.path.join(ROOTFS,"usr/lib/firefox-esr/*.so")))

def needed(p):
    try: out=subprocess.check_output(["readelf","-d",p],stderr=subprocess.DEVNULL).decode()
    except Exception: return []
    return [l.split("[")[1].split("]")[0] for l in out.splitlines()
            if "(NEEDED)" in l and "[" in l]

def find(soname):
    # firefox's own bundled libs live in the payload; don't re-copy those.
    for tree in (FFROOT, ROOTFS):
        for d in LIBDIRS:
            c=os.path.join(tree,d,soname)
            if os.path.exists(c): return os.path.realpath(c), tree
    return None,None

seen=set(); work=[]; copied=0; missing=set()
for s in SEED:
    if os.path.exists(s): work += needed(s)
while work:
    so=work.pop()
    if so in seen: continue
    seen.add(so)
    # bundled firefox libs resolve inside the payload — skip external copy
    if os.path.exists(os.path.join(ROOTFS,"usr/lib/firefox-esr",so)):
        continue
    rp,tree=find(so)
    if rp is None: missing.add(so); continue
    if tree==FFROOT:
        for outd in ("usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu"):
            dst=os.path.join(ROOTFS,outd,so)
            os.makedirs(os.path.dirname(dst),exist_ok=True)
            shutil.copy2(rp,dst);
        copied+=1
    work += needed(rp)
print(f"[stage-ff] staged {copied} external closure libs from the GTK3 delta")
if missing:
    print("[stage-ff] NOTE unresolved sonames (bundled/lazy/absent):", sorted(missing))
PY

# --- 4. GdkPixbuf loaders (dlopen'd) + regenerated cache ---------------
# GTK loads image loaders by dlopen from
# /usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders and reads the
# loaders.cache index. The cache embeds ABSOLUTE loader paths, so we
# regenerate it with the host's gdk-pixbuf-query-loaders against the
# STAGED loaders, then rewrite the staging prefix to the in-image path.
PIXBUF_REL="usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/2.10.0"
if [ -d "$FFROOT/$PIXBUF_REL/loaders" ]; then
    mkdir -p "$ROOTFS/$PIXBUF_REL/loaders"
    cp -a "$FFROOT/$PIXBUF_REL/loaders/." "$ROOTFS/$PIXBUF_REL/loaders/"
    # DT_NEEDED closure of each loader (e.g. libjpeg/libtiff/librsvg deps).
    python3 - "$FFROOT" "$ROOTFS" "$PIXBUF_REL" <<'PY'
import os,sys,subprocess,shutil,glob
FFROOT,ROOTFS,REL=sys.argv[1],sys.argv[2],sys.argv[3]
LIBDIRS=["usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu","usr/lib","lib"]
def needed(p):
    try:o=subprocess.check_output(["readelf","-d",p],stderr=subprocess.DEVNULL).decode()
    except Exception:return []
    return [l.split("[")[1].split("]")[0] for l in o.splitlines() if "(NEEDED)" in l and "[" in l]
def find(so):
    for t in (FFROOT,ROOTFS):
        for d in LIBDIRS:
            c=os.path.join(t,d,so)
            if os.path.exists(c):return os.path.realpath(c),t
    return None,None
seen=set();work=[]
for lo in glob.glob(os.path.join(ROOTFS,REL,"loaders","*.so")): work+=needed(lo)
n=0
while work:
    so=work.pop()
    if so in seen:continue
    seen.add(so)
    rp,t=find(so)
    if rp is None:continue
    if t==FFROOT:
        for outd in ("usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu"):
            dst=os.path.join(ROOTFS,outd,so);os.makedirs(os.path.dirname(dst),exist_ok=True);shutil.copy2(rp,dst)
        n+=1
    work+=needed(rp)
print(f"[stage-ff] staged {n} gdk-pixbuf loader deps")
PY
    QL="/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders"
    [ -x "$QL" ] || QL="$(command -v gdk-pixbuf-query-loaders || true)"
    if [ -n "$QL" ] && [ -x "$QL" ]; then
        "$QL" "$ROOTFS/$PIXBUF_REL/loaders/"*.so 2>/dev/null \
          | sed "s|$ROOTFS/||g" > "$ROOTFS/$PIXBUF_REL/loaders.cache"
        echo "[stage-ff] wrote gdk-pixbuf loaders.cache ($(grep -c '\.so' "$ROOTFS/$PIXBUF_REL/loaders.cache" || echo 0) loaders)"
    else
        echo "[stage-ff] WARNING: gdk-pixbuf-query-loaders absent; no loaders.cache (icons may not decode)."
    fi
else
    echo "[stage-ff] NOTE: no gdk-pixbuf loaders in staging tree."
fi

# --- 5. GTK immodules (dlopen'd input methods) -------------------------
IMMOD_REL="usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules"
if [ -d "$FFROOT/$IMMOD_REL" ]; then
    mkdir -p "$ROOTFS/$IMMOD_REL"
    cp -a "$FFROOT/$IMMOD_REL/." "$ROOTFS/$IMMOD_REL/" 2>/dev/null || true
    QI="/usr/lib/x86_64-linux-gnu/libgtk-3-0/gtk-query-immodules-3.0"
    [ -x "$QI" ] || QI="$(command -v gtk-query-immodules-3.0 || true)"
    if [ -n "$QI" ] && [ -x "$QI" ]; then
        "$QI" "$ROOTFS/$IMMOD_REL/"*.so 2>/dev/null \
          | sed "s|$ROOTFS/||g" > "$ROOTFS/usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules.cache" || true
        echo "[stage-ff] wrote gtk immodules.cache"
    fi
fi

# --- 6. GLib GSettings schemas (GTK reads org.gtk.Settings.*) ----------
# GTK aborts hard if the compiled schema for org.gtk.Settings.FileChooser
# etc. is missing on some paths; always provide gschemas.compiled.
SCHEMA_REL="usr/share/glib-2.0/schemas"
if [ -d "$FFROOT/$SCHEMA_REL" ]; then
    mkdir -p "$ROOTFS/$SCHEMA_REL"
    cp -a "$FFROOT/$SCHEMA_REL/." "$ROOTFS/$SCHEMA_REL/" 2>/dev/null || true
    # Also pull the host's GTK core schemas if the deb set lacked them.
    for x in /usr/share/glib-2.0/schemas/org.gtk.*.gschema.xml \
             /usr/share/glib-2.0/schemas/org.gnome.desktop.interface.gschema.xml; do
        [ -e "$x" ] && cp -a "$x" "$ROOTFS/$SCHEMA_REL/" 2>/dev/null || true
    done
    if command -v glib-compile-schemas >/dev/null 2>&1; then
        glib-compile-schemas "$ROOTFS/$SCHEMA_REL" >/dev/null 2>&1 \
          && echo "[stage-ff] compiled gschemas.compiled" \
          || echo "[stage-ff] WARNING: glib-compile-schemas failed (GTK may warn)."
    fi
fi

# --- 7. shared-mime-info (GIO content-type db; GTK file chooser) -------
if [ -d "$FFROOT/usr/share/mime" ]; then
    mkdir -p "$ROOTFS/usr/share/mime"
    cp -a "$FFROOT/usr/share/mime/." "$ROOTFS/usr/share/mime/" 2>/dev/null || true
fi

# --- 8. runtime dirs + a throwaway profile ----------------------------
# XDG_RUNTIME_DIR=/run carries the wayland-0 socket (created by the DE).
# Firefox writes a profile; give it a fixed throwaway dir + prefs that
# force software render and disable the sandbox/remote so the launch test
# is deterministic. /tmp is the base-namespace scratch dir.
mkdir -p "$ROOTFS/run" "$ROOTFS/tmp"
chmod 1777 "$ROOTFS/tmp" 2>/dev/null || true
PROFILE="$ROOTFS/root/.ff-profile"
mkdir -p "$PROFILE"
# Both prefs.js (initial) AND user.js (durable — Firefox re-applies user.js
# into prefs on every start, so it wins even after Firefox rewrites prefs.js).
# The KEY prefs for the Hamnix wl_shm-only compositor (no EGL/GL/DMABuf/DRM):
#   gfx.webrender.software              = true   -> SWGL CPU rasteriser
#   gfx.webrender.software.opengl       = false  -> the SW-WR render thread
#       PRESENTS its composited frame straight into a wl_shm buffer instead
#       of creating an OpenGL/EGL RenderCompositor. WITHOUT this, software
#       WebRender still opens a 2nd wl connection + an EGL GL context for the
#       final present — and mesa/EGL is ABSENT here (no libEGL, no dri driver,
#       only a dead libgbm), so that GL-present init NULL-derefs on the render
#       thread (the window-blocking crash). false == pure shm path.
#   gfx.webrender.compositor            = false  -> no native/EGL compositor
#   gfx.x11-egl.force-disabled          = true   -> never probe EGL
#   widget.dmabuf.force-enabled         = false  -> no DMABuf (needs DRM/GBM)
#   media.ffmpeg.vaapi.enabled          = false  -> no VA-API dmabuf
read -r -d '' FF_PREFS <<'PREFS' || true
// Throwaway Firefox profile — PURE wl_shm software render (no EGL/GL/DMABuf).
user_pref("gfx.webrender.software", true);
user_pref("gfx.webrender.software.opengl", false);
user_pref("gfx.webrender.force-disabled", false);
user_pref("gfx.webrender.compositor", false);
user_pref("gfx.webrender.compositor.force-enabled", false);
user_pref("gfx.x11-egl.force-disabled", true);
user_pref("widget.dmabuf.force-enabled", false);
user_pref("widget.wayland.use-dmabuf", false);
user_pref("media.ffmpeg.vaapi.enabled", false);
user_pref("media.hardware-video-decoding.enabled", false);
user_pref("layers.acceleration.disabled", true);
user_pref("layers.gpu-process.enabled", false);
user_pref("webgl.disabled", true);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.tabs.remote.autostart", false);
user_pref("dom.ipc.processCount", 1);
user_pref("browser.startup.page", 0);
PREFS
printf '%s\n' "$FF_PREFS" > "$PROFILE/prefs.js"
printf '%s\n' "$FF_PREFS" > "$PROFILE/user.js"
echo "[stage-ff] seeded throwaway profile ($PROFILE, prefs.js+user.js) + /run + /tmp"

# --- 8a. force the pure wl_shm software path: REMOVE the GL/GBM libs -----
# The Hamnix compositor speaks wl_shm ONLY. There is no mesa EGL, no dri
# driver, and no DRM render node in the namespace. Firefox, however, probes
# for DMABuf/GBM at gfx init: as long as `libgbm.so.1` is dlopen-able it runs
# DMABufDevice::Configure -> DMABufFormats::EnsureBasicFormats and then
# NULL-derefs on the absent DRM/GBM device (write-perm fault va=0, rip in
# libxul's DMABuf path — the render-thread window-blocking crash). PREFS
# alone (widget.dmabuf.force-enabled=false etc.) do NOT stop the probe.
#
# libxul only *dlopens* these by soname (they are NOT DT_NEEDED — verified
# with readelf -d), so DELETING them makes the dlopen fail cleanly and
# Firefox falls back to its pure-software wl_shm present path. weston-terminal
# / weston-simple-shm / libgtk-3 do not link them either, so the wl_shm
# clients are unaffected. (Only Xwayland — unused, GL-blocked here — needs
# libgbm, so its loss is a no-op for the native-Wayland path.)
echo "[stage-ff] removing GL/GBM libs to force Firefox onto the wl_shm path ..."
# -L so a symlinked ROOTFS start point is descended (find does not descend a
# symlink-to-dir start point by default).
for gl in libgbm.so libGL.so libGLX.so libGLX_mesa.so libEGL.so libEGL_mesa.so \
          libGLdispatch.so libgallium libvulkan_lvp.so; do
    find -L "$ROOTFS" -name "${gl}*" -print -delete 2>/dev/null || true
done
# dri driver blobs (swrast_dri.so etc.), if any slipped in
find -L "$ROOTFS" -path "*/dri/*_dri.so" -print -delete 2>/dev/null || true
echo "[stage-ff]   GL/GBM libs removed (Firefox -> wl_shm software present)."

# --- 8b. baked-in native-Wayland launcher (/ff-launch.sh) --------------
# One short serial line launches Firefox as a native wl client once the
# live-root is up:  spawn linux { /bin/sh /ff-launch.sh }
# All env is baked here (no 900-char inline string — hamsh's line editor
# caps command length). A spawn-linux child's stdout reaches the serial
# console, so we merge Firefox stderr (2>&1) through a line-buffered read
# loop that prefixes [FF]: GDK/GLib warnings + assertions then land on the
# serial log (Firefox's own stderr otherwise rides the DE-owned console).
cat > "$ROOTFS/ff-launch.sh" <<'FFLAUNCH'
#!/bin/sh
# /ff-launch.sh — Firefox-as-native-Wayland-client launcher (see stage_firefox.sh).
export XDG_RUNTIME_DIR=/run
export WAYLAND_DISPLAY=wayland-0
export MOZ_ENABLE_WAYLAND=1
export MOZ_DISABLE_WAYLAND_PROXY=1
export GDK_BACKEND=wayland
export MOZ_DISABLE_CONTENT_SANDBOX=1
export MOZ_DISABLE_GMP_SANDBOX=1
export MOZ_DISABLE_RDD_SANDBOX=1
export MOZ_SANDBOX=0
export LIBGL_ALWAYS_SOFTWARE=1
export MOZ_ACCELERATED=0
export MOZ_WEBRENDER=1
# Force pure-software WebRender + present via wl_shm (NO EGL/GL/DMABuf). Our
# compositor speaks wl_shm only (no libEGL/dri/DRM in the ns), so the SW-WR
# render thread must NOT open an OpenGL RenderCompositor — env belt to the
# user.js prefs (gfx.webrender.software.opengl=false).
export MOZ_WEBRENDER_SOFTWARE=1
export MOZ_X11_EGL=0
export MOZ_DISABLE_DMABUF=1
export MOZ_ALLOW_SOFTWARE_GL=1
export MOZ_CRASHREPORTER_DISABLE=1
export MOZ_LAYOUT_FRAME_RATE=10
# Diagnostics: the CURRENT fresh-boot blocker is NOT a client crash and NOT a
# missing wl_surface op — it is the parent<->child process IPC handshake. On a
# clean 3G boot the parent firefox-esr builds full GTK chrome, spawns the
# content + GPU child processes, then EXITS code=255 WITHOUT creating a
# wl_surface, leaving the children parked forever in futex / poll / ppoll /
# epoll_wait (waiting on IPC messages the parent never delivers). So the
# instructive modules are the IPC channel + widget/window bring-up, NOT gfx.
#   NB: MOZ_LOG_FILE=/dev/stderr rode the DE-owned console for the child
#   processes and produced NOTHING capturable on the serial [FF] stream; point
#   it at a writable file under $HOME (the live root's /root is writable) so a
#   follow-up run can `cat /root/moz.log*` over the serial shell and read the
#   parent's exact IPC-launch / handshake-timeout decision. `sync` flushes each
#   line so a 255 exit does not lose the tail.
export MOZ_LOG='ipc:5,IPDL:5,MessageChannel:5,widget:5,WidgetWayland:5,nsWindow:5,sync'
export MOZ_LOG_FILE=/root/moz.log
export HOME=/root
export XDG_CONFIG_HOME=/run
export XDG_CACHE_HOME=/root/.cache
# Fontconfig: point libfontconfig explicitly at the staged /etc/fonts config.
# Without this, firefox's fontconfig cannot locate a default config file
# ("Cannot load default config file: No such file: (null)") because its
# compiled-in default path does not match the Hamnix distro layout and no
# FONTCONFIG_* env is set -> font init fails and firefox exits before it
# commits its first wl_shm frame. FONTCONFIG_FILE names the config directly;
# FONTCONFIG_PATH is the dir fallback. Both are standard fontconfig overrides.
export FONTCONFIG_FILE=/etc/fonts/fonts.conf
export FONTCONFIG_PATH=/etc/fonts
export G_SLICE=always-malloc
export G_MESSAGES_DEBUG=all
mkdir -p /root/.cache /root/.mozilla /run
# drop any stale profile lock from a prior crashed run
rm -f /root/.ff-profile/lock /root/.ff-profile/.parentlock 2>/dev/null
echo "[FF] launching firefox-esr (native wayland)"
/usr/lib/firefox-esr/firefox-esr \
    -profile /root/.ff-profile -no-remote -new-instance 'about:blank' 2>&1 \
    | while IFS= read -r line; do echo "[FF] $line"; done
echo "[FF] firefox pipeline ended"
FFLAUNCH
chmod +x "$ROOTFS/ff-launch.sh"
echo "[stage-ff] baked native-wayland launcher: /ff-launch.sh"

echo "[stage-ff] DONE. rootfs now carries firefox-esr + GTK3 closure."
echo "[stage-ff]   payload: $FF_DU under /usr/lib/firefox-esr"
echo "[stage-ff]   verify:  readelf -d $ROOTFS/usr/lib/firefox-esr/libxul.so | grep NEEDED"
echo "[stage-ff]   NOTE: grow the live rootfs — HAMNIX_ROOTFS_SIZE_MB=768 (or more)."
echo "[stage-ff] Next: HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB=768 bash scripts/build_installer_img.sh"
[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"
