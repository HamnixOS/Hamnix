#!/usr/bin/env bash
# scripts/test_l58_udf.sh — L58 udf.ko load test (deferred).
#
# Goal:
#   udf.ko (Universal Disk Format — Linux's DVD/Blu-ray filesystem
#   driver) was triaged at L58 along with vfat/msdos/exfat/isofs but
#   deferred: the stock Debian 6.12 udf.ko has 75 UND symbols missing
#   relative to L57 + the L58 vfat/msdos/exfat/isofs union, exceeding
#   the L58 "<= 50 UND beyond L57 covers" cap. udf's filesystem
#   surface (cdrom_get_last_written, write_cache_pages, __folio_lock,
#   inode_init_owner, ...) is wider than the FAT family and overlaps
#   with isofs only partially. Picked up in a future L milestone once
#   the inode/folio runtime is broader.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
SRC="${HOST_LIB}/fs/udf/udf.ko.xz"
[ -f "$SRC" ] || SRC="${HOST_LIB}/fs/udf/udf.ko"

if [ ! -f "$SRC" ]; then
    echo "L58: udf.ko not present; skipping"
    exit 0
fi

echo "[test_l58_udf] DEFERRED: udf.ko triage shows 75 UND symbols" \
     "missing beyond L57+L58 coverage (cap is 50). Picked up in a" \
     "future L milestone — passing as no-op."
exit 0
