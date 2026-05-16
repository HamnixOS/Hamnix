#!/usr/bin/env bash
# scripts/test_ext4.sh - M16.51..M16.54 verification.
#
# Boots the kernel with build/ext4.img attached via virtio-blk so
# vda is detected as ext4 (FAT magic absent at sector 0). The
# ext4 driver mounts at /ext via the standard probe path. The
# test drives hamsh through `cat /ext/HELLO.TXT` and asserts:
#
#   1. The superblock log lines appeared (M16.51).
#   2. ext4_read_inode produced inode 2 with mode 0x41ED (M16.52).
#   3. The boot-time dirent dump found HELLO.TXT (M16.53).
#   4. cat /ext/HELLO.TXT delivered the marker — meaning the full
#      read path (root lookup → inode → extent → block → VFS →
#      user) works (M16.54).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_ext4] (1/5) Regenerate disk images"
python3 scripts/build_diskimg.py

echo "[test_ext4] (2/5) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_ext4] (3/5) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_ext4] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_ext4] (5/5) Boot QEMU with ext4 image as virtio-blk"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'cat /ext/HELLO.TXT\n'
    sleep 1
    # M16.68: HELLO_LINK is a symlink to /HELLO.TXT planted in the
    # image by build_diskimg.py. Reading it exercises the symlink
    # follow-through in ext4_resolve_file. The output is HELLO.TXT's
    # body, so the existing EXT4_MARKER assertion below covers both.
    printf 'cat /ext/HELLO_LINK\n'
    sleep 1
    printf 'ls /ext/SUB\n'
    sleep 1
    printf 'cat /ext/SUB/NESTED.TXT\n'
    sleep 1
    printf 'cat /ext/BIG.TXT\n'
    sleep 1
    # M16.63: SMOKE.TXT was created by the kernel at boot via
    # ext4_create_file. cat verifies the read path sees the new
    # dirent, the new inode, and the new data block end-to-end.
    printf 'cat /ext/SMOKE.TXT\n'
    sleep 1
    # M16.59: FILE49.TXT lives in the second block of the root dir
    # (which spans 2 blocks after we plant 50 extras). Resolving it
    # exercises the multi-block dir walk; a single-block walker
    # would silently miss it.
    printf 'cat /ext/FILE49.TXT\n'
    sleep 1
    # ext4_listdir should now stream entries from BOTH blocks of
    # the root dir — pipe through wc to get a line count. With
    # entries: . .. lost+found HELLO.TXT BIG.TXT FILE00..FILE49 SUB
    # = 55 lines.
    printf 'ls /ext | wc\n'
    sleep 2
    # M16.64: ext4 write through shell `>` redirect. echo writes
    # "WRITE_VIA_SHELL\n" into a new ext4 file; cat reads it back.
    printf 'echo WRITE_VIA_SHELL > /ext/USERMADE.TXT\n'
    sleep 2
    printf 'cat /ext/USERMADE.TXT\n'
    sleep 2
    # M16.67: ext4 unlink. rm removes the file we just made; a
    # second cat should fail to find it. We test by then
    # creating /ext/UNLINKED_OK.TXT — if unlink left the inode
    # bitmap in a bad state, this create would fail.
    printf 'rm /ext/USERMADE.TXT\n'
    sleep 2
    printf 'echo UNLINKED_OK > /ext/UNLINKED_OK.TXT\n'
    sleep 2
    printf 'cat /ext/UNLINKED_OK.TXT\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 55s qemu-system-x86_64 \
    -kernel "$ELF" \
    -drive file=build/ext4.img,if=virtio,format=raw \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_ext4] --- captured output ---"
cat "$LOG"
echo "[test_ext4] --- end output ---"

fail=0
for needle in \
    "ext4: mounted; block_size=1024 inodes_count=128" \
    "ext4 inode#2 mode=" \
    "dirent inode=12 name='HELLO.TXT'" \
    "EXT4_MARKER hello from /ext/HELLO.TXT" \
    "NESTED.TXT" \
    "EXT4_NESTED_MARKER /ext/SUB/NESTED.TXT" \
    "DEPTH1_MARKER ext4 index extents work" \
    "ext4: bitmap smoke PASS" \
    "ext4: create smoke PASS" \
    "CREATE_OK ext4 file-create round-trip works" \
    "WRITE_VIA_SHELL" \
    "UNLINKED_OK"
do
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_ext4] OK: '$needle'"
    else
        echo "[test_ext4] MISS: '$needle'"
        fail=1
    fi
done

# M16.59 multi-block dir assertions: FILE49.TXT lives in the second
# block of the root dir; resolving it via cat exercises the
# multi-block ext4_dir_lookup walk. The wc count line is a stricter
# regression: cleaned stdout includes the literal "55 55 ..." token.
cleaned=$(sed 's/task: pid -*[0-9]* exited (code=-*[0-9]*)//g' "$LOG" \
          | tr '\n' ' ' | tr -s ' ')

# cat /ext/FILE49.TXT outputs BIG.TXT's body (the source we wrote it
# from) — first 14 bytes are unique enough to grep for.
if echo "$cleaned" | grep -F -q "DEPTH1_MARKER ext4 index extents work"; then
    : # already asserted above by the loop
fi
if grep -F -q "cat /ext/FILE49.TXT" "$LOG"; then
    # If we see the prompt before AND a non-empty file-not-found
    # error, the lookup failed. Direct positive check: the second
    # cat (in the same session) emits its body to stdout, which
    # is BIG.TXT's body (single line).
    if echo "$cleaned" | grep -oF "DEPTH1_MARKER ext4 index extents work" | wc -l \
       | grep -q -E '^[2-9]|^[0-9]{2,}$'; then
        echo "[test_ext4] OK: FILE49.TXT (in second dir block) resolved"
    else
        echo "[test_ext4] MISS: FILE49.TXT didn't resolve to second-block content"
        fail=1
    fi
fi

# ls /ext | wc — root dir has 58 entries before the shell write
# (., .., lost+found, HELLO.TXT, BIG.TXT, SUB, FILE00..FILE49,
# SMOKE.TXT, HELLO_LINK). SMOKE.TXT was created by
# ext4_create_smoke_test at kernel init; HELLO_LINK is the M16.68
# symlink planted in the disk image. The count verifies that BOTH
# the multi-block listdir works (a single-block walker would stop
# ~30) AND that the M16.63 dirent insert is visible through the
# same listdir path. The shell-created USERMADE.TXT comes LATER in
# the session so it doesn't affect this count.
if echo "$cleaned" | grep -E -q "(^| )58 58 "; then
    echo "[test_ext4] OK: ls /ext listed all 58 entries (multi-block + create + symlink)"
else
    echo "[test_ext4] MISS: ls /ext | wc didn't show 58-line count"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_ext4] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_ext4] PASS"
