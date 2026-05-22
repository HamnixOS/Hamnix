#!/usr/bin/env bash
# scripts/test_u41_cpython.sh -- U41 milestone: full CPython 3.11
# running through the Hamnix U-track Linux ABI.
#
# U39 proved MicroPython (~900 KB) boots through the Linux ABI and
# prints. U41 raises the bar to CPython -- the same binary Debian's
# `apt install python3` actually delivers, with the full stdlib +
# the much wider syscall surface (getrandom, prlimit64, fstatat,
# readlinkat, ...) that real Python apps walk.
#
# Boots Hamnix with /bin/u_cpython embedded in the initramfs and
# drives hamsh to exec it. u_cpython is a host-built fully-static
# OSABI=Linux x86_64 ELF -- CPython 3.11.10 linked `-static`, ~5.7 MB
# stripped. See tests/u-binary/src/cpython/HOWTO.md for the build.
#
# Why this milestone matters: with CPython running, "Hamnix is a
# useful server OS that hosts Python apps" stops being a theoretical
# claim and becomes a demo. M16.104 made brk per-task, which unblocks
# CPython's much more aggressive malloc behaviour (MicroPython had to
# clamp to a 64 KB heap; CPython grows freely now).
#
# The single success marker is the literal "hello from CPython on
# Hamnix" on serial -- that's the line printed by the embedded Python
# expression `print('hello from CPython on Hamnix')`. It can only
# appear if:
#
#   1. hamsh tokenised the quoted -c argument correctly (U17 envp
#      / argv plumbing).
#   2. SYS_SPAWN + ELF loader brought up the static binary
#      (U5 + U10 + U14 paths).
#   3. The interpreter reached its print path through the U4 + U7
#      write/writev syscalls without an unhandled -ENOSYS hit on
#      the boot path.
#   4. CPython's startup didn't trip on a missing syscall that has
#      no glibc fallback (e.g. getrandom -- if -ENOSYS, glibc falls
#      back to /dev/urandom, which we don't have, which would abort).
#
# Skip-on-missing: if tests/u-binary/u_cpython hasn't been built on
# the host (`make -C tests/u-binary/src/cpython install`), exit 0
# with a notice so CI in environments without the host build still
# passes -- same shape as U22/U24/U39/U40. The build takes 15-30 min.
#
# U41 status after the brk/mmap fix + frozen-modules build:
#   - The original blocker (Fatal Python error: pycore_interp_init:
#     failed to initialize importlib / MemoryError) is gone. CPython
#     now runs through pycore_interp_init, _frozen_importlib bootstrap,
#     site.py initialisation, and reaches init_fs_encoding.
#   - The init_fs_encoding "No module named 'encodings'" blocker is
#     also gone. We rebuilt CPython with a widened FROZEN list in
#     Tools/scripts/freeze_modules.py — `encodings.*`, `collections.*`,
#     `enum`, `keyword`, `re`, `functools`, etc. are now compiled into
#     the binary's data segment via `_freeze_module`. The previous
#     HAMNIX_EMBED_PYLIB approach (embed upstream Lib/ tree into the
#     initramfs at /usr/lib/python3.11/) was blocked by fs/cpio.ad's
#     NR_FILES=192 cap + by the assembly blob exceeding GitHub's
#     100 MiB push limit. Frozen-modules sidesteps both. See
#     tests/u-binary/src/cpython/HOWTO.md "Frozen-modules build".
#   - "REGRESSION:" markers below guard against the pycore_interp_init
#     / mmap-alignment regressions returning.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_cpython
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/cpython; only SKIP on a real failure.
# NOTE: this fixture fetches the upstream Python-3.11.x tarball and
# does a full ~15-30 min interpreter build — an offline host (or one
# without wget/curl) will fail here, which is the correct, informative
# skip reason.
ensure_ubin_or_skip test_u41_cpython u_cpython cpython

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u41_cpython] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u41_cpython] (2/4) Swap /init = $HAMSH_ELF + embed u_cpython"
# The CPython stdlib is now frozen INTO u_cpython itself (see
# tests/u-binary/src/cpython/HOWTO.md "Frozen-modules build"), so
# no /usr/lib/python3.11/ tree is embedded in the initramfs. Just
# embed the binary via HAMNIX_EMBED_UBIN.
HAMNIX_EMBED_UBIN=1 \
    INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u41_cpython] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u41_cpython] (4/4) Boot QEMU + run /bin/u_cpython via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# Success-marker strategy: hamsh echoes the typed command line on
