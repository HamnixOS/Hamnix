#!/usr/bin/env bash
# scripts/test_fbpix.sh -- /dev/fbpix framebuffer pixel READ-BACK leaf
# (the hamshot screenshot source) + the hamshot CLI end-to-end.
#
# /dev/fb's read side stays the one-line geometry string; /dev/fbpix is the
# additive READ-ONLY pixel leaf: read(off, count) returns raw framebuffer
# bytes at byte offset `off`, size = PITCH * HEIGHT, EOF past the end
# (drivers/video/fb_cdev.ad devfbpix_read, routed via namec's DEV_FBPIX).
#
# THREE complementary proofs:
#
#  (A) KERNEL self-test. With /etc/fbpix-test planted (ENABLE_FBPIX_TEST=1)
#      init/main.ad's fbpix gate (boot:37.fbpix) calls fbpix_selftest()
#      (drivers/video/fb_cdev.ad). It stands up a SYNTHETIC 32x16x32bpp
#      framebuffer, paints a known byte pattern, and drives devfbpix_read
#      directly: size==pitch*height, byte-exact head read, short tail +
#      EOF semantics, a chunked full-frame walk accumulating exactly
#      `size` bytes, non-mutation, and read-only write rejection.
#      Banner: "[fbpix] PASS".
#
#  (B) USERLAND fixture /bin/test_fbpix (tests/test_fbpix.ad), run from
#      hamsh: reads + parses the real /dev/fb geometry line, then STREAMS
#      /dev/fbpix through honest open/read syscalls (fd_pos-advancing
#      chunked reads) to EOF and asserts the byte count == PITCH * HEIGHT
#      and that EOF is sticky. The kernel self-test deliberately leaves
#      the synthetic FB live so this leg sees real geometry under
#      -nographic. Banner: "[fbpix-user] PASS".
#
#  (C) THE PRODUCT: /bin/hamshot (user/hamshot.ad) run from hamsh writes a
#      PNG (lib/pngwrite.ad — one stored-DEFLATE-block IDAT per row) of the
#      live (synthetic) framebuffer to /tmp/shot.png and prints
#      "hamshot: wrote 32x16 -> /tmp/shot.png".
#
#  (D) DECODE-BACK: /bin/test_shotpng (tests/test_shotpng.ad) reads that
#      PNG, runs it through the REAL lib/png.ad decoder, and asserts a valid
#      structure, 32x16 dimensions, and NON-UNIFORM pixels (real captured
#      content, not a blank/garbage frame). Banner "[shotpng] PASS".
#
# Pass markers: [fbpix] PASS  AND  [fbpix-user] PASS  AND  hamshot: wrote
#               AND  [shotpng] PASS

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_fbpix.elf
SHOTPNG_ELF=build/user/test_shotpng.elf

echo "[test_fbpix] (1/5) Build userland (hamsh + coreutils + hamshot)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_fbpix] (2/5) Build tests/test_fbpix.ad + tests/test_shotpng.ad"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_fbpix.ad \
    -o "$TEST_ELF" >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_shotpng.ad \
    -o "$SHOTPNG_ELF" >/dev/null

