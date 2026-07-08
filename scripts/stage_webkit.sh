#!/usr/bin/env bash
# scripts/stage_webkit.sh — host-side, one-time: stage the UNMODIFIED Debian
# WebKitGTK 4.1 engine (MiniBrowser reference browser + the WebKit multi-process
# helpers WebKitWebProcess / WebKitNetworkProcess / WebKitGPUProcess + the
# injected-bundle) and its REAL runtime shared-object closure into the
# debian-minbase fixture rootfs, so the full-mirror live image
# (HAMNIX_LIVE_MINIMAL=0) carries a real MODERN-WEB browser engine that runs as
# a NATIVE Wayland client of the in-kernel compositor.
#
# WHY WebKit and not Firefox: Firefox (Gecko) deadlocks in a Gecko-internal
# early-init circular wait that is engine-specific (a Qt5 app + weston/foot GTK
# clients all render fine on the same wl_shm path). WebKitGTK is a DIFFERENT
# engine (WebKit) on the proven GTK3 path. Like Firefox it is multi-process
# (UIProcess in MiniBrowser + WebProcess + NetworkProcess), so it exercises the
# session's fork/exec + AF_UNIX socketpair fd-inherit + SCM_RIGHTS IPC — but its
# render bring-up is independent of Gecko's, so it may map + paint where Firefox
# cannot.
#
# SOFTWARE RENDER ONLY. WebKit draws with Skia's CPU raster backend and presents
# into a wl_shm buffer when compositing is disabled
# (WEBKIT_DISABLE_COMPOSITING_MODE=1) — no Mesa/EGL/GBM/DRM. libwebkit2gtk
# DT_NEEDED-links libwayland-egl (kept), but libEGL/libGL/libgbm are only
# dlopen'd for the accelerated path; they are absent here so WebKit falls back to
# the pure-software wl_shm present path (same as Firefox's swgl fallback).
#
# Run scripts/stage_weston_term.sh FIRST (glibc 2.41 upgrade + fontconfig cache
# + xkb + DejaVu fonts + the wayland/cairo/pango/glib/GTK3 base closure). This
# script REUSES all of that and adds the WebKit engine + its extra closure
# (gstreamer, libsoup-3, icu-76, libxml2/xslt, harfbuzz-icu, lcms2, woff2,
# libmanette, libseccomp, systemd, flite, ...).
#
# Libs are COPIED FROM THE HOST (trixie — libwebkit2gtk-4.1 2.52.x, matching the
# fixture's staged glibc 2.41), like stage_qt_app.sh / stage_weston_term.sh copy
# host libs. No apt-get, no sudo, idempotent.
#
# Env:
#   ROOTFS  target rootfs (default: tests/distros/debian-minbase/rootfs)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$HERE/tests/distros/debian-minbase/rootfs}"
HOSTLIB="/usr/lib/x86_64-linux-gnu"
WK_LIBEXEC="$HOSTLIB/webkit2gtk-4.1"

if [ ! -d "$ROOTFS" ]; then
    echo "[stage-webkit] ERROR: $ROOTFS absent. Populate it first."; exit 1
fi
if [ ! -e "$ROOTFS/usr/bin/weston-terminal" ]; then
    echo "[stage-webkit] ERROR: weston base not staged; run stage_weston_term.sh first."; exit 1
fi
if [ ! -e "$HOSTLIB/libwebkit2gtk-4.1.so.0" ]; then
    echo "[stage-webkit] ERROR: host libwebkit2gtk-4.1 absent. apt install libwebkit2gtk-4.1-0 gir1.2-webkit2-4.1 webkit2gtk-driver."; exit 1
fi
if [ ! -x "$WK_LIBEXEC/MiniBrowser" ]; then
    echo "[stage-webkit] ERROR: MiniBrowser absent ($WK_LIBEXEC/MiniBrowser). apt install webkit2gtk-driver (or libwebkit2gtk-4.1-0 which ships MiniBrowser)."; exit 1
fi

