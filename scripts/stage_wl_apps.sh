#!/usr/bin/env bash
# scripts/stage_wl_apps.sh — host-side, one-time: stage a BROAD set of simple,
# single-process Wayland GUI apps (beyond weston-terminal) into the
# debian-minbase fixture rootfs so the full-mirror live image
# (HAMNIX_LIVE_MINIMAL=0) can prove that "GUI apps from the Linux ns" works
# generally — not just the one weston-terminal.
#
# It stages, layered on top of scripts/stage_weston_term.sh (which MUST have
# run first — this script reuses that closure + fonts + glibc upgrade):
#
#   1. weston-* SIMPLE DEMOS (from the `weston` .deb): raw libwayland /
#      cairo wl_shm clients whose ENTIRE DT_NEEDED closure is already staged
#      by stage_weston_term.sh (identical cairo/pango/wayland set). We just
#      copy the demo binaries + re-walk their closure (copying any straggler).
#        - weston-simple-damage : pure wl_shm, minimal deps (2 libs) — the
#                                 simplest possible native wl client.
#        - weston-flower        : cairo wl_shm, animated — a richer raw client.
#        - weston-smoke         : cairo wl_shm, animated.
#        - weston-eventdemo     : toytoolkit (cairo/pango), like weston-terminal.
#        - weston-clickdot      : toytoolkit, pointer demo.
#
#   2. `foot` (+ footclient): a real, tiny Wayland TERMINAL EMULATOR. NOT a
#      toy — it is a different, independent codebase from weston's toytoolkit,
#      rendering via pixman + fcft (freetype/harfbuzz) into wl_shm (NO GL, NO
#      cairo). Its closure adds only TWO libraries over the weston-terminal
#      set: libfcft.so.4 + libutf8proc.so.3 (everything else — pixman,
#      wayland-client/cursor, xkbcommon, fontconfig, freetype, harfbuzz — is
#      already staged). This is the marquee "second real app" win: a wholly
#      independent toolkit exercising the same wl_shm compositor path.
#
# Requirements (Debian/Ubuntu host): apt-get download + dpkg-deb + readelf.
# No sudo, no install into the host. Idempotent.
#
# Env:
#   ROOTFS  target rootfs (default: tests/distros/debian-minbase/rootfs)
#   WORK    scratch dir for .deb download/extract (default: mktemp)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$HERE/tests/distros/debian-minbase/rootfs}"
WORK="${WORK:-$(mktemp -d --tmpdir hamnix-wlapps.XXXXXX)}"

if [ ! -d "$ROOTFS" ]; then
    echo "[stage-wlapps] ERROR: $ROOTFS absent. Populate it first."
    exit 1
fi
if [ ! -e "$ROOTFS/usr/bin/weston-terminal" ]; then
    echo "[stage-wlapps] ERROR: weston-terminal not staged in $ROOTFS."
    echo "[stage-wlapps]   Run scripts/stage_weston_term.sh FIRST (this script"
    echo "[stage-wlapps]   layers on its closure + fonts + glibc upgrade)."
    exit 1
fi

DEBS="$WORK/debs"; APPROOT="$WORK/approot"
mkdir -p "$DEBS" "$APPROOT"

# --- 1. download the app packages + foot's two NEW closure libs --------
# weston      : carries the weston-* demo binaries (closure already staged).
# foot        : the tiny native wl terminal emulator (+ footclient).
# libfcft4t64 : foot's glyph-rasterizer (freetype/harfbuzz over pixman).
# libutf8proc3: fcft's unicode dep.
# ncurses-term: ships the `foot` terminfo entry (foot's default TERM=foot).
PKGS=(
  weston
  foot
  libfcft4t64 libutf8proc3
  ncurses-term
)
echo "[stage-wlapps] downloading ${#PKGS[@]} packages into $DEBS ..."
( cd "$DEBS" && apt-get download "${PKGS[@]}" >/dev/null 2>&1 ) || {
    echo "[stage-wlapps] ERROR: apt-get download failed (need mirror access)."; exit 1; }

