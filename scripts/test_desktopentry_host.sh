#!/usr/bin/env bash
# scripts/test_desktopentry_host.sh — FAST, QEMU-free host gate for the
# `.desktop` parser (lib/desktopentry.ad) that makes the DE application
# menu DATA-DRIVEN. Compiles the pure parser + a host harness for the
# x86_64-linux target, feeds it in-memory `.desktop` fixtures, and asserts
# the parsed Name / Exec-program / category classification / display flag.
# Also confirms the parser still links into the NATIVE panel that consumes
# it (user/hampanelscene.ad) — all in milliseconds, no QEMU.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/desktopentry_host"
mkdir -p "$OUT"
fail=0

echo "[deskentry-host] compiling parser + harness for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        tests/desktopentry_host.ad -o "$BIN" 2>"$OUT/deskentry_compile.log"; then
    echo "[deskentry-host] FAIL: host harness did not compile"
    cat "$OUT/deskentry_compile.log"; exit 1
fi
echo "[deskentry-host] PASS host harness compiled -> $BIN"

echo "[deskentry-host] compiling NATIVE hampanelscene (consumer) ..."
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hampanelscene.ad -o "$OUT/hampanelscene.elf" \
        2>"$OUT/deskentry_native.log"; then
    echo "[deskentry-host] FAIL: hampanelscene did not compile against the parser"
    cat "$OUT/deskentry_native.log"; exit 1
fi
echo "[deskentry-host] PASS hampanelscene still compiles with the parser"

DUMP="$OUT/deskentry_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[deskentry-host] FAIL: host harness exited non-zero"; cat "$DUMP"; exit 1
fi
echo "[deskentry-host] ---- parser output ----"
cat "$DUMP"
echo "[deskentry-host] -----------------------"

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then
        echo "[deskentry-host] PASS $msg"
    else
        echo "[deskentry-host] FAIL $msg (missing: $pat)"; fail=1
    fi
}

# Field-code + whitespace stripping: Exec="/bin/ham2048scene %U" -> prog only.
assert_grep '^PARSE game ok=1 name=2048 prog=/bin/ham2048scene cat=Games nodisplay=0' \
    "Game entry parses; %U field code stripped; classified Games"
# CRLF + leading comment/blank-line tolerance; Network -> Internet.
assert_grep '^PARSE net ok=1 name=Web Browser prog=/bin/hambrowse cat=Internet' \
    "Network entry parses through CRLF + comments; classified Internet"
# Utility -> Accessories.
assert_grep '^PARSE util ok=1 name=Calculator prog=/bin/hamcalcscene cat=Accessories' \
    "Utility entry classified Accessories"
# Priority: Settings beats System.
assert_grep '^PARSE settings ok=1 name=Settings prog=/bin/hamsettings cat=Settings' \
    "Settings;System; classified Settings (priority order)"
# NoDisplay=true rejected.
assert_grep '^PARSE hidden ok=0 .* nodisplay=1' \
    "NoDisplay=true entry rejected"
# Wrong Type rejected.
assert_grep '^PARSE dir ok=0 ' \
    "Type=Directory entry rejected"
# Missing Exec rejected.
assert_grep '^PARSE noexec ok=0 ' \
    "entry with no Exec rejected"
# Keys outside [Desktop Entry] ignored.
assert_grep '^PARSE scoped ok=1 name=Scoped prog=/bin/hamterm' \
    "keys outside [Desktop Entry] ignored"
# REAL Debian: full freedesktop Firefox .desktop — extra keys tolerated,
# C-locale Name (not Name[de]) chosen, %u field code stripped, Network ->
# Internet, [Desktop Action] group boundary respected, Terminal=false.
assert_grep '^PARSE firefox ok=1 name=Firefox prog=/usr/bin/firefox cat=Internet nodisplay=0 terminal=0' \
    "full freedesktop Firefox entry parses (localized keys + Actions tolerated)"
# Terminal=true Debian CLI app parses and surfaces the terminal flag.
assert_grep '^PARSE cli ok=1 name=htop prog=htop cat=System nodisplay=0 terminal=1' \
    "Terminal=true CLI entry parses; terminal flag surfaced"
# Suffix helper.
assert_grep '^SUFFIX yes=1 no=0' \
    ".desktop suffix detector works"

if [ "$fail" -eq 0 ]; then
    echo "[deskentry-host] RESULT: PASS"
    exit 0
else
    echo "[deskentry-host] RESULT: FAIL"
    exit 1
fi
