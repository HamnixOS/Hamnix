#!/usr/bin/env bash
# scripts/_make_ext4_test_disk.sh — mints a small ext4 disk image
# carrying a single canonical /hello.txt with the test payload.
#
# Used by scripts/test_nvme_io.sh (and any future storage exercise
# tests that want a freshly-minted, unshared disk image rather than
# build/ext4.img — which is a 1 MiB shared fixture multiple tests
# read from). Each caller passes (out_path, payload) and gets back
# a 32 MiB ext4 image containing /hello.txt with the requested
# bytes. The image is created with `-O ^has_journal` to match
# build/ext4.img's lean layout, so fs/ext4.ad's reader doesn't
# need the journal-replay path.
#
# Tooling note: mkfs.ext4 + debugfs live in /sbin which is not
# always on PATH for non-root users; we look in the usual suspects
# the same way scripts/build_diskimg.py's _which() does.
#
# Usage:
#   _make_ext4_test_disk.sh <out_path> <payload_string>
#
# Example (test_nvme_io.sh):
#   bash scripts/_make_ext4_test_disk.sh build/nvme-test.img nvme-shim-works

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <out_path> <payload_string>" >&2
    exit 1
fi

OUT="$1"
PAYLOAD="$2"

_which() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    for prefix in /sbin /usr/sbin /usr/local/sbin; do
        if [ -x "$prefix/$name" ]; then
            echo "$prefix/$name"
            return 0
        fi
    done
    echo "$0: required tool '$name' not found" >&2
    return 1
}

MKFS="$(_which mkfs.ext4)"
DEBUGFS="$(_which debugfs)"

mkdir -p "$(dirname "$OUT")"

# 32 MiB raw image. Larger than build/ext4.img's 1 MiB because
# QEMU's emulated nvme device wants a minimum namespace size that
# accommodates default block sizes; 32 MiB is comfortable headroom
# without bloating the test loop.
truncate -s 32M "$OUT"

# Format: -F skips the "are you sure" prompt, -q quiets banner,
# -L names the volume, -O '^has_journal' drops the journal we don't
# need for an init-cold read+write test.
"$MKFS" -F -q -L "HAMNIX_NVME" -O "^has_journal" "$OUT" >/dev/null

# Plant /hello.txt with the requested payload via debugfs (no
# loopback mount, no root). debugfs takes commands on stdin; write
# expects a real file on disk for the source so stage the payload
# in a tmp file the script cleans up afterwards.
TMP_PAYLOAD="$(mktemp --suffix=.nvme-test.payload)"
printf '%s' "$PAYLOAD" > "$TMP_PAYLOAD"
trap 'rm -f "$TMP_PAYLOAD"' EXIT

"$DEBUGFS" -w -f /dev/stdin "$OUT" >/dev/null <<EOF
write $TMP_PAYLOAD hello.txt
EOF

echo "$0: wrote $OUT ($(wc -c < "$OUT") bytes; /hello.txt = '$PAYLOAD')"
