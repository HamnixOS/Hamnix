#!/usr/bin/env bash
# scripts/stage_mesa_gl.sh — host-side, one-time: stage Mesa SOFTWARE OpenGL
# (llvmpipe / swrast + libEGL + GLESv2 + libgbm + the LLVM JIT backend) plus a
# raw EGL Wayland test client (weston-simple-egl) into the debian-minbase
# fixture rootfs, so the full-mirror live image (HAMNIX_LIVE_MINIMAL=0) can
# prove that a GL-using Linux GUI client renders a frame on the native
# in-kernel Wayland compositor (linux_abi/wayland.ad).
#
# THE PATH (why no /dev/dri is needed):
#   The Hamnix compositor speaks wl_shm ONLY — it advertises NEITHER wl_drm
#   NOR zwp_linux_dmabuf. Mesa's EGL Wayland platform detects that and falls
#   back to its SOFTWARE swrast path (dri2_initialize_wayland_swrast): it
#   renders with llvmpipe into a plain wl_shm pool buffer and commits it like
#   any other shm client. That path opens NO DRM render node and needs NO
#   GBM device — it is pure CPU rasterization into shared memory. So this
#   staging is sufficient on its own; a /dev/dri/renderD128 shim (the GBM
#   platform) is only required for the EGL_PLATFORM_GBM / kms_swrast route,
#   which we deliberately do NOT use here.
#
#   Env the launcher must set (see scripts/test_wayland_gl_egl.sh):
#     LIBGL_ALWAYS_SOFTWARE=1  GALLIUM_DRIVER=llvmpipe
#     EGL_PLATFORM=wayland     __EGL_VENDOR_LIBRARY_FILENAMES=<50_mesa.json>
#
# Layers ON TOP OF scripts/stage_weston_term.sh (which MUST have run first —
# this reuses its libwayland/cairo/xkb closure, fonts, and glibc upgrade).
#
# Requirements (Debian/Ubuntu host w/ a trixie-ish mirror): apt-get download +
# dpkg-deb + readelf. No sudo, no install into the host. Idempotent.
#
# Env:
#   ROOTFS  target rootfs (default: tests/distros/debian-minbase/rootfs)
#   WORK    scratch dir for .deb download/extract (default: mktemp)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$HERE/tests/distros/debian-minbase/rootfs}"
WORK="${WORK:-$(mktemp -d --tmpdir hamnix-mesagl.XXXXXX)}"

if [ ! -d "$ROOTFS" ]; then
    echo "[stage-mesa] ERROR: $ROOTFS absent. Populate it first."
    exit 1
fi
if [ ! -e "$ROOTFS/usr/bin/weston-terminal" ]; then
    echo "[stage-mesa] ERROR: weston-terminal not staged in $ROOTFS."
    echo "[stage-mesa]   Run scripts/stage_weston_term.sh FIRST (this script"
    echo "[stage-mesa]   layers on its libwayland/glibc/font closure)."
    exit 1
fi

DEBS="$WORK/debs"; MROOT="$WORK/mroot"
mkdir -p "$DEBS" "$MROOT"

# --- 1. download the Mesa GL closure + LLVM + weston (simple-egl) -------
# Mesa 25 packaging: the gallium drivers live in ONE megalib
# (mesa-libgallium: libgallium-<ver>.so, ~42 MiB) that libEGL_mesa.so and the
# dri/*_dri.so loader shim (libdril_dri.so) dlopen; libLLVM is llvmpipe's JIT
# backend. libglvnd provides the libEGL.so.1 / libGLESv2.so.2 dispatch that
# clients link, resolving the Mesa vendor via /usr/share/glvnd/egl_vendor.d.
PKGS=(
  # Mesa vendor + gallium megadriver + GBM
  libegl-mesa0 libgbm1 libgl1-mesa-dri mesa-libgallium
  # libglvnd dispatch (libEGL.so.1 / libGLESv2.so.2 / libGLdispatch)
  libegl1 libgles2 libglvnd0
  # llvmpipe JIT backend + its runtime deps
  libllvm19 libstdc++6 libz3-4 libedit2 libbsd0
  zlib1g libzstd1 libsensors5 libelf1t64
  # libLLVM DT_NEEDED libxml2 (+ its lzma/icu deps); libEGL_mesa DT_NEEDED
  # libwayland-server (the wl_drm server-protocol side, linked even client-side)
  libxml2 liblzma5 libicu76 libwayland-server0
  # libdrm family (linked even for swrast; harmless without a GPU)
  libdrm2 libdrm-amdgpu1 libdrm-intel1 libpciaccess0
  # xcb / x11 shims libgallium + libEGL_mesa DT_NEEDED (X11-less, but present)
  libx11-xcb1 libxcb1 libxcb-randr0 libxcb-xfixes0 libxcb-shm0
  libxcb-dri3-0 libxcb-present0 libxcb-sync1 libxshmfence1 libexpat1
  # the EGL Wayland test client (raw wl_egl_window + GLES2 triangle)
  weston
)
echo "[stage-mesa] downloading ${#PKGS[@]} packages into $DEBS ..."
( cd "$DEBS" && apt-get download "${PKGS[@]}" >/dev/null 2>&1 ) || {
    echo "[stage-mesa] ERROR: apt-get download failed (need mirror access)."; exit 1; }

