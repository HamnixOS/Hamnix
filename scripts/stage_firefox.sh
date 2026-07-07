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

# --- 1b. firefox-esr itself: explicit .deb, else mirror download, else host --
# FF_DEB=<path>   stage THIS exact firefox-esr .deb (version-alignment /
#                 debug-symbol control). Preferred over the host copy so the
#                 staged libxul's build-id matches a downloaded firefox-esr-
#                 dbgsym (offline addr2line symbolication of parked-wd RIPs).
#                 The rootfs is BOOKWORM-based (deb12 GTK stack), so a
#                 firefox-esr_*~deb12u1_amd64.deb build is the version-aligned
#                 choice — the host's installed firefox-esr is a deb13/trixie
#                 build against newer glibc/GTK than the rootfs carries.
FF_SRC=""
FF_DEB_FILE=""
echo "[stage-ff] fetching firefox-esr ..."
if [ -n "${FF_DEB:-}" ] && [ -f "${FF_DEB}" ]; then
    echo "[stage-ff]   using explicit FF_DEB=${FF_DEB}"
    cp -f "${FF_DEB}" "$DEBS/"
    FF_DEB_FILE="$DEBS/$(basename "${FF_DEB}")"
    FF_SRC="deb"
elif ( cd "$DEBS" && apt-get download firefox-esr >/dev/null 2>&1 ) && ls "$DEBS"/firefox-esr_*.deb >/dev/null 2>&1; then
    echo "[stage-ff]   got firefox-esr .deb from mirror."
    FF_DEB_FILE="$(ls "$DEBS"/firefox-esr_*.deb | head -1)"
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
# Record the staged libxul build-id so an offline addr2line can pick the
# matching firefox-esr-dbgsym .debug for parked-wd RIP symbolication.
if command -v readelf >/dev/null 2>&1 && [ -e "$ROOTFS/usr/lib/firefox-esr/libxul.so" ]; then
    LIBXUL_BID="$(readelf -n "$ROOTFS/usr/lib/firefox-esr/libxul.so" 2>/dev/null \
        | grep -oiE 'Build ID: [0-9a-f]+' | awk '{print $3}')"
    echo "[stage-ff]   staged libxul build-id: ${LIBXUL_BID:-<unknown>}"
    echo "${LIBXUL_BID:-unknown}" > "$ROOTFS/usr/lib/firefox-esr/.libxul-build-id" 2>/dev/null || true
    if [ -n "${FF_DEB_FILE}" ]; then
        echo "[stage-ff]   staged from: $(basename "${FF_DEB_FILE}")"
    fi
fi

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

# --- 7b. fontconfig DTD (belt) -----------------------------------------
# The staged /etc/fonts/fonts.conf carries `<!DOCTYPE fontconfig SYSTEM
# "fonts.dtd">`. fontconfig's non-validating expat parse normally does NOT
# fetch the DTD, but stage it next to the config anyway so a validating build
# cannot trip on a missing SYSTEM entity. Sourced from the host fontconfig pkg
# or the staging tree; harmless if absent.
for dtd_src in "$FFROOT/usr/share/xml/fontconfig/fonts.dtd" \
               /usr/share/xml/fontconfig/fonts.dtd \
               /usr/share/fontconfig/fonts.dtd; do
    if [ -f "$dtd_src" ]; then
        mkdir -p "$ROOTFS/etc/fonts" "$ROOTFS/usr/share/xml/fontconfig"
        cp -a "$dtd_src" "$ROOTFS/etc/fonts/fonts.dtd"
        cp -a "$dtd_src" "$ROOTFS/usr/share/xml/fontconfig/fonts.dtd"
        echo "[stage-ff] staged fontconfig fonts.dtd (belt) from $dtd_src"
        break
    fi
