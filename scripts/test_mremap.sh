#!/usr/bin/env bash
# scripts/test_mremap.sh — mremap(2) grow/move/shrink/no-move regression.
#
# Boots Hamnix with /bin/u_mremap embedded in the initramfs and drives
# hamsh to exec it. u_mremap is a host-built, static, OSABI=Linux
# x86_64 ELF whose _start exercises the real mremap() path
# (linux_abi/u_syscalls.ad::_u_unimpl_mremap -> mm/vma.ad::vma_mremap):
#
#   (a) mmap 6 MiB anon (windowed), sentinel at head + old tail, then
#       mremap -> 10 MiB with MREMAP_MAYMOVE; verify sentinels survived
#       the move and the new tail is usable     -> "MREMAP: grow ok"
#   (b) mremap 10 MiB -> 2 MiB (shrink in place); verify base unchanged
#       and head sentinel intact                -> "MREMAP: shrink ok"
#   (c) grow a single identity-mapped page WITHOUT MAYMOVE; verify it
#       returns -ENOMEM (never silently moves)  -> "MREMAP: nomove ok"
#
# Modeled on scripts/test_u7_mmap.sh's build+boot+grep harness.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_mremap
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/mremap; only SKIP on a real failure.
ensure_ubin_or_skip test_mremap u_mremap mremap

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_mremap] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_mremap] (2/4) Swap /init = $HAMSH_ELF + embed u_mremap"
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_mremap] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_mremap] (4/4) Boot QEMU + run /bin/u_mremap via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Prompt-aware drive: wait for hamsh's ready banner before sending input.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 40 \
    -- "u_mremap" 5 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_mremap] --- captured output ---"
cat "$LOG"
echo "[test_mremap] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_mremap] OK: $label  ('$needle')"
    else
        echo "[test_mremap] MISS: $label  ('$needle')"
        fail=1
    fi
}

check_marker "grow+move (MAYMOVE)"      "MREMAP: grow ok"
check_marker "shrink in place"          "MREMAP: shrink ok"
check_marker "grow w/o MAYMOVE=-ENOMEM" "MREMAP: nomove ok"

# Negative markers — only printed if u_mremap took an error path.
for m in "MREMAP: grow FAIL" "MREMAP: shrink FAIL" "MREMAP: nomove FAIL"; do
    if grep -F -q "$m" "$LOG"; then
        echo "[test_mremap] DIAG: u_mremap reported '$m'"
        fail=1
    fi
done

# A #PF (vector 0x0e) from user mode while touching a remapped page is a
# kernel-side gap — surface it explicitly.
if grep -F -q "TRAP: vector 0x0e" "$LOG"; then
    echo "[test_mremap] DIAG: kernel reported #PF — likely user-mode" \
         "touch of a mis-mapped mremap page"
fi

if [ "$fail" -ne 0 ]; then
    echo "[mremap] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[mremap] PASS — grow+move, shrink, and no-move -ENOMEM all working"
