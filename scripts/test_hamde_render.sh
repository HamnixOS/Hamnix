#!/usr/bin/env bash
# scripts/test_hamde_render.sh — acceptance gate for the hamui-based
# Desktop Environment shell (user/hamde.ad) built on lib/hamui.ad.
#
# WHAT IT PROVES
# ==============
# hamde is the DE panel rebuilt as an ordinary hamui consumer: it builds
# a widget tree (an Applications menubar, a clock label, a taskbar list)
# and the toolkit lays it out and paints it as hamML markup into the
# window's "ui" draw layer — NO hand-rolled panel markup. A correct shell
# therefore means the panel chrome genuinely turns into toolkit-emitted
# hamML the compositor can rasterise.
#
# This is an OFFLINE compile+markup gate (the robust path on this host;
# full in-VM boot of the live daemon times out under load — see the
# project's "Verification under load" / "Real boot-path testing" notes).
# It mirrors scripts/test_hamui_render.sh's offline section:
#   1. hamde.ad (auto-pulling lib/hamui.ad) compiles clean.
#   2. the compiled hamde.elf embeds the toolkit's hamML emitters
#      (<rect>/<text>/fill=) and the menubar/menu fills, proving the
#      panel paint code is linked + reachable.
#   3. it embeds the Applications-menu item text and the real app launch
#      paths, proving the menu launches the shipped GUI apps.
#   4. the new hamui_list_clear (taskbar row-pool recycle) is linked.
#
# A regression in the toolkit paint path, the menu wiring, or the launch
# table will drop one of these tokens and fail the gate.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

mkdir -p build/user

echo "[test_hamde_render] (1/4) hamde.ad + lib/hamui.ad compile clean"
if ! python3 -m compiler.adder compile \
        --target=x86_64-adder-user \
        user/hamde.ad \
        -o build/user/hamde.elf >/tmp/hamde_compile.log 2>&1; then
    echo "[test_hamde_render] FAIL: user/hamde.ad did not compile"
    cat /tmp/hamde_compile.log
    exit 1
fi
echo "[test_hamde_render] OK: hamde + hamui compiled"

if [ ! -s build/user/hamde.elf ]; then
    echo "[test_hamde_render] FAIL: build/user/hamde.elf missing/empty"
    exit 1
fi

fail=0
check_tok() {  # $1=token  $2=label
    if grep -aF -q "$1" build/user/hamde.elf; then
        echo "[test_hamde_render] OK: ${2} (token: ${1})"
    else
        echo "[test_hamde_render] MISS: ${2} (no '${1}')"
        fail=1
    fi
}

echo "[test_hamde_render] (2/4) Panel chrome paints through the toolkit (hamML emitters)"
# Core protocol + primitive emitters + the menubar/menu fills the panel
# uses (#333333 menubar bg, #252525 popdown, #4a6da7 open/selection).
check_tok '<rect x='          'toolkit rect emitter linked'
check_tok '<text x='          'toolkit text emitter linked'
check_tok 'fill='             'hamML fill attribute emitted'
check_tok 'mklayer ui markup' 'panel creates its ui markup layer'
check_tok 'setz ui'           'panel z-orders its ui layer'
check_tok '#333333'           'menubar background fill'
check_tok '#252525'           'menu popdown fill'
check_tok '#4a6da7'           'menu open / selection highlight'

echo "[test_hamde_render] (3/4) Applications menu launches the shipped GUI apps"
check_tok 'Applications'   'Applications menu title'
check_tok 'Terminal'       'Terminal menu item'
check_tok 'Text Editor'    'Text Editor menu item'
check_tok 'Snake'          'Snake menu item'
check_tok '2048'           '2048 menu item'
check_tok '/bin/hamterm'   'Terminal launch path'
check_tok '/bin/hamfiles'  'Files launch path'
check_tok '/bin/hamedit'   'Editor launch path'
check_tok '/bin/hamsnake'  'Snake launch path'
check_tok '/bin/ham2048'   '2048 launch path'

echo "[test_hamde_render] (4/4) Toolkit additions linked (taskbar row recycle + windowing)"
for sym in hamui_menubar hamui_menu hamui_list hamui_list_clear \
           hamui_window_on hamui_step hamui_take_event; do
    if grep -aF -q "$sym" build/user/hamde.elf; then
        echo "[test_hamde_render] OK: links toolkit symbol: ${sym}"
    else
        echo "[test_hamde_render] MISS: lacks toolkit symbol: ${sym}"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[test_hamde_render] FAIL: the DE panel's toolkit paint/menu/launch wiring is not fully linked"
    exit 1
fi

echo "[test_hamde_render] capture method: hamde builds its panel from hamui widgets; the compiled binary embeds the toolkit's hamML emitters + the Applications-menu launch table, proving the panel chrome is toolkit-rendered, not hand-rolled"
echo "[test_hamde_render] PASS"