done

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
// MULTIPROCESS RE-ENABLED (#125): the single-process prefs below were a
// WORKAROUND for the OLD cross-process child deadlock, now FIXED on main
// (afunix fd-inherit c63406c1 + pgrp d6567770 + futex 4fc6c713/b775a4ae).
// Firefox's single-process software-WebRender path intra-deadlocks (main
// thread cond-waits on a compositor thread blocked on a self-pipe whose
// writer sibling is also parked). The NORMAL multiprocess render path runs
// content + GPU/compositor in a persistent child (2nd cr3) and avoids that
// intra-process circular init. Allow the GPU process; keep pure software.
user_pref("layers.gpu-process.enabled", true);
user_pref("webgl.disabled", true);
// ---- suppress the startup GPU-probe CHILD (glxtest / vaapitest). Firefox
// launches these as separate helper binaries via g_spawn (fork+exec) to
// learn GL/VAAPI capabilities. In this GL-free namespace the probe child
// deadlocks in a parent<->child pipe wait (the #119 window blocker). These
// prefs stop libxul from ever WANTING the GL/VAAPI info, so the probe is
// never fired (the binaries are also physically removed from the rootfs by
// stage_firefox.sh section 8a as a definitive belt).
user_pref("gfx.x11-glx.disabled", true);        // never probe/desire GLX
user_pref("gfx.canvas.accelerated", false);     // no GPU canvas -> no GL want
user_pref("media.ffmpeg.vaapi-drm-display.enabled", false);
user_pref("media.rdd-vpx.enabled", false);
user_pref("media.rdd-ffmpeg.enabled", false);
user_pref("media.rdd-ffvpx.enabled", false);
user_pref("media.utility-process.enabled", false); // no utility child
user_pref("media.gpu-process-decoder", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.tabs.remote.autostart", true);
user_pref("dom.ipc.processCount", 4);
user_pref("browser.startup.page", 0);
// ---- minimise child-process dependence (Hamnix Linux-ns futex is still the
// O(n^2) poll-yield path pending the bounded-park fix #117: every extra
// Firefox child = ~10 more threads parking on the slow futex, and a child
// that crashes/stalls during its OWN gfxPlatform font-list init emits the
// late "Fontconfig error: ... (null)" then can wedge the parent's launch
// before the chrome toplevel maps). The browser CHROME window is drawn by
// the PARENT and needs NO child process to map, so disable every optional
// out-of-process child: Fission/site-isolation, the RDD (media decode),
// the network/socket process, the utility process, and privileged content.
// This is a pure throwaway-profile pref change (no effect on weston-terminal
// or the DE) that gives the parent's xdg_toplevel the best chance to map. ----
user_pref("fission.autostart", false);
user_pref("media.rdd-process.enabled", false);
user_pref("network.process.enabled", false);
user_pref("browser.tabs.remote.separatePrivilegedContentProcess", false);
user_pref("browser.tabs.remote.useCrossOriginOpenerPolicy", false);
user_pref("browser.tabs.remote.useCrossOriginEmbedderPolicy", false);
user_pref("dom.ipc.forkserver.enable", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("extensions.pocket.enabled", false);
PREFS
printf '%s\n' "$FF_PREFS" > "$PROFILE/prefs.js"
printf '%s\n' "$FF_PREFS" > "$PROFILE/user.js"
# WORLD-READABLE seed copy: `spawn linux` runs Firefox as a non-hostowner uid
# (1001) which may not traverse root-owned /root (0700). ff-launch.sh copies
# the prefs from THIS world-readable path (under /usr) into its writable /tmp
# profile so the critical software-render prefs survive even when /root is
# unreadable to uid 1001.
SEED_DIR="$ROOTFS/usr/lib/firefox-esr/ff-profile-seed"
mkdir -p "$SEED_DIR"
printf '%s\n' "$FF_PREFS" > "$SEED_DIR/prefs.js"
printf '%s\n' "$FF_PREFS" > "$SEED_DIR/user.js"
chmod -R a+rX "$SEED_DIR" 2>/dev/null || true
echo "[stage-ff] seeded throwaway profile ($PROFILE + world-readable $SEED_DIR) + /run + /tmp"

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

# --- 8a2. STUB the GPU-probe helpers (glxtest / vaapitest) ----------------
# Firefox 140 launches these two SEPARATE helper binaries at startup via
# base::LaunchApp/posix_spawn (fork+exec) to probe GL (glxtest) and VA-API
# (vaapitest); each writes its result to the fd given by `-f <n>` (a pipe back
# to the parent) and the parent reads it in GfxInfo::GetData()/GetDataVAAPI().
#
# HISTORY: #120 DELETED these binaries. But a MISSING binary is the WRONG cure:
# the posix_spawn still succeeds-then-exec-fails, and on Hamnix's Linux ABI the
# failed exec surfaces as a child that exits 127 (not a clean g_spawn pid=0),
# which GfxInfo can treat as a hard graphics-init failure — leaving the GPU
# probe in an indeterminate state instead of a definite "no GL". With the
# CLONE_THREAD pgrp-namespace fix (#123/d6567770) the probe CHILD now runs in
# the correct namespace and no longer deadlocks, so the right fix is a probe
# that RUNS and writes the canonical "no GL / software only" answer the parent
# accepts, then exits 0.
#
# THE STUB emits exactly the response Firefox's OWN glxtest produces when
# MOZ_AVOID_OPENGL_ALTOGETHER is set (ff-launch.sh exports it):
#     ERROR\nMOZ_AVOID_OPENGL_ALTOGETHER envvar set\n
# GfxInfo reads that as "GL unavailable" — a SUPPORTED, non-fatal no-GL mode
# (that env var exists precisely to force it) — so Firefox blocklists GL/EGL
# acceleration and falls back to pure-software WebRender (swgl), which presents
# into a wl_shm buffer (no libGL/EGL/GBM needed — those stay removed, §8a).
# The stub parses `-f <n>`/`--fd <n>` (writes there; default stdout) and
# ignores `-w`. It links only libc — no libgdk-3/X11/GL — so it always loads
# and never touches a display. vaapitest gets the same ERROR no-op.
#
# Compiled from C on the host (gcc/cc, static so no runtime lib dep at all).
# If no C compiler is present we fall back to KEEPING the real glxtest binary
# (which, via MOZ_AVOID_OPENGL_ALTOGETHER=1, self-emits the identical ERROR and
# exits before any GL dlopen — verified: its DT_NEEDED closure is GL-free).
echo "[stage-ff] installing no-GL stub for GPU-probe helpers (glxtest/vaapitest) ..."
STUB_SRC="$WORK/glxtest_stub.c"
cat > "$STUB_SRC" <<'STUBC'
/* no-GL glxtest/vaapitest stub: writes the canonical "no GL" response Firefox
 * accepts (same bytes as the real glxtest with MOZ_AVOID_OPENGL_ALTOGETHER),
 * to the fd named by -f/--fd (default stdout), then exits 0. libc-only. */
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
    int fd = 1; /* default stdout */
    for (int i = 1; i < argc; i++) {
        if ((!strcmp(argv[i], "-f") || !strcmp(argv[i], "--fd")) && i + 1 < argc)
            fd = atoi(argv[++i]);
    }
    /* exact bytes the real glxtest writes with MOZ_AVOID_OPENGL_ALTOGETHER
     * (no trailing newline — GfxInfo splits on '\n'). */
    static const char resp[] = "ERROR\nMOZ_AVOID_OPENGL_ALTOGETHER envvar set";
    size_t off = 0, n = sizeof(resp) - 1;
    while (off < n) {
        ssize_t w = write(fd, resp + off, n - off);
        if (w <= 0) break;
        off += (size_t)w;
    }
    return 0;
}
STUBC
CC_BIN="$(command -v gcc || command -v cc || true)"
STUB_OK=0
if [ -n "$CC_BIN" ]; then
    if "$CC_BIN" -static -O2 -o "$WORK/glxtest_stub" "$STUB_SRC" 2>/dev/null \
       || "$CC_BIN" -O2 -o "$WORK/glxtest_stub" "$STUB_SRC" 2>/dev/null; then
        for probe in glxtest vaapitest; do
            cp -f "$WORK/glxtest_stub" "$ROOTFS/usr/lib/firefox-esr/$probe"
            chmod 0755 "$ROOTFS/usr/lib/firefox-esr/$probe"
            echo "[stage-ff]   installed no-GL stub -> /usr/lib/firefox-esr/$probe"
        done
        STUB_OK=1
    fi
fi
if [ "$STUB_OK" -eq 0 ]; then
    echo "[stage-ff]   no C compiler / build failed; KEEPING real glxtest+vaapitest"
    echo "[stage-ff]   (MOZ_AVOID_OPENGL_ALTOGETHER=1 makes them self-emit the no-GL ERROR)."
    # Ensure the real probe binaries' GL-free DT_NEEDED closure is staged so
    # they load: seed the closure walker (below re-run) with them.
    for probe in glxtest vaapitest; do
        if [ ! -e "$ROOTFS/usr/lib/firefox-esr/$probe" ]; then
            if [ "$FF_SRC" = "deb" ] && [ -e "$FFROOT/usr/lib/firefox-esr/$probe" ]; then
                cp -a "$FFROOT/usr/lib/firefox-esr/$probe" "$ROOTFS/usr/lib/firefox-esr/$probe"
            elif [ -e "/usr/lib/firefox-esr/$probe" ]; then
                cp -a "/usr/lib/firefox-esr/$probe" "$ROOTFS/usr/lib/firefox-esr/$probe"
            fi
        fi
    done
fi

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
# ---- suppress the startup GPU-probe CHILD (glxtest/vaapitest) -----------
# Firefox forks+execs a `glxtest` helper (and `vaapitest`) at startup to
# learn GL/VAAPI capability and reads the result over a pipe. In this GL-free
# namespace that forked probe child DEADLOCKS in a parent<->child pipe wait
# (the #119 window blocker). We remove the two helper binaries in
# stage_firefox.sh (g_spawn then fails cleanly), and additionally PRE-SEED
# the GL info via MOZ_GFX_SPOOF_* so GfxInfo already has vendor/renderer/
# version/OS and never needs the probe result. MOZ_AVOID_OPENGL_ALTOGETHER
# is glxtest's own belt (a no-op once the binary is gone). Net effect: no GL
# probe fork -> no deadlock -> the parent proceeds straight to chrome map.
export MOZ_GFX_SPOOF_GL_VENDOR="Mesa"
export MOZ_GFX_SPOOF_GL_RENDERER="llvmpipe (Hamnix wl_shm software)"
export MOZ_GFX_SPOOF_GL_VERSION="3.3 (Core Profile) Mesa"
export MOZ_GFX_SPOOF_OS="Linux"
export MOZ_GFX_SPOOF_OS_RELEASE="6.0.0"
export MOZ_AVOID_OPENGL_ALTOGETHER=1
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
# ---- WRITABLE HOME/PROFILE UNDER /tmp (THE uid-1001 spawn fix) ----------
# `spawn linux { ... }` runs Firefox as a NON-hostowner uid (observed uid=1001),
# but HOME=/root and the seeded profile /root/.ff-profile are owned by root
# (uid 0). Firefox as uid 1001 then CANNOT write its profile (the async
# storage / places-SQLite / profile-lock worker fails), and MOZ_LOG_FILE=
# /root/moz.log is never even created (confirmed: `cat /root/moz.log` ->
# "No such file"). The main thread g_cond_wait's for that storage worker's
# completion signal which never comes -> the all-threads-parked startup hang
# (no xdg_toplevel, no wl_shm commit). FIX: relocate EVERY writable path to
# world-writable /tmp (1777, writable by uid 1001) and COPY the seeded prefs
# there at launch so Firefox owns a fully-writable profile.
# THE PREFS-DELIVERY FIX. `spawn linux { ... }` runs Firefox as a NON-hostowner
# uid (observed uid=1001), but Hamnix tmpfs assigns NEW files/dirs owner uid 0
# (it does not honour the caller's fsuid), so a plain `mkdir "$FFHOME/.ff-profile"`
# yields a ROOT-owned 0755 dir that uid 1001 then CANNOT write prefs.js into — the
# seed copy silently fails and Firefox launches with DEFAULT prefs (no
# gfx.webrender.software / no software-render forcing), taking a GL/compositor
# path that cannot work here. Confirmed by "[openat-enoent]
# /tmp/ffhome/.ff-profile/prefs.js" on the serial. FIX: `umask 000` so mkdir -p
# creates every profile dir mode 0777 REGARDLESS of the tmpfs-assigned owner, so
# the uid-1001 process can write prefs.js/user.js into them. Also make FFHOME
# pid-unique so a stale root-owned /tmp/ffhome from any earlier spawn can never
# shadow it. (chmod -R is kept as a belt but is a no-op on root-owned nodes.)
umask 000
FFHOME="/tmp/ffhome.$$"
rm -rf "$FFHOME" 2>/dev/null
mkdir -p "$FFHOME/.ff-profile" "$FFHOME/.cache" "$FFHOME/.config" "$FFHOME/.mozilla"
# seed prefs from the WORLD-READABLE seed under /usr (uid 1001 may not
# traverse root-owned /root) into the now-world-writable /tmp profile.
cp /usr/lib/firefox-esr/ff-profile-seed/prefs.js "$FFHOME/.ff-profile/prefs.js" 2>/dev/null || true
cp /usr/lib/firefox-esr/ff-profile-seed/user.js  "$FFHOME/.ff-profile/user.js"  2>/dev/null || true
chmod -R 0777 "$FFHOME" 2>/dev/null || true
# PROVE the prefs landed (else Firefox silently runs GL-path defaults).
if [ -s "$FFHOME/.ff-profile/prefs.js" ]; then echo "[FF-DIAG] prefs.js delivered ($(wc -l < "$FFHOME/.ff-profile/prefs.js") lines)"; else echo "[FF-DIAG] prefs.js MISSING — Firefox will use GL-path defaults!"; fi
# DIAGNOSTICS: the process our launch pipe reads is a SHORT-LIVED launcher fork
# that returns 255; the REAL firefox forks off (observed pid), REDIRECTS its own
# stdio (so no more [FF] serial output) and then DEADLOCKS with all ~13 threads
# parked in the Gecko child-process IPC handshake (threads seen blocked in
# read() on pipes fd7/fd0, futex, and socket(41)/sendmsg(46)/recvmsg(47) on an
# AF_UNIX socketpair — the parent<->content/GPU channel). Because that process
# closes stdio, MOZ_LOG must go to a FILE, and we DUMP it AFTER a settle delay so
# the still-running deadlocked process's log (which pinpoints the IPC gap) is
# captured. Write per-process logs: MOZ_LOG_FILE gets a .child-N suffix per
# child, so we dump EVERY moz.log* file, not just the parent's.
# PER-PID log files (%PID) so the parent AND each content/GPU child write
# their OWN moz.<pid>.log — the cross-process IPC handshake stall needs the
# CHILD's IPDL/MessageChannel trace, not just the parent's. ipc/IPDL first so
# the earliest channel-open + Bridge/Endpoint messages land before any hang.
export MOZ_LOG='ipc:5,IPDL:5,MessageChannel:5,Widget:5,WidgetWayland:5,nsWindow:5,Compositor:5,WebRender:5,ProcessHangMon:5,sync,timestamp'
export MOZ_LOG_FILE="$FFHOME/moz.%PID.log"
export HOME="$FFHOME"
export XDG_CONFIG_HOME="$FFHOME/.config"
export XDG_CACHE_HOME="$FFHOME/.cache"
export XDG_DATA_HOME="$FFHOME/.local/share"
export TMPDIR=/tmp
# Fontconfig: libfontconfig must locate its config, else gfxPlatformGtk font
# -list init (FcInitLoadConfigAndFonts) fails and — critically — its font-init
# WORKER thread aborts without signalling the main thread's join-futex, so the
# main thread parks FOREVER (the observed task-35 futex-wait deadlock, uaddr
# ~0x20b8ea650). PRIOR form set FONTCONFIG_FILE to the ABSOLUTE path
# /etc/fonts/fonts.conf; fontconfig's FcConfigFileExists then reported "Cannot
# load default config file: No such file: (null)" — it rejects the absolute
# value. The CANONICAL fontconfig override is a BASENAME resolved through
# FONTCONFIG_PATH: FONTCONFIG_FILE=fonts.conf + FONTCONFIG_PATH=/etc/fonts.
# That is what fontconfig's own FcConfigGetFilename search expects.
export FONTCONFIG_FILE=fonts.conf
export FONTCONFIG_PATH=/etc/fonts
export FONTCONFIG_SYSROOT=/
export G_SLICE=always-malloc
export G_MESSAGES_DEBUG=all
mkdir -p "$FFHOME/.cache" "$FFHOME/.mozilla" /run
# drop any stale profile lock from a prior crashed run
rm -f "$FFHOME/.ff-profile/lock" "$FFHOME/.ff-profile/.parentlock" 2>/dev/null
# ---- FONT DIAGNOSTICS (serial): prove whether the namespace can SEE + READ
# the fontconfig config, and echo the resolved env. This pinpoints whether the
# "(null)" config failure is an env-propagation gap, a namespace file-access
# gap, or a fontconfig path-resolution quirk. Cheap; prints a few [FF-DIAG]
# lines then continues to launch. ----
echo "[FF-DIAG] uid=$(id -u 2>/dev/null) HOME=$HOME FFHOME=$FFHOME"
# prove the writable profile dir really IS writable by this uid
if ( : > "$FFHOME/.ff-profile/.wtest" ) 2>/dev/null; then echo "[FF-DIAG] profile dir IS writable"; rm -f "$FFHOME/.ff-profile/.wtest"; else echo "[FF-DIAG] profile dir NOT writable"; fi
ls -ld "$FFHOME" "$FFHOME/.ff-profile" 2>&1 | while IFS= read -r l; do echo "[FF-DIAG] home: $l"; done
echo "[FF] launching firefox-esr (native wayland)"
# Capture the launcher fork's exit code THROUGH the pipe (dash has no
# PIPESTATUS): the `echo FFEXIT=$?` streams to serial as "[FF] FFEXIT=<code>".
{ /usr/lib/firefox-esr/firefox-esr \
    -profile "$FFHOME/.ff-profile" -no-remote -new-instance 'about:blank' 2>&1
  echo "FFEXIT=$?"
} | while IFS= read -r line; do echo "[FF] $line"; done
echo "[FF] firefox pipeline ended"
# The REAL forked firefox keeps running (deadlocked). Let it settle, then dump
# EVERY moz*.log* (parent + per-child) so the IPC-handshake stall is captured.
echo "[FF-POST] settling 40s to let the forked firefox write its MOZ_LOG ..."
i=0; while [ "$i" -lt 40 ]; do sleep 1; i=$((i+1)); done
# FLUSH THE MOZ_LOG (the 0-byte-parent-log fix). Firefox's NSPR log buffers its
# MOZ_LOG output and, even with `sync`, the buffered tail is only guaranteed to
# hit the file on PR_Close at shutdown. A DEADLOCKED parent never exits, so its
# moz.<pid>.log stays 0 bytes and the IPC-handshake trace we need is invisible
# (validated on the host: a freely-running firefox writes MBs; the Hamnix
# deadlocked parent wrote 0). Send SIGTERM to every firefox-esr process to drive
# its shutdown path (PR_Close -> flush) BEFORE dumping. Best-effort: use whatever
# the busybox rootfs provides (pkill or a /proc scan); a still-parked handler
# just means we fall back to whatever `sync` already flushed.
echo "[FF-POST] SIGTERM firefox-esr to flush buffered MOZ_LOG ..."
if command -v pkill >/dev/null 2>&1; then
    pkill -TERM -f firefox-esr 2>/dev/null || true
else
    for pd in /proc/[0-9]*; do
        c=$(tr '\0' ' ' < "$pd/cmdline" 2>/dev/null)
        case "$c" in *firefox-esr*) kill -TERM "${pd#/proc/}" 2>/dev/null || true;; esac
    done