# --- 1. copy the WebKit libexec tree (helper procs + injected bundle) ----
# libwebkit2gtk locates its multi-process helpers + the MiniBrowser binary in
# its compiled-in libexec dir. Copy the WHOLE tree verbatim (the helpers are
# fork+exec'd by soname/path, not DT_NEEDED-discoverable).
echo "[stage-webkit] staging WebKit libexec tree ($WK_LIBEXEC) ..."
mkdir -p "$ROOTFS$WK_LIBEXEC"
cp -a "$WK_LIBEXEC/." "$ROOTFS$WK_LIBEXEC/"
# convenience: /usr/bin/MiniBrowser -> the libexec binary
ln -sf "$WK_LIBEXEC/MiniBrowser" "$ROOTFS/usr/bin/MiniBrowser"
# the injected-bundle .so also lives under /usr/lib (webkit loads it by path)
for ib in "$HOSTLIB"/webkit2gtk-4.1/injected-bundle; do :; done

# --- 2. copy the WebKit engine libs + the resource dir --------------------
# libwebkit2gtk + libjavascriptcoregtk are large (~120 MiB combined); copy the
# real (versioned) files + recreate the sonames. These are DT_NEEDED-walked
# below too, but seed them explicitly so their own deps are pulled.
for real in libwebkit2gtk-4.1.so.0 libjavascriptcoregtk-4.1.so.0; do
    src="$(readlink -f "$HOSTLIB/$real")"
    cp -a "$src" "$ROOTFS$HOSTLIB/$(basename "$src")"
    ln -sf "$(basename "$src")" "$ROOTFS$HOSTLIB/$real"
done
# WebKit's shared gresources (icons, injected-bundle default resources)
if [ -d /usr/share/webkitgtk-4.1 ]; then
    mkdir -p "$ROOTFS/usr/share/webkitgtk-4.1"
    cp -a /usr/share/webkitgtk-4.1/. "$ROOTFS/usr/share/webkitgtk-4.1/"
fi

# --- 3. walk the full DT_NEEDED closure of the engine + helpers ----------
# Seed from MiniBrowser + every WebKit helper binary + the two engine libs +
# the injected-bundle .so. Resolve each soname against the HOST libdir, copy any
# not already in the rootfs (weston/GTK3 base already carries cairo/pango/glib/
# gdk-pixbuf/gtk3/freetype/fontconfig/harfbuzz/wayland/xkb).
python3 - "$ROOTFS" "$HOSTLIB" "$WK_LIBEXEC" <<'PY'
import os, sys, subprocess, shutil, glob
ROOTFS, HOSTLIB, LIBEXEC = sys.argv[1], sys.argv[2], sys.argv[3]
LIBDIRS = ["usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu","usr/lib","lib","usr/lib64","lib64"]

def needed(p):
    try: out=subprocess.check_output(["readelf","-d",p],stderr=subprocess.DEVNULL).decode()
    except Exception: return []
    return [l.split("[")[1].split("]")[0] for l in out.splitlines()
            if "(NEEDED)" in l and "[" in l]

def in_rootfs(so):
    for d in LIBDIRS:
        if os.path.exists(os.path.join(ROOTFS,d,so)): return True
    return False

def host_path(so):
    for d in LIBDIRS:
        c=os.path.join("/",d,so)
        if os.path.exists(c): return os.path.realpath(c)
    return None

roots=[]
for b in ("MiniBrowser","WebKitWebProcess","WebKitNetworkProcess","WebKitGPUProcess"):
    p=os.path.join(ROOTFS+LIBEXEC,b)
    if os.path.exists(p): roots.append(p)
roots += glob.glob(os.path.join(ROOTFS+LIBEXEC,"injected-bundle","*.so"))
roots += [os.path.join(ROOTFS,HOSTLIB.lstrip("/"),"libwebkit2gtk-4.1.so.0"),
          os.path.join(ROOTFS,HOSTLIB.lstrip("/"),"libjavascriptcoregtk-4.1.so.0")]

seen=set(); work=[]; copied=[]; missing=set()
for r in roots:
    if os.path.exists(r): work += needed(r)