echo "[stage-mesa] extracting .debs into merged staging tree ..."
for d in "$DEBS"/*.deb; do dpkg-deb -x "$d" "$MROOT"; done

# --- 2. copy the ENTIRE dri/ driver dir (megadriver + symlinks) --------
# The dri directory is a set of *_dri.so symlinks -> libdril_dri.so (the
# loader shim). Mesa opens dri/swrast_dri.so + dri/kms_swrast_dri.so by name;
# preserve the symlink graph verbatim.
DRI_SRC="$MROOT/usr/lib/x86_64-linux-gnu/dri"
DRI_DST="$ROOTFS/usr/lib/x86_64-linux-gnu/dri"
if [ -d "$DRI_SRC" ]; then
    mkdir -p "$DRI_DST"
    cp -a "$DRI_SRC"/. "$DRI_DST"/
    echo "[stage-mesa] staged dri/ ($(ls "$DRI_DST" | wc -l) entries incl. swrast_dri.so)"
else
    echo "[stage-mesa] ERROR: no dri/ dir in extracted tree."; exit 1
fi

# --- 3. glvnd EGL vendor JSON (points libEGL.so.1 at libEGL_mesa.so.0) --
for vd in usr/share/glvnd/egl_vendor.d etc/glvnd/egl_vendor.d; do
    if [ -d "$MROOT/$vd" ]; then
        mkdir -p "$ROOTFS/$vd"
        cp -a "$MROOT/$vd"/. "$ROOTFS/$vd"/
        echo "[stage-mesa] staged $vd/$(ls "$ROOTFS/$vd" | tr '\n' ' ')"
    fi
done

# --- 4. walk the transitive DT_NEEDED closure of the whole GL stack ----
# Seed from: the EGL Wayland client, the glvnd dispatch libs, the Mesa
# vendor + megadriver + gbm. Resolve against the merged tree first, then the
# existing rootfs (libc/ld.so already upgraded there). Copy host-fresh libs.
python3 - "$MROOT" "$ROOTFS" <<'PY'
import os, sys, subprocess, shutil
MROOT, ROOTFS = sys.argv[1], sys.argv[2]
LIBDIRS = ["usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu",
           "usr/lib","lib","usr/lib64","lib64"]
# Seed binaries/libs (paths relative to a tree root). dri libs are copied
# wholesale in step 2, but we still seed libdril_dri.so so ITS deps resolve.
SEEDS = [
  "usr/bin/weston-simple-egl",
  "usr/lib/x86_64-linux-gnu/libEGL.so.1",
  "usr/lib/x86_64-linux-gnu/libGLESv2.so.2",
  "usr/lib/x86_64-linux-gnu/libEGL_mesa.so.0",
  "usr/lib/x86_64-linux-gnu/libgbm.so.1",
  "usr/lib/x86_64-linux-gnu/dri/libdril_dri.so",
]
# Also seed the gallium megadriver by its real (versioned) name.
gd = None
for f in os.listdir(os.path.join(MROOT,"usr/lib/x86_64-linux-gnu")):
    if f.startswith("libgallium-") and f.endswith(".so"):
        gd = "usr/lib/x86_64-linux-gnu/"+f
if gd: SEEDS.append(gd)

def needed(p):
    try: out=subprocess.check_output(["readelf","-d",p],stderr=subprocess.DEVNULL).decode()
    except Exception: return []
    return [l.split("[")[1].split("]")[0] for l in out.splitlines()
            if "(NEEDED)" in l and "[" in l]

def find(soname):
    for tree in (MROOT, ROOTFS):
        for d in LIBDIRS:
            c=os.path.join(tree,d,soname)
            if os.path.exists(c): return os.path.realpath(c), tree
    return None,None

def copy_into_rootfs(realpath, soname):
    for sub in ("usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu"):
        dst=os.path.join(ROOTFS,sub,soname)
        os.makedirs(os.path.dirname(dst),exist_ok=True)
        shutil.copy2(realpath,dst)

def stage_lib_with_links(rel):
    """Copy a merged-tree library FILE into the rootfs under BOTH its
    versioned real name and its SONAME symlink spelling. Needed for libs
    that are dlopen'd (not DT_NEEDED) — e.g. the libEGL_mesa vendor that
    the glvnd egl_vendor.d JSON names, and which the NEEDED walk misses."""
    src=os.path.join(MROOT,rel)
    if not os.path.exists(src): return 0
    real=os.path.realpath(src); realbase=os.path.basename(real)
    copy_into_rootfs(real, realbase)
    # recreate the soname (and any intermediate) symlink spelling(s)
    soname=os.path.basename(rel)
    if soname!=realbase:
        for sub in ("usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu"):
            link=os.path.join(ROOTFS,sub,soname)
            if not os.path.lexists(link):
                try: os.symlink(realbase, link)
                except OSError: pass
    return 1

seen=set(); work=[]; copied=0; missing=set()
# Explicitly copy the dlopen'd EGL vendor + GLES/GBM seed FILES (the NEEDED
# walk below only follows DT_NEEDED, which never names the glvnd vendor).
for rel in ("usr/lib/x86_64-linux-gnu/libEGL_mesa.so.0",
            "usr/lib/x86_64-linux-gnu/libGLESv2.so.2",
            "usr/lib/x86_64-linux-gnu/libgbm.so.1"):
    copied += stage_lib_with_links(rel)
for s in SEEDS:
    sp=os.path.join(MROOT,s)
    if os.path.exists(sp): work += needed(sp)
    else: print(f"[stage-mesa]   NOTE: seed absent: {s}")
# The megadriver's own name is not a DT_NEEDED of the seeds' binaries but
# libEGL_mesa NEEDS it explicitly — copy it verbatim + walk its closure.
if gd:
    real=os.path.realpath(os.path.join(MROOT,gd))
    copy_into_rootfs(real, os.path.basename(gd)); copied+=1
    work += needed(real)

while work:
    so=work.pop()
    if so in seen: continue
    seen.add(so)
    rp,tree=find(so)
    if rp is None: missing.add(so); continue
    if tree==MROOT:
        copy_into_rootfs(rp, so); copied+=1
    work += needed(rp)

# copy the GL client binaries (raw EGL + a couple more if present)
CLIENTS=["usr/bin/weston-simple-egl","usr/bin/weston-simple-dmabuf-egl"]
staged_clients=0
for b in CLIENTS:
    src=os.path.join(MROOT,b)
    if os.path.exists(src):
        dst=os.path.join(ROOTFS,b)
        os.makedirs(os.path.dirname(dst),exist_ok=True)
        shutil.copy2(src,dst); os.chmod(dst,0o755); staged_clients+=1

print(f"[stage-mesa] staged {copied} closure libs + {staged_clients} GL client binaries")
# libgbm.so.1 / libEGL_mesa.so.0 / libGLESv2.so.2 are versioned symlinks in
# the deb; ensure the SONAME spelling exists in rootfs (copy2 above followed
# realpath, landing the real file under the versioned name — re-point the
# soname symlink names too).
import glob
for tree_sub in ("usr/lib/x86_64-linux-gnu","lib/x86_64-linux-gnu"):
    md=os.path.join(MROOT,tree_sub)
    if not os.path.isdir(md): continue
    for name in os.listdir(md):
        full=os.path.join(md,name)
        if os.path.islink(full):
            tgt=os.readlink(full)
            # only re-create links whose real target we actually staged
            realbase=os.path.basename(os.path.realpath(full))
            dst_real=os.path.join(ROOTFS,tree_sub,realbase)
            if os.path.exists(dst_real):
                link=os.path.join(ROOTFS,tree_sub,name)
                if not os.path.exists(link):
                    try: os.symlink(os.path.basename(tgt), link)
                    except OSError: pass
if missing:
    # X11/xcb libs may be intentionally absent (headless ns); note, don't fail.
    print("[stage-mesa] NOTE unresolved sonames (ok if X11-only):", sorted(missing))
PY

echo "[stage-mesa] DONE. Mesa software GL staged into $ROOTFS."
echo "[stage-mesa]   swrast_dri.so + libgallium(+LLVM) + libEGL(glvnd/mesa) + weston-simple-egl."
echo "[stage-mesa]   Rebuild the live image: HAMNIX_LIVE_MINIMAL=0 bash scripts/build_installer_img.sh"
