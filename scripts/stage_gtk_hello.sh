#!/usr/bin/env bash
# scripts/stage_gtk_hello.sh — host-side, one-time: compile the MINIMAL GTK3
# toplevel probe (tests/u-binary/src/gtk_hello/gtk_hello.c) against the host
# libgtk-3 and stage it (+ a native-Wayland launcher) into the debian-minbase
# fixture rootfs. This is the cheap, engine-free reproduction of the "GTK/GDK
# clients stall before get_xdg_surface" symptom that the heavyweight browsers
# (Firefox/WebKitGTK) exhibit — it isolates the cause to the CLIENT side.
#
# FINDING (this staging + scripts/test_gtk_hello.sh): the stall is NOT a
# compositor negotiation gap. gtk-hello connects, binds the full registry,
# allocates its wl_shm buffer, then ABORTS in GTK's ensure_surface_for_gicon
# (a fatal g_assert) while decorating the window, because the gdk-pixbuf SVG
# loader can't be dlopen'd — the loaders.cache held RELATIVE module paths
# (stage_webkit.sh's `sed s|$ROOTFS/||g` stripped the leading slash). The fix
# is to write ABSOLUTE loader paths (stage_webkit.sh now does `s|$ROOTFS/|/|g`,
# matching stage_firefox.sh) and point GDK_PIXBUF_MODULE_FILE at it. This is a
# GENERAL fix: it unblocks the window-map for every GTK/GDK client.
#
# Run scripts/stage_weston_term.sh + scripts/stage_webkit.sh FIRST (they stage
# the GTK3/gdk-pixbuf/librsvg closure + the fixed loaders.cache this reuses).
#   Env: ROOTFS  target rootfs (default: tests/distros/debian-minbase/rootfs)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$HERE/tests/distros/debian-minbase/rootfs}"
SRC="$HERE/tests/u-binary/src/gtk_hello/gtk_hello.c"
HOSTLIB=/usr/lib/x86_64-linux-gnu

[ -d "$ROOTFS" ] || { echo "[stage-gtk] ERROR: $ROOTFS absent."; exit 1; }
[ -f "$SRC" ] || { echo "[stage-gtk] ERROR: $SRC absent."; exit 1; }
[ -e "$HOSTLIB/libgtk-3.so.0" ] || { echo "[stage-gtk] ERROR: host libgtk-3 absent (apt install libgtk-3-0)."; exit 1; }
[ -e "$ROOTFS/$HOSTLIB/libgtk-3.so.0" ] \
    || { echo "[stage-gtk] ERROR: GTK3 not staged in rootfs; run stage_webkit.sh first."; exit 1; }

# --- 1. compile against the host libgtk-3 (manual prototypes; no -dev headers) -
echo "[stage-gtk] compiling gtk_hello ..."
gcc -O2 "$SRC" -o "$ROOTFS/usr/bin/gtk-hello" \
    -l:libgtk-3.so.0 -l:libgobject-2.0.so.0 -l:libglib-2.0.so.0
chmod +x "$ROOTFS/usr/bin/gtk-hello"

# --- 2. ensure the loaders.cache holds ABSOLUTE paths (belt: regen here too) ---
PIXBUF_REL="usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/2.10.0"
QL="$HOSTLIB/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders"
[ -x "$QL" ] || QL="$(command -v gdk-pixbuf-query-loaders || true)"
if [ -n "$QL" ] && [ -x "$QL" ] && [ -d "$ROOTFS/$PIXBUF_REL/loaders" ]; then
    "$QL" "$ROOTFS/$PIXBUF_REL/loaders/"*.so 2>/dev/null \
        | sed "s|$ROOTFS/|/|g" > "$ROOTFS/$PIXBUF_REL/loaders.cache"
    echo "[stage-gtk] regenerated gdk-pixbuf loaders.cache (absolute paths)"
fi

# --- 3. native-Wayland launcher --------------------------------------------
cat > "$ROOTFS/gtk-launch.sh" <<'GKL'
#!/bin/sh
# /gtk-launch.sh — minimal GTK3 toplevel as a native Wayland client. WAYLAND_
# DEBUG=1 emits the wire trace under "[GTKH]" so the harness can see exactly
# which xdg-shell verb the window-map reaches.
export XDG_RUNTIME_DIR=/run
export WAYLAND_DISPLAY=wayland-0
export GDK_BACKEND=wayland
export LIBGL_ALWAYS_SOFTWARE=1
umask 000
GH=/tmp/gtkhome.$$
rm -rf "$GH" 2>/dev/null
mkdir -p "$GH/.cache" "$GH/.config" "$GH/.local/share"
chmod -R 0777 "$GH" 2>/dev/null || true
export HOME="$GH"
export XDG_CONFIG_HOME="$GH/.config"
export XDG_CACHE_HOME="$GH/.cache"
export XDG_DATA_HOME="$GH/.local/share"
export TMPDIR=/tmp
export FONTCONFIG_FILE=fonts.conf
export FONTCONFIG_PATH=/etc/fonts
# gdk-pixbuf loaders (dlopen'd for SVG icon decode during CSD titlebar draw).
# Absolute-path cache so the SVG loader resolves; a relative path aborts GTK
# in ensure_surface_for_gicon before the window ever maps.
export GDK_PIXBUF_MODULE_FILE=/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders.cache
export GDK_PIXBUF_MODULEDIR=/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/2.10.0/loaders
export G_MESSAGES_DEBUG=all
[ "${GTK_WAYLAND_DEBUG:-1}" = "0" ] || export WAYLAND_DEBUG=1
echo "[GTKH] uid=$(id -u 2>/dev/null) HOME=$HOME"
echo "[GTKH] launching gtk-hello (GTK3, software wl_shm)"
{ /usr/bin/gtk-hello 2>&1
  echo "GTKEXIT=$?"
} | while IFS= read -r line; do echo "[GTKH] $line"; done
echo "[GTKH] gtk-hello pipeline ended"
GKL
chmod +x "$ROOTFS/gtk-launch.sh"
echo "[stage-gtk] DONE. staged /usr/bin/gtk-hello + /gtk-launch.sh."