while work:
    so=work.pop()
    if so in seen: continue
    seen.add(so)
    if in_rootfs(so):
        for d in LIBDIRS:
            p=os.path.join(ROOTFS,d,so)
            if os.path.exists(p): work += needed(p); break
        continue
    hp=host_path(so)
    if hp is None: missing.add(so); continue
    for d in ("usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu"):
        dst=os.path.join(ROOTFS,d,so)
        os.makedirs(os.path.dirname(dst),exist_ok=True)
        # preserve the soname->real symlink shape
        real=os.path.realpath(hp)
        rn=os.path.basename(real)
        shutil.copy2(real, os.path.join(os.path.dirname(dst), rn))
        if rn!=so:
            lp=dst
            try:
                if os.path.islink(lp) or os.path.exists(lp): os.remove(lp)
            except OSError: pass
            os.symlink(rn, lp)
    copied.append(so); work += needed(hp)
print(f"[stage-webkit] copied {len(copied)} NEW closure libs")
print("[stage-webkit]  new:", ", ".join(sorted(copied)) or "(none)")
if missing:
    print("[stage-webkit] NOTE unresolved sonames (dlopen/bundled/absent):", sorted(missing))
PY

# --- 4. GdkPixbuf loaders (dlopen'd) + regenerated cache -----------------
PIXBUF_REL="usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/2.10.0"
if [ -d "$HOSTLIB/gdk-pixbuf-2.0/2.10.0/loaders" ]; then
    mkdir -p "$ROOTFS/$PIXBUF_REL/loaders"
    cp -a "$HOSTLIB/gdk-pixbuf-2.0/2.10.0/loaders/." "$ROOTFS/$PIXBUF_REL/loaders/"
    python3 - "$ROOTFS" "$HOSTLIB" "$PIXBUF_REL" <<'PY'
import os,sys,subprocess,shutil,glob
ROOTFS,HOSTLIB,REL=sys.argv[1],sys.argv[2],sys.argv[3]
LIBDIRS=["usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu","usr/lib","lib"]
def needed(p):
    try:o=subprocess.check_output(["readelf","-d",p],stderr=subprocess.DEVNULL).decode()
    except Exception:return []
    return [l.split("[")[1].split("]")[0] for l in o.splitlines() if "(NEEDED)" in l and "[" in l]
def in_rootfs(so):
    for d in LIBDIRS:
        if os.path.exists(os.path.join(ROOTFS,d,so)):return True
    return False
def host_path(so):
    for d in LIBDIRS:
        c=os.path.join("/",d,so)
        if os.path.exists(c):return os.path.realpath(c)
    return None
seen=set();work=[];n=0
for lo in glob.glob(os.path.join(ROOTFS,REL,"loaders","*.so")): work+=needed(lo)
while work:
    so=work.pop()
    if so in seen:continue
    seen.add(so)
    if in_rootfs(so):continue
    hp=host_path(so)
    if hp is None:continue
    real=os.path.realpath(hp);rn=os.path.basename(real)
    for d in ("usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu"):
        dst=os.path.join(ROOTFS,d,rn);os.makedirs(os.path.dirname(dst),exist_ok=True);shutil.copy2(real,dst)
        if rn!=so:
            lp=os.path.join(ROOTFS,d,so)
            try:
                if os.path.islink(lp) or os.path.exists(lp): os.remove(lp)
            except OSError: pass
            os.symlink(rn,lp)
    n+=1;work+=needed(hp)
print(f"[stage-webkit] staged {n} gdk-pixbuf loader deps")
PY
    QL="$HOSTLIB/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders"
    [ -x "$QL" ] || QL="$(command -v gdk-pixbuf-query-loaders || true)"
    if [ -n "$QL" ] && [ -x "$QL" ]; then
        "$QL" "$ROOTFS/$PIXBUF_REL/loaders/"*.so 2>/dev/null | sed "s|$ROOTFS/||g" > "$ROOTFS/$PIXBUF_REL/loaders.cache"
        echo "[stage-webkit] wrote gdk-pixbuf loaders.cache"
    fi
fi

