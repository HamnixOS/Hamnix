#!/usr/bin/env bash
# scripts/run_hambrowse_sdl_net.sh — build + launch the INTERACTIVE hambrowse
# window on the Linux HOST *with LIVE http/https browsing*.
#
# Same interactive window as scripts/run_hambrowse_sdl.sh (the SAME Adder engine
# + SDL2 C bridge), but the child engine is linked against the Plan-9 /net SHIM
# (scripts/net9_host_shim.c) + OpenSSL, so a typed http(s):// URL is actually
# FETCHED over the UNCHANGED user/http9.ad -> user/net9.ad stack (open
# /net/tcp/clone, write "connect ip!port" / "tls host", read/write the data
# file; sys_resolve for DNS) and RENDERED — no more "networking: phase 2" stub.
# The real sockets + TLS live ONLY in the host shim; the [[no-sockets]]
# invariant holds in the native Adder code.
#
# WHY A DIFFERENT LINK than run_hambrowse_sdl.sh: the freestanding
# user/linux-runtime.S stubs sys_resolve and has no TLS. A real TLS handshake
# needs a crypto library (OpenSSL) which needs libc, so we compile the engine to
# an object (--emit-asm) and gcc-link it against the shim instead of the
# -nostdlib runtime. The engine source (user/hambrowse_sdl_host.ad) is identical
# either way.
#
# USAGE:
#   scripts/run_hambrowse_sdl_net.sh [PAGE-or-URL]
# Default page: tests/fixtures/hambrowse_sdl_home.html
# Then type e.g.  https://example.com/  into the address bar + Enter.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PAGE="${1:-tests/fixtures/hambrowse_sdl_home.html}"
OUT="build/host"
mkdir -p "$OUT"
CHILD="$OUT/hambrowse_sdl_net"
BRIDGE="$OUT/hambrowse_sdl_bridge"
ASM="$OUT/hambrowse_sdl_net.s"
SHIM_O="$OUT/net9_host_shim.o"
LIBSDL="/usr/lib/x86_64-linux-gnu/libSDL2-2.0.so.0"

echo "[run-net] compiling Adder browser engine (x86_64-linux, emit-asm) ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux --emit-asm \
        user/hambrowse_sdl_host.ad -o "$OUT/hambrowse_sdl_net_freestanding.elf" \
        >"$OUT/hambrowse_sdl_net_compile.log" 2>&1; then
    echo "[run-net] FAIL: engine did not compile"; cat "$OUT/hambrowse_sdl_net_compile.log"; exit 1
fi
mv -f user/hambrowse_sdl_host.s "$ASM"

echo "[run-net] compiling + linking the /net shim (sockets + OpenSSL TLS) ..."
if ! gcc -O2 -c scripts/net9_host_shim.c -o "$SHIM_O" 2>"$OUT/net9_host_shim_compile.log"; then
    echo "[run-net] FAIL: shim did not compile"; cat "$OUT/net9_host_shim_compile.log"; exit 1
fi
if ! gcc -no-pie -O2 "$ASM" "$SHIM_O" -lssl -lcrypto -o "$CHILD" \
        2>"$OUT/hambrowse_sdl_net_link.log"; then
    echo "[run-net] FAIL: engine link failed"; cat "$OUT/hambrowse_sdl_net_link.log"; exit 1
fi

echo "[run-net] compiling SDL2 window bridge ..."
if [ ! -e "$LIBSDL" ]; then
    echo "[run-net] FAIL: $LIBSDL not found (install libsdl2-2.0-0)"; exit 1
fi
if ! gcc -O2 scripts/hambrowse_sdl_bridge.c -o "$BRIDGE" "$LIBSDL" \
        2>"$OUT/hambrowse_sdl_bridge_compile.log"; then
    echo "[run-net] FAIL: bridge did not compile"; cat "$OUT/hambrowse_sdl_bridge_compile.log"; exit 1
fi

echo "[run-net] launching LIVE interactive window (type an http(s):// URL + Enter): $PAGE"
exec "$BRIDGE" "$CHILD" "$PAGE"
