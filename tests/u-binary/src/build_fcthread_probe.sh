#!/usr/bin/env bash
# Build tests/u-binary/src/fcthread_probe.c and stage it into the Debian
# fixture rootfs as /fcthread-probe, so it can be run inside the Linux
# namespace:
#
#     spawn linux { /fcthread-probe }               # FcInit on the main thread
#     spawn linux { /fcthread-probe --fc-on-thread } # FcInit on a worker thread
#     spawn linux { /fcthread-probe --io-only }     # raw dir/file I/O only
#
# The probe reports, with no Gecko in the picture:
#   * whether a pthread can do directory/file I/O in the Linux namespace,
#   * how many files the process can hold open simultaneously,
#   * FcInit() + FcConfigGetFonts(FcSetSystem)->nfont on the main thread
#     and on a worker thread (Pango runs FcInit on its own thread).
#
# It was written to bisect the Firefox wl_shm-no-commit hang and it caught a
# real kernel bug: before fs/ext4.ad's open-file table was raised from 8, the
# ninth simultaneous open() of an existing file returned ENOENT.
#
# The probe links only libc/libpthread/libdl; libfontconfig is dlopen()ed at
# run time out of the guest rootfs, so the HOST does not need fontconfig
# headers. The host's glibc must not be newer than the fixture rootfs's
# (both are Debian trixie / glibc 2.41 today).
#
# Rebuild the live image afterwards:
#   HAMNIX_LIVE_MINIMAL=0 HAMNIX_ROOTFS_SIZE_MB=1792 bash scripts/build_installer_img.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../../.." && pwd)"
ROOTFS="${ROOTFS:-$PROJ/tests/distros/debian-minbase/rootfs}"
OUT="${OUT:-$PROJ/build/fcthread-probe}"

mkdir -p "$(dirname "$OUT")"
gcc -O1 -g -o "$OUT" "$HERE/fcthread_probe.c" -lpthread -ldl
echo "[fcthread-probe] built $OUT"

if [ -d "$ROOTFS" ]; then
    install -m 0755 "$OUT" "$ROOTFS/fcthread-probe"
    echo "[fcthread-probe] staged $ROOTFS/fcthread-probe"
else
    echo "[fcthread-probe] NOTE: $ROOTFS absent; run tests/distros/debian-minbase/BUILD.sh first." >&2
fi