# --- 5. GIO modules (glib-networking TLS + others; libsoup uses gio) ------
GIO_REL="usr/lib/x86_64-linux-gnu/gio/modules"
if [ -d "$HOSTLIB/gio/modules" ]; then
    mkdir -p "$ROOTFS/$GIO_REL"
    cp -a "$HOSTLIB/gio/modules/." "$ROOTFS/$GIO_REL/" 2>/dev/null || true
    # walk the gio modules' closure (glib-networking pulls gnutls/p11-kit)
    python3 - "$ROOTFS" "$HOSTLIB" "$GIO_REL" <<'PY'
import os,sys,subprocess,shutil,glob
ROOTFS,HOSTLIB,REL=sys.argv[1],sys.argv[2],sys.argv[3]
LIBDIRS=["usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu","usr/lib","lib"]
def needed(p):
    try:o=subprocess.check_output(["readelf","-d",p],stderr=subprocess.DEVNULL).decode()
    except Exception:return []
    return [l.split("[")[1].split("]")[0] for l in o.splitlines() if "(NEEDED)" in l and "[" in l]
def in_rootfs(so):
    for d in LIBDIRS:
        if os.path.exists(os.path.join(ROOTFS,d,so)):return True
    return False
def host_path(so):
    for d in LIBDIRS:
        c=os.path.join("/",d,so)
        if os.path.exists(c):return os.path.realpath(c)
    return None
seen=set();work=[];n=0
for lo in glob.glob(os.path.join(ROOTFS,REL,"*.so")): work+=needed(lo)
while work:
    so=work.pop()
    if so in seen:continue
    seen.add(so)
    if in_rootfs(so):continue
    hp=host_path(so)
    if hp is None:continue
    real=os.path.realpath(hp);rn=os.path.basename(real)
    for d in ("usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu"):
        dst=os.path.join(ROOTFS,d,rn);os.makedirs(os.path.dirname(dst),exist_ok=True);shutil.copy2(real,dst)
        if rn!=so:
            lp=os.path.join(ROOTFS,d,so)
            try:
                if os.path.islink(lp) or os.path.exists(lp): os.remove(lp)
            except OSError: pass
            os.symlink(rn,lp)
    n+=1;work+=needed(hp)
if os.path.exists(os.path.join(ROOTFS,REL,"giomodule.cache")): pass
print(f"[stage-webkit] staged {n} gio-module deps")
PY
    GQ="$HOSTLIB/glib-2.0/gio-querymodules"
    [ -x "$GQ" ] || GQ="$(command -v gio-querymodules || true)"
    [ -n "$GQ" ] && [ -x "$GQ" ] && "$GQ" "$ROOTFS/$GIO_REL" 2>/dev/null && echo "[stage-webkit] wrote giomodule.cache" || true
fi

# --- 6. GSettings schemas (GTK reads org.gtk.Settings.*) -----------------
SCHEMA_REL="usr/share/glib-2.0/schemas"
mkdir -p "$ROOTFS/$SCHEMA_REL"
for x in /usr/share/glib-2.0/schemas/org.gtk.*.gschema.xml \
         /usr/share/glib-2.0/schemas/org.gnome.desktop.interface.gschema.xml \
         /usr/share/glib-2.0/schemas/gschemas.compiled; do
    [ -e "$x" ] && cp -a "$x" "$ROOTFS/$SCHEMA_REL/" 2>/dev/null || true
done
if command -v glib-compile-schemas >/dev/null 2>&1; then
    glib-compile-schemas "$ROOTFS/$SCHEMA_REL" >/dev/null 2>&1 && echo "[stage-webkit] compiled gschemas.compiled" || true
fi

# --- 7. ICU data + CA certs (libsoup TLS for https; harmless for http) ---
# icudata is DT_NEEDED-walked already. CA certs let https validate (http needs
# none). Copy the host bundle if present.
if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
    mkdir -p "$ROOTFS/etc/ssl/certs"
    cp -a /etc/ssl/certs/ca-certificates.crt "$ROOTFS/etc/ssl/certs/" 2>/dev/null || true
fi

