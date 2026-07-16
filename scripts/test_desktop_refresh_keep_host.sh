#!/usr/bin/env bash
# scripts/test_desktop_refresh_keep_host.sh — FAST, QEMU-free host gate for the
# user-reported "clicking the default theme drops my desktop icons" regression.
#
# Applying a theme/wallpaper in Control Center bumps the kernel wallpaper gen;
# the desktop (user/hamdesktop.ad) wakes and, on the SAME wake, runs its
# periodic fmc_refresh_if_changed() -> _rebuild_after_refresh(). The old rebuild
# fell back to _load_defaults() whenever the re-scan yielded 0 icons, so a
# transiently unreadable/empty ~/Desktop scan collapsed the full ~10-icon set to
# the 3 built-in defaults, made VISIBLE by the wallpaper redraw at the click.
#
# The fix routes the rebuild-vs-keep decision through desk_refresh_should_keep()
# and, on a refresh scan of 0 with icons already present, KEEPS the current set.
#
# Two-part gate:
#   1. Source guard: confirm user/hamdesktop.ad has desk_refresh_should_keep AND
#      that _rebuild_after_refresh() no longer calls _load_defaults() (it must
#      go through the keep decision, restoring the prior count instead).
#   2. Behaviour: compile tests/test_desktop_refresh_keep_host.ad for the host
#      and assert the four decision cases (keep on refresh scan=0 with prev>0,
#      keep on refresh readable-empty, defaults on cold-start empty, rebuild on
#      a real non-empty listing).
#
# Built with the frozen Python seed compiler (no self-host bootstrap needed).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/test_desktop_refresh_keep"
SRC="user/hamdesktop.ad"
HARNESS="tests/test_desktop_refresh_keep_host.ad"
mkdir -p "$OUT"
fail=0

# --- Part 1: source guard -------------------------------------------------
echo "[deskrefresh] checking $SRC keeps icons on a refresh scan=0 ..."
if grep -Eq 'def desk_refresh_should_keep\(' "$SRC"; then
    echo "[deskrefresh] PASS desk_refresh_should_keep() exists"
else
    echo "[deskrefresh] FAIL $SRC is missing desk_refresh_should_keep()"
    fail=1
fi

# _rebuild_after_refresh must route through the keep decision and MUST NOT
# fall back to _load_defaults() on a transient empty scan.
rebuild_body="$(awk '/^def _rebuild_after_refresh\(/{f=1} f{print} f&&/_load_positions\(\)/{exit}' "$SRC")"
if printf '%s' "$rebuild_body" | grep -q 'desk_refresh_should_keep(' && \
   ! printf '%s' "$rebuild_body" | grep -q '_load_defaults()'; then
    echo "[deskrefresh] PASS _rebuild_after_refresh routes through the keep decision (no _load_defaults fallback)"
else
    echo "[deskrefresh] FAIL _rebuild_after_refresh still wipes icons (calls _load_defaults or skips the keep decision)"
    fail=1
fi

# --- Part 2: compile + run behavioural replica ----------------------------
echo "[deskrefresh] compiling host harness ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        "$HARNESS" -o "$BIN" 2>"$OUT/deskrefresh_compile.log"; then
    echo "[deskrefresh] FAIL: host harness did not compile"
    cat "$OUT/deskrefresh_compile.log"
    exit 1
fi
echo "[deskrefresh] PASS host harness compiled -> $BIN"

echo "[deskrefresh] running host harness ..."
if ! "$BIN" >"$OUT/deskrefresh_run.log" 2>&1; then
    echo "[deskrefresh] FAIL: harness reported a failing assertion"
    cat "$OUT/deskrefresh_run.log"
    fail=1
else
    cat "$OUT/deskrefresh_run.log"
fi

if [ "$fail" -ne 0 ]; then
    echo "[deskrefresh] FAIL"
    exit 1
fi
echo "[deskrefresh] PASS desktop refresh icon-keep gate"
exit 0