# the prompt before exec'ing it, so a marker that appears in the
# raw `print(...)` argument WOULD also appear in the echo of the
# command -- a false-PASS. We therefore (a) build the marker as a
# Python f-string with a runtime concatenation `'U41OK-' + str(2+3)`
# so the literal marker `U41OK-5` ONLY exists in interpreter output,
# not in the typed command line; and (b) grep for the assembled
# marker, not the source expression.
(
    # CPython startup is heavier than MicroPython: imports `_frozen_importlib`,
    # `_frozen_importlib_external`, decodes a few hundred KB of bytecode,
    # initialises sys + builtins, then hits the print path. On a 2 vCPU
    # qemu host with no JIT this typically takes 5-15s from exec to first
    # write(1, ...). We give it 60s before sending the `exit` line, which
    # is well within the 150s qemu timeout.
    sleep 5
    # With the frozen-modules build, no PYTHONHOME / PYTHONPATH
    # plumbing is needed — encodings + collections + the site.py
    # support set are all in the binary's data segment, found by
    # CPython's `_frozen_importlib` loader before sys.path is even
    # consulted.
    #
    # u_cpython -c "print('U41OK-' + str(2+3), 'hello from CPython on Hamnix')"
    # hamsh's tokenizer supports double quotes (see user/hamsh.ad:240);
    # we use that to keep the print() expression as a single argv slot.
    printf "u_cpython -c \"print('U41OK-' + str(2+3), 'hello from CPython on Hamnix')\"\n"
    sleep 60
    printf 'exit\n'
    sleep 2
) | timeout 150s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_u41_cpython] --- captured output (tail 120) ---"
tail -120 "$LOG"
echo "[test_u41_cpython] --- end output ---"

fail=0

check_marker() {
    local label="$1"
    local needle="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_u41_cpython] OK: $label  ('$needle')"
    else
        echo "[test_u41_cpython] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Primary success criterion: CPython's print() reached serial.
# We grep for `U41OK-5` (the runtime-assembled marker from
# `'U41OK-' + str(2+3)`) which ONLY appears when print() actually
# executed -- the typed shell command contains only the source
# expression, never the assembled string. So matching `U41OK-5`
# is unambiguous proof that:
#   - CPython's importlib finished init (most likely failure point)
#   - bytecode compile of the -c expression succeeded
#   - the eval loop ran str() + str-concat + tuple-build + print()
#   - write(1, ...) reached the kernel and serial.
check_marker "CPython print() output"  "U41OK-5 hello from CPython on Hamnix"
# Secondary: the U1 ELF-detect path noticed the OSABI=Linux byte.
check_marker "U1/U2 ELF detect"        "Linux-ABI binary detected"

# Tertiary checks tracking the move past the U41 (054f58b) original
# blocker -- the silent `Fatal Python error: pycore_interp_init:
# failed to initialize importlib / MemoryError` that the 4 MiB brk
# reserve + 32 mmap slots produced. After bumping LINUX_BRK_RESERVE
# to 32 MiB and LINUX_MMAP_SLOTS to 256 (and fixing the mmap fd=-1
# 32-vs-64-bit check + the mmap PAGE_ALIGN landing for glibc-malloc's
# sysmalloc_mmap), pycore_interp_init completes cleanly and CPython
# proceeds to fs encoding init.
# These markers should NEVER appear once the original blocker is
# diagnosed-and-fixed; their absence is part of the regression
# guarantee for the brk/mmap bump.
if grep -F -q "pycore_interp_init: failed to initialize importlib" "$LOG"; then
    echo "[test_u41_cpython] REGRESSION: importlib MemoryError returned"
    fail=1
fi
if grep -F -q "MALLOC_ALIGN_MASK) == 0" "$LOG"; then
    echo "[test_u41_cpython] REGRESSION: glibc-malloc mmap alignment assertion"
    fail=1
fi
# With the frozen-modules build, the cpio file_table cap should
# no longer come into play for U41 — no /usr/lib/python3.11/
# tree is embedded. If "cpio: file table full" surfaces, it's
# unrelated to U41 (some other initramfs growth).
if grep -F -q "cpio: file table full" "$LOG"; then
    echo "[test_u41_cpython] DIAG: in-kernel cpio file_table overflowed"
    echo "    (unrelated to U41 — frozen-modules build doesn't"
    echo "    touch /usr/lib/python3.11/)"
fi
if grep -F -q "init_fs_encoding" "$LOG"; then
    echo "[test_u41_cpython] DIAG: init_fs_encoding marker present"
    grep -F "init_fs_encoding" "$LOG" | head -4 || true
fi
if grep -F -q "ModuleNotFoundError" "$LOG"; then
    echo "[test_u41_cpython] DIAG: ModuleNotFoundError"
    grep -F "ModuleNotFoundError" "$LOG" | head -4 || true
fi

# Diagnostics: surface the next-gap signal for triage. The -ENOSYS
# hits are the main artifact we want from this test: every new N
# should land as a TODO.md entry for the cd-validation follow-up
# agent to fix in linux_abi/u_syscalls.ad.
if grep -F -q "ENOSYS nr=" "$LOG"; then
    echo "[test_u41_cpython] DIAG: -ENOSYS gaps (unique syscall numbers):"
    grep -F "ENOSYS nr=" "$LOG" | sed -E 's/.*ENOSYS nr=([0-9]+).*/\1/' | sort -un | head -40 || true
fi
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u41_cpython] DIAG: kernel logged 'unknown syscall'"
    grep -F "unknown syscall" "$LOG" | sort -u | head -20 || true
fi
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u41_cpython] DIAG: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "page fault" "$LOG"; then
    echo "[test_u41_cpython] DIAG: page fault"
    grep -F "page fault" "$LOG" | head -5 || true
fi
if grep -F -q "linux_u:" "$LOG"; then
    echo "[test_u41_cpython] DIAG: linux_u trace lines (first 30)"
    grep -F "linux_u:" "$LOG" | head -30 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u41_cpython] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u41_cpython] PASS -- CPython 3.11 (full static) runs on Hamnix"
