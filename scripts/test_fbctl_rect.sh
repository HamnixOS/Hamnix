#!/usr/bin/env bash
# scripts/test_fbctl_rect.sh -- /dev/fbctl dirty-rectangle RECT present:
# bounds hardening + full-width fast path.
#
# The userland desktop compositor presents only the changed rectangles of a
# frame by writing a fixed 52-byte little-endian RECT command to /dev/fbctl
# (magic 0x54434552). The kernel handler (drivers/video/fb_cdev.ad
# _fbctl_rect_present) decodes that attacker-controllable geometry, copies
# the named rectangle out of the caller's source frame via copy_from_user,
# and blits it to the write-combining framebuffer.
#
# TWO complementary proofs:
#
#  (A) KERNEL self-test. With /etc/fbrect-test planted (ENABLE_FBRECT_TEST=1)
#      init/main.ad's fbrect gate (boot:37.fbrect) calls fbctl_rect_selftest()
#      (drivers/video/fb_cdev.ad). It stands up a SYNTHETIC framebuffer and
#      drives the REAL devfbctl_write path with a valid full-frame RECT (must
#      be accepted -> present count increments), three OUT-OF-BOUNDS RECTs (a
#      destination origin past the screen, a source rect wider than the named
#      frame, and an overflow-crafted source offset -- all rejected, present
#      count flat, a sentinel guard band past the live framebuffer proving no
#      over-write), the conversion/coalescing blit core (pixel-identical), and
#      the full-width fast-path selection. Banner: "[fbrect] PASS".
#
#  (B) USERLAND fixture /bin/test_fbctl_rect (tests/test_fbctl_rect.ad), run
#      from hamsh, writes a well-formed RECT whose source pointer is a REAL
#      user buffer (exercising copy_from_user + the return-52 contract through
#      an honest syscall) and confirms the ASCII suspend/resume verbs still
#      route. Banner: "[fbrect-user] PASS".
#
# Pass markers: [fbrect] PASS   AND   [fbrect-user] PASS
# Fail markers: [fbrect] FAIL   OR    [fbrect-user] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT=900

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_fbctl_rect.elf

echo "[test_fbctl_rect] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_fbctl_rect] (2/5) Build tests/test_fbctl_rect.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_fbctl_rect.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_fbctl_rect] (3/5) Plant /init = hamsh + /bin/test_fbctl_rect + /etc/fbrect-test marker"
INIT_ELF="$HAMSH_ELF" ENABLE_FBRECT_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_fbctl_rect] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_fbctl_rect] (5/5) Boot QEMU + drive the userland fixture via hamsh"
# Gate the keystroke on a boot-ready marker rather than a fixed sleep: wait
# for hamsh's prompt to appear in the log, then send the command. The FIRST
# serial line a freshly-booted hamsh sees is sometimes dropped, so re-send
# until the fixture's own start banner shows.
set +e
(
    # Wait (bounded) for the shell to be ready.
    for _i in $(seq 1 60); do
        if grep -aqE 'hamsh|\$ |# ' "$LOG" 2>/dev/null; then break; fi
        sleep 0.5
    done
    # Drive the fixture; re-send a few times in case the first line drops.
    for _r in 1 2 3; do
        printf '/bin/test_fbctl_rect\n'
        for _j in $(seq 1 10); do
            if grep -aqF '[fbrect-user]' "$LOG" 2>/dev/null; then break; fi
            sleep 0.5
        done
        if grep -aqF '[fbrect-user]' "$LOG" 2>/dev/null; then break; fi
    done
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 90s qemu-system-x86_64 \
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

echo "[test_fbctl_rect] --- RECT self-test output ---"
grep -aE "\[fbrect\]|\[fbrect-user\]" "$LOG" || true
echo "[test_fbctl_rect] --- end ---"

fail=0

# A kernel panic / CPU trap is ALWAYS a hard failure.
if grep -aE -q "PANIC|panic:|TRAP:|BUG:" "$LOG"; then
    echo "[test_fbctl_rect] FAIL: kernel panic / trap" >&2
    grep -aE "PANIC|panic:|TRAP:|BUG:" "$LOG" | head -5 || true
    fail=1
fi

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_fbctl_rect] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# Explicit internal failures are fatal.
if grep -aqF "[fbrect] FAIL" "$LOG"; then
    echo "[test_fbctl_rect] FAIL: kernel self-test reported a failure" >&2
    grep -aF "[fbrect] FAIL" "$LOG" | head -10 || true
    fail=1
fi
if grep -aqF "[fbrect-user] FAIL" "$LOG"; then
    echo "[test_fbctl_rect] FAIL: userland fixture reported a failure" >&2
    grep -aF "[fbrect-user] FAIL" "$LOG" | head -10 || true
    fail=1
fi

# (A) kernel self-test PASS banner (allow an optional "[NNNNNN] " prefix).
if grep -aqE '(^|\] )\[fbrect\] PASS$' "$LOG"; then
    echo "[test_fbctl_rect] OK: kernel self-test PASS (bounds + blit + fast path)"
else
    echo "[test_fbctl_rect] FAIL: kernel self-test PASS banner missing" >&2
    fail=1
fi

# (B) userland fixture PASS banner.
if grep -aqF '[fbrect-user] PASS' "$LOG"; then
    echo "[test_fbctl_rect] OK: userland RECT write fixture PASS"
else
    echo "[test_fbctl_rect] FAIL: userland fixture PASS banner missing" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_fbctl_rect] FAIL"
    exit 1
fi

echo "[test_fbctl_rect] PASS -- RECT present rejects out-of-bounds/overflow" \
     "geometry without scribbling past the framebuffer, the blit core is" \
     "pixel-identical, the full-width contiguous fast path is selected, and" \
     "a real userland RECT write honours the return-52 wire contract"