echo "[stage-wlapps] extracting .debs into merged staging tree ..."
for d in "$DEBS"/*.deb; do dpkg-deb -x "$d" "$APPROOT"; done

# --- 2. walk each app's transitive DT_NEEDED closure -------------------
# Resolve each soname against the merged app tree first, then the EXISTING
# rootfs (which already carries the whole weston-terminal closure + upgraded
# glibc). Copy only libs that resolve in the app tree AND are not already in
# the rootfs — i.e. foot's two extras (fcft + utf8proc); the demos add none.
BINS_ENV="weston-simple-damage weston-flower weston-smoke weston-eventdemo weston-clickdot foot footclient"
python3 - "$APPROOT" "$ROOTFS" "$BINS_ENV" <<'PY'
import os, sys, subprocess, shutil
APPROOT, ROOTFS, BINSTR = sys.argv[1], sys.argv[2], sys.argv[3]
LIBDIRS = ["usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu",
           "usr/lib","lib","usr/lib64","lib64"]
BINS = ["usr/bin/"+b for b in BINSTR.split()]

def needed(p):
    try: out=subprocess.check_output(["readelf","-d",p],stderr=subprocess.DEVNULL).decode()
    except Exception: return []
    return [l.split("[")[1].split("]")[0] for l in out.splitlines()
            if "(NEEDED)" in l and "[" in l]

def find(soname, trees):
    for tree in trees:
        for d in LIBDIRS:
            c=os.path.join(tree,d,soname)
            if os.path.exists(c): return os.path.realpath(c), tree
    return None,None

seen=set(); work=[]; copied=[]; missing=set()
for b in BINS:
    bp=os.path.join(APPROOT,b)
    if os.path.exists(bp): work += needed(bp)
    else: print(f"[stage-wlapps] NOTE: {b} not in app tree (skipped)")
while work:
    so=work.pop()
    if so in seen: continue
    seen.add(so)
    # already present in the rootfs? then leave it (weston-terminal closure).
    rp_root,_=find(so,[ROOTFS])
    if rp_root is not None:
        work += needed(rp_root); continue
    # otherwise pull it from the app tree.
    rp,tree=find(so,[APPROOT])
    if rp is None: missing.add(so); continue
    dst=os.path.join(ROOTFS,"usr/lib/x86_64-linux-gnu",so)
    os.makedirs(os.path.dirname(dst),exist_ok=True); shutil.copy2(rp,dst)
    dst2=os.path.join(ROOTFS,"lib/x86_64-linux-gnu",so)
    os.makedirs(os.path.dirname(dst2),exist_ok=True); shutil.copy2(rp,dst2)
    copied.append(so)
    work += needed(rp)
# copy the app binaries
staged=[]
for b in BINS:
    src=os.path.join(APPROOT,b)
    if os.path.exists(src):
        dst=os.path.join(ROOTFS,b)
        os.makedirs(os.path.dirname(dst),exist_ok=True)
        shutil.copy2(src,dst); os.chmod(dst,0o755); staged.append(os.path.basename(b))
print(f"[stage-wlapps] staged binaries: {', '.join(staged)}")
print(f"[stage-wlapps] copied {len(copied)} NEW closure libs: {', '.join(sorted(copied)) or '(none — all already present)'}")
if missing:
    print("[stage-wlapps] WARNING unresolved sonames:", sorted(missing)); sys.exit(2)
PY

# --- 3. foot runtime data: config + terminfo ---------------------------
# foot's default TERM=foot needs the `foot` terminfo entry or it aborts at
# startup ("could not find terminfo"). Stage foot/foot-direct/foot+base from
# ncurses-term. /usr/share/terminfo is NOT pruned by FULL_DEBIAN_PRUNE.
if [ -d "$APPROOT/usr/share/terminfo/f" ]; then
    mkdir -p "$ROOTFS/usr/share/terminfo/f"
    for t in foot foot-direct "foot+base"; do
        s="$APPROOT/usr/share/terminfo/f/$t"
        [ -f "$s" ] && install -D -m0644 "$s" "$ROOTFS/usr/share/terminfo/f/$t"
    done
    echo "[stage-wlapps] staged foot terminfo (f/foot, f/foot-direct)"
else
    echo "[stage-wlapps] WARNING: foot terminfo not found in ncurses-term"
fi
# foot's default config (colours/font). Not strictly required (foot has
# built-in defaults) but ships the canonical monospace font pick.
if [ -f "$APPROOT/etc/xdg/foot/foot.ini" ]; then
    install -D -m0644 "$APPROOT/etc/xdg/foot/foot.ini" "$ROOTFS/etc/xdg/foot/foot.ini"
    echo "[stage-wlapps] staged /etc/xdg/foot/foot.ini"
fi

echo "[stage-wlapps] DONE. rootfs now carries weston demos + foot."
echo "[stage-wlapps]   demos:  weston-simple-damage weston-flower weston-smoke weston-eventdemo weston-clickdot"
echo "[stage-wlapps]   foot:   /usr/bin/foot (+ footclient)"
echo "[stage-wlapps] Next: HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB=1792 bash scripts/build_installer_img.sh"
[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"
