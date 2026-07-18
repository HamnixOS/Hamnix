#!/usr/bin/env bash
# scripts/test_hamsh_pygame_device.sh — structural gate for the DEVICE half of
# the pygame-flavored hamSDL bindings: a hamsh pygame game must OPEN a real DE
# window and PRESENT frames by committing the built lib/hamscene display list to
# /dev/wsys/<wid>/scene (the same path every DE scene app uses), not merely
# rasterize to an in-RAM framebuffer.
#
# This is QEMU-free (fast, deterministic). It proves the wsys-commit path is
# WIRED and COMPILED into the on-device hamsh:
#   (1) the NATIVE x86_64-adder-user hamsh compiles with lib/hamsdl_dev.ad in
#       its module set (the DE transport is now part of hamsh);
#   (2) the pygame builtin SOURCE wires the DE transport into the right verbs:
#         pygame init  -> sdl_dev_init   (open the wsys window)
#         pygame flip  -> sdl_dev_present (commit the scene + poke `commit`)
#         pygame poll  -> sdl_dev_pump    (drain the window's /keys + /event);
#   (3) the DE window-open + scene-commit code lands in the device ELF (the
#       wsys ctl grammar strings: newwindow / geometry / /dev/wsys/ctl).
#
# The actual pixels-on-a-DE-window screendump is an on-device follow-up (the DE
# scene gates are QEMU-heavy and mouse-injection is flaky); the HOST PPM path is
# covered byte-for-byte by scripts/test_hamsh_pygame_host.sh and is unchanged.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
ELF="$OUT/hamsh_pygame_device.elf"
SRC="user/hamsh.ad"
mkdir -p "$OUT"
fail=0

# --- (1) native (device) build with lib/hamsdl_dev.ad linked ---------------
echo "[pygame-dev] compiling NATIVE hamsh for x86_64-adder-user ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        "$SRC" -o "$ELF" 2>"$OUT/pygame_device_compile.log"; then
    echo "[pygame-dev] FAIL: device hamsh did not compile/link"
    cat "$OUT/pygame_device_compile.log"; exit 1
fi
if grep -qE "lib/hamsdl_dev\.ad" "$OUT/pygame_device_compile.log"; then
    echo "[pygame-dev] OK: lib/hamsdl_dev.ad is in the device module set"
else
    echo "[pygame-dev] WRONG: lib/hamsdl_dev.ad not compiled into device hamsh"; fail=1
fi

# --- (2) SOURCE wiring: the DE transport reaches the right pygame verbs -----
# Extract just the builtin_pygame body so we assert the call is in the verb,
# not merely somewhere in the 14k-line file.
BODY="$OUT/pygame_body.txt"
awk '/^def builtin_pygame\(/{p=1} p{print} p&&/^def /&&!/^def builtin_pygame\(/&&NR>1{if(seen)exit;seen=1}' \
    "$SRC" > "$BODY" 2>/dev/null
# Fallback: simple range from builtin_pygame to the next top-level def.
if [ ! -s "$BODY" ]; then
    sed -n '/^def builtin_pygame(/,/^def [a-z_]/p' "$SRC" > "$BODY"
fi

wired() {  # <call> <verb-description>
    if grep -qF "$1" "$BODY"; then
        echo "[pygame-dev] OK: builtin_pygame calls $1  ($2)"
    else
        echo "[pygame-dev] WRONG: builtin_pygame missing $1  ($2)"; fail=1
    fi
}
wired "sdl_dev_init"    "pygame init -> open the DE window"
wired "sdl_dev_present" "pygame flip -> commit the scene to /dev/wsys/<wid>/scene"
wired "sdl_dev_pump"    "pygame poll -> drain the DE window's /keys + /event"

# sdl_dev_present must run BEFORE sdl_begin_frame() in flip (commit reads the
# scene buffer read-only; begin_frame resets it).
if awk '/if cstr_eq\(sub, "flip"\)/{f=1}
        f&&/sdl_dev_present/{present=NR}
        f&&/sdl_begin_frame/{if(present&&NR>present){print "OK";exit}}' "$BODY" \
        | grep -q OK; then
    echo "[pygame-dev] OK: flip commits (sdl_dev_present) BEFORE sdl_begin_frame resets the scene"
else
    echo "[pygame-dev] WRONG: flip ordering — present must precede begin_frame"; fail=1
fi

# --- (3) the DE window-open + commit code is in the device ELF --------------
elf_has() {  # <string> <what>
    # grep -c (not -q): -q closes the pipe early and, under pipefail, the
    # SIGPIPE on `strings` would poison the pipeline exit even on a match.
    if [ "$(strings "$ELF" | grep -cF "$1")" -gt 0 ]; then
        echo "[pygame-dev] OK: device ELF contains '$1'  ($2)"
    else
        echo "[pygame-dev] WRONG: device ELF missing '$1'  ($2)"; fail=1
    fi
}
elf_has "newwindow"     "wsys ctl: allocate a window"
elf_has "geometry "     "wsys ctl: size/position the window"
elf_has "/dev/wsys/ctl" "wsys control file path"

if [ "$fail" -ne 0 ]; then
    echo "[pygame-dev] RESULT: FAIL"
    exit 1
fi
echo "[pygame-dev] RESULT: PASS (device wsys-commit path wired + compiled; on-device screendump is a follow-up)"