echo "[test_fbpix] (3/5) Plant /init = hamsh + /bin/test_fbpix + /bin/hamshot + /bin/test_shotpng + /etc/fbpix-test marker"
INIT_ELF="$HAMSH_ELF" ENABLE_FBPIX_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_fbpix] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_fbpix] (5/5) Boot QEMU + drive the userland fixture + hamshot via hamsh"
# Gate keystrokes on a boot-ready marker rather than fixed sleeps; the FIRST
# serial line a freshly-booted hamsh sees is sometimes dropped, so re-send
# each command until its own marker appears.
set +e
(
    # Wait (bounded) for the shell to be ready.
    for _i in $(seq 1 60); do
        if grep -aqE 'hamsh|\$ |# ' "$LOG" 2>/dev/null; then break; fi
        sleep 0.5
    done
    # (B) the streaming fixture; re-send in case the first line drops.
    for _r in 1 2 3; do
        printf '/bin/test_fbpix\n'
        for _j in $(seq 1 10); do
            if grep -aqF '[fbpix-user]' "$LOG" 2>/dev/null; then break; fi
            sleep 0.5
        done
        if grep -aqF '[fbpix-user]' "$LOG" 2>/dev/null; then break; fi
    done
    # (C) the real hamshot CLI against the synthetic FB -> PNG at a known path.
    for _r in 1 2 3; do
        printf '/bin/hamshot /tmp/shot.png\n'
        for _j in $(seq 1 10); do
            if grep -aqF 'hamshot:' "$LOG" 2>/dev/null; then break; fi
            sleep 0.5
        done
        if grep -aqF 'hamshot:' "$LOG" 2>/dev/null; then break; fi
    done
    # (D) decode the captured PNG back + assert dims + non-uniform content.
    for _r in 1 2 3; do
        printf '/bin/test_shotpng /tmp/shot.png 32 16\n'
        for _j in $(seq 1 10); do
            if grep -aqF '[shotpng]' "$LOG" 2>/dev/null; then break; fi
            sleep 0.5
        done
        if grep -aqF '[shotpng]' "$LOG" 2>/dev/null; then break; fi
    done
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_fbpix] --- fbpix self-test output ---"
grep -aE "\[fbpix\]|\[fbpix-user\]|hamshot:|\[shotpng\]" "$LOG" || true
echo "[test_fbpix] --- end ---"

fail=0

# A kernel panic / CPU trap is ALWAYS a hard failure.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_fbpix] FAIL: kernel panic / trap" >&2
    grep -aE "PANIC|panic:|TRAP:|BUG:" "$LOG" | head -5 || true
    fail=1
fi

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_fbpix] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Explicit internal failures are fatal.
if grep -aqF "[fbpix] FAIL" "$LOG"; then
    echo "[test_fbpix] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[fbpix] FAIL" "$LOG" | head -10 || true
    fail=1
fi
if grep -aqF "[fbpix-user] FAIL" "$LOG"; then
    echo "[test_fbpix] FAIL: userland fixture reported a failure" >&2
    grep -aF "[fbpix-user] FAIL" "$LOG" | head -10 || true
    fail=1
fi

# (A) kernel self-test PASS banner (allow an optional "[NNNNNN] " prefix).
if grep -aqE '(^|\] )\[fbpix\] PASS$' "$LOG"; then
    echo "[test_fbpix] OK: kernel self-test PASS (size/bytes/EOF/read-only)"
else
    echo "[test_fbpix] FAIL: kernel self-test PASS banner missing" >&2
    fail=1
fi

# (B) userland streaming fixture PASS banner.
if grep -aqF '[fbpix-user] PASS' "$LOG"; then
    echo "[test_fbpix] OK: userland /dev/fbpix streaming fixture PASS"
else
    echo "[test_fbpix] FAIL: userland fixture PASS banner missing" >&2
    fail=1
fi

# (C) hamshot wrote a PNG from the live framebuffer.
if grep -aqF 'hamshot: wrote 32x16 -> /tmp/shot.png' "$LOG"; then
    echo "[test_fbpix] OK: hamshot captured the synthetic framebuffer to PNG"
else
    echo "[test_fbpix] FAIL: hamshot success line missing" >&2
    fail=1
fi

# (D) the captured PNG decodes back to a valid 32x16 non-uniform image.
if grep -aqF '[shotpng] FAIL' "$LOG"; then
    echo "[test_fbpix] FAIL: decode-back verifier reported a failure" >&2
    grep -aF '[shotpng] FAIL' "$LOG" | head -5 || true
    fail=1
fi
if grep -aqF '[shotpng] PASS' "$LOG"; then
    echo "[test_fbpix] OK: captured PNG decoded back to a valid 32x16 non-uniform image"
else
    echo "[test_fbpix] FAIL: decode-back PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_fbpix] FAIL"
    exit 1
fi

echo "[test_fbpix] PASS -- /dev/fbpix serves the framebuffer's raw bytes" \
     "(size = pitch*height, byte-exact, EOF-terminated, read-only), hamshot" \
     "encodes a live capture to PNG (lib/pngwrite.ad), and the captured PNG" \
     "decodes back to a valid non-uniform 32x16 image end-to-end"
