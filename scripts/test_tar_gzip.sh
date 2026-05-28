#!/usr/bin/env bash
# scripts/test_tar_gzip.sh — end-to-end test for the native `tar`,
# `gzip` and `gunzip` survival primitives, driven from a booted hamsh.
#
# WHAT THE TEST DOES (inside the booted system, working in /tmp):
#
#   tar:
#     1. create two files f1 / f2 with known contents.
#     2. `tar -cf /tmp/a.tar f1 f2`        (create)
#     3. `tar -tf /tmp/a.tar`              (list) — assert f1 and f2 listed
#     4. extract into a fresh dir and `cat` the extracted files —
#        assert the contents round-trip.
#
#   gzip / gunzip (our own stored-block output round-trips):
#     5. `gzip -k f1`                      (keep the original)
#     6. `gunzip -c f1.gz`                 (to stdout) — assert it
#        reproduces f1's contents.
#
#   gunzip on a REAL host-gzip file (the load-bearing assertion):
#     7. a .gz produced by the HOST's Python gzip (dynamic-Huffman
#        DEFLATE, staged into the cpio at /tests/realgz/known.txt.gz by
#        build_initramfs.py under ENABLE_TAR_GZIP_FIXTURE=1) is
#        decompressed with `gunzip -c` and asserted to match the staged
#        plaintext marker — proving our INFLATE handles real Huffman
#        streams, not just our own stored blocks.
#
# REQUIRED MARKERS for PASS:
#   * shell came up (TG_START echoed)
#   * tar list shows f1 and f2
#   * extracted f1/f2 contents match
#   * gunzip of our own gzip output round-trips
#   * gunzip of the host .gz reproduces the known plaintext
#   * NO "TRAP: vector"  (no kernel panic)

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_tar_gzip] (1/3) Build userland + hamsh-as-init initramfs"
bash scripts/build_user.sh >/dev/null
for tool in tar gzip gunzip; do
    if [ ! -x "build/user/${tool}.elf" ]; then
        echo "[test_tar_gzip] FAIL: build/user/${tool}.elf missing after build"
        exit 1
    fi
done

# Stage the real host-gzip fixture into the cpio (dynamic-Huffman .gz).
ENABLE_TAR_GZIP_FIXTURE=1 INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_tar_gzip] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_tar_gzip] (3/3) Boot QEMU + drive tar / gzip / gunzip"
LOG=$(mktemp /tmp/test-tar-gzip.XXXXXX.log)
trap '[ "${TG_KEEP_LOG:-0}" = 1 ] || rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 180 \
    -- "echo TG_START"                                          2 \
       "cd /tmp"                                                2 \
       "echo hello-from-f1 > /tmp/f1"                           2 \
       "echo second-file-2 > /tmp/f2"                           2 \
       "tar -cf /tmp/a.tar f1 f2"                               3 \
       "echo TG_TAR_CREATED"                                    2 \
       "tar -tf /tmp/a.tar"                                     3 \
       "echo TG_TAR_LISTED"                                     2 \
       "mkdir /tmp/ex"                                          2 \
       "cd /tmp/ex"                                             2 \
       "tar -xf /tmp/a.tar"                                     3 \
       "echo TG_TAR_EXTRACTED"                                  2 \
       "cat /tmp/ex/f1"                                         2 \
       "cat /tmp/ex/f2"                                         2 \
       "echo TG_TAR_CAT_DONE"                                   2 \
       "cd /tmp"                                                2 \
       "gzip -k /tmp/f1"                                        3 \
       "echo TG_GZIP_DONE"                                      2 \
       "gunzip -c /tmp/f1.gz"                                   3 \
       "echo TG_GUNZIP_OWN_DONE"                                2 \
       "gunzip -c /tests/realgz/known.txt.gz"                   3 \
       "echo TG_GUNZIP_REAL_DONE"                               2 \
       "exit"                                                   2
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_tar_gzip] --- captured (relevant lines) ---"
grep -E 'TG_|hello-from-f1|second-file-2|^f1$|^f2$|quick brown fox|tar:|gzip:|gunzip:' "$LOG" || true
echo "[test_tar_gzip] --- end ---"

fail=0

# 0. No kernel panic.
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_tar_gzip] FAIL: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
else
    echo "[test_tar_gzip] OK: no kernel TRAP / panic"
fi

# 1. Shell came up.
if ! grep -F -q "TG_START" "$LOG"; then
    echo "[test_tar_gzip] FAIL: shell never accepted the first command"
    tail -n 100 "$LOG"
    exit 1
fi

# 2. tar list shows both members.
list_block=$(sed -n '/TG_TAR_CREATED/,/TG_TAR_LISTED/p' "$LOG")
if echo "$list_block" | grep -E -q '(^|[^a-z])f1([^0-9a-z]|$)' \
   && echo "$list_block" | grep -E -q '(^|[^a-z])f2([^0-9a-z]|$)'; then
    echo "[test_tar_gzip] OK: tar -t listed f1 and f2"
else
    echo "[test_tar_gzip] FAIL: tar -t did not list both f1 and f2"
    fail=1
fi

# 3. Extracted contents round-trip.
cat_block=$(sed -n '/TG_TAR_EXTRACTED/,/TG_TAR_CAT_DONE/p' "$LOG")
if echo "$cat_block" | grep -F -q "hello-from-f1" \
   && echo "$cat_block" | grep -F -q "second-file-2"; then
    echo "[test_tar_gzip] OK: extracted f1/f2 contents round-trip"
else
    echo "[test_tar_gzip] FAIL: extracted contents did not match"
    fail=1
fi

# 4. gunzip of our own gzip output round-trips.
own_block=$(sed -n '/TG_GZIP_DONE/,/TG_GUNZIP_OWN_DONE/p' "$LOG")
if echo "$own_block" | grep -F -q "hello-from-f1"; then
    echo "[test_tar_gzip] OK: gzip|gunzip round-trips our own stored-block .gz"
else
    echo "[test_tar_gzip] FAIL: gunzip of our gzip output did not reproduce f1"
    fail=1
fi

# 5. gunzip of a REAL host-gzip (dynamic-Huffman) file.
real_block=$(sed -n '/TG_GUNZIP_OWN_DONE/,/TG_GUNZIP_REAL_DONE/p' "$LOG")
if echo "$real_block" | grep -F -q "quick brown fox"; then
    echo "[test_tar_gzip] OK: gunzip decoded a real host-gzip (Huffman) stream"
else
    echo "[test_tar_gzip] FAIL: gunzip could not decode the host .gz fixture"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_tar_gzip] FAIL (qemu rc=$rc)"
    echo "[test_tar_gzip] --- full log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi
echo "[test_tar_gzip] PASS (qemu rc=$rc)"