fi
i=0; while [ "$i" -lt 5 ]; do sleep 1; i=$((i+1)); done
echo "[FF-POST] === $FFHOME listing ==="
ls -la "$FFHOME" 2>&1 | while IFS= read -r l; do echo "[FF-POST] $l"; done
# Firefox names its logs moz.-main.<pid>.log.moz_log (parent) and
# moz.-child.<pid>.log.child-N.moz_log (children) — the `.moz_log` suffix means
# the previous `moz.*.log` / `moz.log*` globs matched NEITHER, so the dump was
# always empty even when content existed. Enumerate every log file by content
# suffix instead, and dump the IPC-relevant tail of each.
for f in "$FFHOME"/*moz_log "$FFHOME"/moz.*.log "$FFHOME"/moz.log*; do
    [ -e "$f" ] || continue
    echo "[FF-POST] === $f ($(wc -l < "$f" 2>/dev/null) lines) ==="
    # Surface the IPC/handshake-relevant lines first (bounded), then the tail.
    grep -aE "ipc|IPDL|MessageChannel|Bridge|Endpoint|Open|Connect|handshake|error|fail|abort|ABORT" "$f" 2>/dev/null \
        | tail -n 80 | while IFS= read -r l; do echo "[FF-LOG] $l"; done
    tail -n 60 "$f" 2>/dev/null | while IFS= read -r l; do echo "[FF-TAIL] $l"; done
done
FFLAUNCH
chmod +x "$ROOTFS/ff-launch.sh"
echo "[stage-ff] baked native-wayland launcher: /ff-launch.sh"

echo "[stage-ff] DONE. rootfs now carries firefox-esr + GTK3 closure."
echo "[stage-ff]   payload: $FF_DU under /usr/lib/firefox-esr"
echo "[stage-ff]   verify:  readelf -d $ROOTFS/usr/lib/firefox-esr/libxul.so | grep NEEDED"
echo "[stage-ff]   NOTE: grow the live rootfs — HAMNIX_ROOTFS_SIZE_MB=768 (or more)."
echo "[stage-ff] Next: HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB=768 bash scripts/build_installer_img.sh"
[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"
