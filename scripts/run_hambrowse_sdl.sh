#!/usr/bin/env bash
# scripts/run_hambrowse_sdl.sh — build + launch the INTERACTIVE hambrowse window
# on the Linux HOST. Opens a real SDL2 window driven by the SAME Adder browser
# engine that runs on Hamnix (user/hambrowse_sdl_host.ad + lib/htmlengine +
# lib/htmlpage + lib/browserwin) through a thin C bridge
# (scripts/hambrowse_sdl_bridge.c). QEMU-free.
#
# USAGE:
#   scripts/run_hambrowse_sdl.sh [PAGE.html]
# Default page: tests/fixtures/hambrowse_sdl_home.html
#
# WHAT WORKS (phase 1, LOCAL pages):
#   * click a link  -> navigates to the linked local file
#   * mouse wheel / j k / space / b / g / G / arrows -> scroll the page
#   * click the URL bar -> focus + caret; type a local path/file:// URL
#   * Enter (or click "Go") -> load the typed local page
#   * click "<" / ">" -> Back / Forward through visited local pages
#   * drag the window edge -> resize + reflow
# STUBBED (phase 2): live http/https fetching shows a "networking: phase 2"
#   status line instead of loading the URL.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PAGE="${1:-tests/fixtures/hambrowse_sdl_home.html}"
OUT="build/host"
mkdir -p "$OUT"
CHILD="$OUT/hambrowse_sdl"
BRIDGE="$OUT/hambrowse_sdl_bridge"
LIBSDL="/usr/lib/x86_64-linux-gnu/libSDL2-2.0.so.0"

echo "[run] compiling Adder browser engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hambrowse_sdl_host.ad -o "$CHILD" 2>"$OUT/hambrowse_sdl_compile.log"; then
    echo "[run] FAIL: engine did not compile"; cat "$OUT/hambrowse_sdl_compile.log"; exit 1
fi

echo "[run] compiling SDL2 window bridge ..."
if [ ! -e "$LIBSDL" ]; then
    echo "[run] FAIL: $LIBSDL not found (install libsdl2-2.0-0)"; exit 1
fi
if ! gcc -O2 scripts/hambrowse_sdl_bridge.c -o "$BRIDGE" "$LIBSDL" \
        2>"$OUT/hambrowse_sdl_bridge_compile.log"; then
    echo "[run] FAIL: bridge did not compile"; cat "$OUT/hambrowse_sdl_bridge_compile.log"; exit 1
fi

echo "[run] launching interactive window for: $PAGE"
exec "$BRIDGE" "$CHILD" "$PAGE"
