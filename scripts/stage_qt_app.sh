#!/usr/bin/env bash
# scripts/stage_qt_app.sh — host-side, one-time: stage a minimal Qt5 WIDGETS
# app (qt_hello) + its full runtime shared-object closure + the Qt Wayland
# platform plugin (libqwayland-generic.so) + the xdg-shell shell-integration
# plugin into the debian-minbase fixture rootfs, so the full-mirror live image
# (HAMNIX_LIVE_MINIMAL=0) can prove that a Qt toolkit app renders as a NATIVE
# Wayland client of the in-kernel compositor — broadening GUI-from-Linux-ns
# coverage beyond the GTK (weston/foot) toolkit.
#
# Qt5 Widgets draw via the RASTER paint engine (QBackingStore) into a wl_shm
# buffer — NO GL/EGL needed (QT_QPA_PLATFORM=wayland + the generic plugin's
# shm backing store). This mirrors the software-render path GTK uses.
#
# Run scripts/stage_weston_term.sh FIRST (glibc 2.41 upgrade + fontconfig
# cache + xkb + fonts + the wayland/freetype/harfbuzz/glib base closure). This
# script REUSES all of that and adds the Qt5 delta.
#
# The qt_hello binary must be pre-compiled on the host (see the companion
# build in the stage-qt driver); pass its path via QT_HELLO_BIN. Qt5 runtime
# libs + plugins are COPIED FROM THE HOST (trixie 5.15.15 — same version the
# fixture's staged glibc 2.41 supports), like stage_weston_term.sh copies host
# libs. No apt-get, no sudo, idempotent.
#
# Env:
#   ROOTFS        target rootfs (default: tests/distros/debian-minbase/rootfs)
#   QT_HELLO_BIN  path to the compiled qt_hello binary (REQUIRED)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$HERE/tests/distros/debian-minbase/rootfs}"
QT_HELLO_BIN="${QT_HELLO_BIN:-}"
HOSTLIB="/usr/lib/x86_64-linux-gnu"
QT_PLUGROOT="$HOSTLIB/qt5/plugins"

if [ ! -d "$ROOTFS" ]; then
    echo "[stage-qt] ERROR: $ROOTFS absent. Populate it first."; exit 1
fi
if [ ! -e "$ROOTFS/usr/bin/weston-terminal" ]; then
    echo "[stage-qt] ERROR: weston-terminal not staged; run stage_weston_term.sh first."; exit 1
fi
if [ -z "$QT_HELLO_BIN" ] || [ ! -f "$QT_HELLO_BIN" ]; then
    echo "[stage-qt] ERROR: QT_HELLO_BIN must point at the compiled qt_hello binary."; exit 1
fi

# Copy the app binary.
install -D -m0755 "$QT_HELLO_BIN" "$ROOTFS/usr/bin/qt_hello"
echo "[stage-qt] staged /usr/bin/qt_hello"

# Copy the Qt Wayland plugin trees WHOLESALE (platform + shell/decoration/
# graphics integrations). These are dlopen'd by Qt at runtime (not
# DT_NEEDED-discoverable), so they must be copied explicitly. Their closures
# are walked below.
mkdir -p "$ROOTFS$QT_PLUGROOT"
for sub in platforms wayland-shell-integration wayland-decoration-client \
           wayland-graphics-integration-client imageformats platforminputcontexts; do
    if [ -d "$QT_PLUGROOT/$sub" ]; then
        mkdir -p "$ROOTFS$QT_PLUGROOT/$sub"
        cp -a "$QT_PLUGROOT/$sub/." "$ROOTFS$QT_PLUGROOT/$sub/" 2>/dev/null || true
        echo "[stage-qt] staged plugin dir: $sub"
    fi
done

# Walk the full DT_NEEDED closure of the app binary + every staged plugin .so,
# resolving each soname against the HOST libdir, copying any not already in the
# rootfs (the weston/foot closure already carries many: freetype, fontconfig,
# harfbuzz, glib, png, zlib, xkbcommon, wayland-client/cursor).
python3 - "$ROOTFS" "$HOSTLIB" "$QT_PLUGROOT" <<'PY'
import os, sys, subprocess, shutil, glob
ROOTFS, HOSTLIB, PLUGROOT = sys.argv[1], sys.argv[2], sys.argv[3]
LIBDIRS = ["usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu","usr/lib","lib"]

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

# Seed the work list: app binary NEEDED + every staged plugin .so NEEDED.
roots=[os.path.join(ROOTFS,"usr/bin/qt_hello")]
for so in glob.glob(os.path.join(ROOTFS+PLUGROOT,"**","*.so"),recursive=True):
    roots.append(so)

seen=set(); work=[]; copied=[]; missing=set()
for r in roots:
    if os.path.exists(r): work += needed(r)
while work:
    so=work.pop()
    if so in seen: continue
    seen.add(so)
    if in_rootfs(so):
        # already present; still walk its deps in case a transitive is missing
        for d in LIBDIRS:
            p=os.path.join(ROOTFS,d,so)
            if os.path.exists(p): work += needed(p); break
        continue
    hp=host_path(so)
    if hp is None: missing.add(so); continue
    for d in ("usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu"):
        dst=os.path.join(ROOTFS,d,so)
        os.makedirs(os.path.dirname(dst),exist_ok=True); shutil.copy2(hp,dst)
    copied.append(so); work += needed(hp)

# Also walk closures of the plugin .so's themselves (they DT_NEED Qt5WaylandClient etc.)
print(f"[stage-qt] copied {len(copied)} NEW closure libs: {', '.join(sorted(copied)) or '(none)'}")
if missing:
    print("[stage-qt] WARNING unresolved sonames:", sorted(missing)); sys.exit(2)
PY

# Bake a short launcher (mirrors ff-launch.sh): a SHORT command line that
# carries the full Qt/Wayland environment + prefixes stderr with [QT].
cat > "$ROOTFS/qt-launch.sh" <<'QTL'
#!/bin/sh
# /qt-launch.sh — Qt5 widget app as a native Wayland client (see stage_qt_app.sh).
export XDG_RUNTIME_DIR=/run
export WAYLAND_DISPLAY=wayland-0
export QT_QPA_PLATFORM=wayland
export QT_PLUGIN_PATH=/usr/lib/x86_64-linux-gnu/qt5/plugins
export QT_QPA_PLATFORM_PLUGIN_PATH=/usr/lib/x86_64-linux-gnu/qt5/plugins/platforms
# Software render only: no GL. Disable client-side decorations (compositor
# does SSD chrome) to avoid a hard dep on the decoration plugin.
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
export QT_LOGGING_RULES="qt.qpa.*=true"
export LIBGL_ALWAYS_SOFTWARE=1
export HOME=/root
echo "[QT] launching qt_hello (QT_QPA_PLATFORM=$QT_QPA_PLATFORM)"
exec /usr/bin/qt_hello 2>&1 | while IFS= read -r line; do echo "[QT] $line"; done
QTL
chmod +x "$ROOTFS/qt-launch.sh"
echo "[stage-qt] baked native-wayland launcher: /qt-launch.sh"
echo "[stage-qt] DONE. Next: HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB=1792 bash scripts/build_installer_img.sh"