# --- 8. a local CSS-styled HTML test page --------------------------------
cat > "$ROOTFS/page.html" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Hamnix WebKit</title>
<style>
  body{background:#0b3d91;color:#fff;font-family:sans-serif;margin:0;padding:40px}
  h1{color:#ffd200;font-size:44px;margin:0 0 20px}
  .box{background:#e02020;border-radius:16px;padding:24px;max-width:620px}
  p{font-size:20px;line-height:1.5}
  a{color:#7CFC00;font-weight:bold}
  .sw{display:inline-block;width:60px;height:60px;margin-right:8px;border-radius:8px}
</style></head>
<body>
  <h1>WebKitGTK on Hamnix</h1>
  <div class="box">
    <p>A real modern-web engine rendering CSS from the Linux namespace.</p>
    <p><span class="sw" style="background:#00c2ff"></span>
       <span class="sw" style="background:#ffd200"></span>
       <span class="sw" style="background:#7CFC00"></span></p>
    <p><a href="https://webkit.org/">webkit.org</a></p>
  </div>
</body></html>
HTML
echo "[stage-webkit] wrote /page.html (CSS-styled test page)"

# --- 9. baked native-Wayland launcher (/webkit-launch.sh) ----------------
# One short serial line: spawn linux { /bin/sh /webkit-launch.sh [URL] }
cat > "$ROOTFS/webkit-launch.sh" <<'WKL'
#!/bin/sh
# /webkit-launch.sh [URL] — MiniBrowser (WebKitGTK) as a native wl client.
URL="${1:-file:///page.html}"
export XDG_RUNTIME_DIR=/run
export WAYLAND_DISPLAY=wayland-0
export GDK_BACKEND=wayland
# pure software: no EGL/GL/DMABuf compositing; Skia CPU raster -> wl_shm.
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export LIBGL_ALWAYS_SOFTWARE=1
# WebKit's bwrap sandbox needs user-namespaces / seccomp we don't provide; the
# UIProcess enables it opt-in (MiniBrowser doesn't), but belt-disable so the
# WebProcess/NetworkProcess fork+exec never tries to enter bwrap.
export WEBKIT_FORCE_SANDBOX=0
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
# helper-process path (belt; matches the compiled-in libexec dir)
export WEBKIT_EXEC_PATH=/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1
# writable HOME/profile under world-writable /tmp (spawn linux runs as uid 1001;
# tmpfs assigns new nodes owner 0, so umask 000 makes them uid-1001-writable).
umask 000
WKHOME="/tmp/wkhome.$$"
rm -rf "$WKHOME" 2>/dev/null
mkdir -p "$WKHOME/.cache" "$WKHOME/.config" "$WKHOME/.local/share"
chmod -R 0777 "$WKHOME" 2>/dev/null || true
export HOME="$WKHOME"
export XDG_CONFIG_HOME="$WKHOME/.config"
export XDG_CACHE_HOME="$WKHOME/.cache"
export XDG_DATA_HOME="$WKHOME/.local/share"
export TMPDIR=/tmp
export FONTCONFIG_FILE=fonts.conf
export FONTCONFIG_PATH=/etc/fonts
export G_MESSAGES_DEBUG=all
export GST_REGISTRY="$WKHOME/gst.reg"
export GST_REGISTRY_UPDATE=no
echo "[WK] uid=$(id -u 2>/dev/null) HOME=$HOME URL=$URL"
echo "[WK] launching MiniBrowser (WebKitGTK, software wl_shm)"
{ /usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/MiniBrowser "$URL" 2>&1
  echo "WKEXIT=$?"
} | while IFS= read -r line; do echo "[WK] $line"; done
echo "[WK] MiniBrowser pipeline ended"
WKL
chmod +x "$ROOTFS/webkit-launch.sh"
echo "[stage-webkit] baked native-wayland launcher: /webkit-launch.sh"

WK_DU="$(du -sh "$ROOTFS$WK_LIBEXEC" 2>/dev/null | awk '{print $1}')"
echo "[stage-webkit] DONE. rootfs now carries WebKitGTK 4.1 (MiniBrowser + helpers, libexec $WK_DU)."
echo "[stage-webkit] Next: HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB=1024 bash scripts/build_installer_img.sh"
