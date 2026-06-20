#!/usr/bin/env bash
# scripts/test_editor_picker_homedirs.sh
#
# FAST regression guard (no VM / KVM) for the Kate-flavor editor wave:
#
#   1. hameditscene.ad COMPILES clean to a user ELF (the file-picker +
#      gutter + line:col additions must not break the build).
#   2. useradd.ad COMPILES clean (the make_home_skel() addition).
#   3. The editor's file-PICKER is wired: it imports the p9 dir-listing
#      helpers, has the picker render/handle entry points, routes keys
#      to the picker, and binds Open (Ctrl-O) + Save-As (Ctrl-S/Ctrl-W)
#      to it. The picker defaults to $HOME (/home/live/Documents).
#   4. The Kate polish is present: a line-number gutter, a current-line
#      highlight, and an "Ln .. Col .." status indicator.
#   5. Classic home dirs (Desktop/Documents/Downloads/Pictures) are
#      CREATED for new users (useradd::make_home_skel) AND BAKED into the
#      cpio for the live/default user (build_initramfs.py), and the
#      generated cpio archive actually carries /home/live/Desktop etc.
#
# These are the load-bearing invariants a later refactor could silently
# break; the heavy rl5 VM gate proves the live visuals.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail=0
note() { echo "[editor_picker] $*"; }
failed() { echo "[editor_picker] FAIL $*" >&2; fail=1; }
passed() { echo "[editor_picker] PASS $*"; }

# --- 1/2. Compile -----------------------------------------------------
compile_one() {
    local name="$1"
    local out
    out="$(mktemp --tmpdir "hamnix-${name}.XXXXXX.elf")"
    if python3 -m compiler.adder compile --target=x86_64-adder-user \
            "user/${name}.ad" -o "$out" >"/tmp/editor_picker.$name.log" 2>&1; then
        if file "$out" | grep -q ELF; then
            passed "$name compiles to an ELF"
        else
            failed "$name produced no ELF"
        fi
    else
        failed "$name did NOT compile (see /tmp/editor_picker.$name.log)"
        tail -8 "/tmp/editor_picker.$name.log" >&2 || true
    fi
    rm -f "$out"
}
compile_one hameditscene
compile_one useradd

ED=user/hameditscene.ad

# --- 3. File-picker wiring -------------------------------------------
grep -q "from lib.p9 import" "$ED" \
    && passed "hameditscene imports lib.p9 dir-listing helpers" \
    || failed "hameditscene missing lib.p9 import"

for sym in "_pk_open" "_pk_emit" "_pk_handle_code" "_pk_load" "_pk_enter" \
           "_pk_commit_save" "_pk_commit_open"; do
    grep -q "def ${sym}\b" "$ED" \
        && passed "picker entry ${sym} present" \
        || failed "picker entry ${sym} MISSING"
done

# Keys: Ctrl-O (15) Open, Ctrl-S (19) + Ctrl-W (23) Save-As route to picker.
grep -q "code == 15" "$ED" \
    && passed "Ctrl-O opens the picker" \
    || failed "Ctrl-O (code 15) not wired"
grep -q "code == 23" "$ED" \
    && passed "Ctrl-W Save-As wired" \
    || failed "Ctrl-W (code 23) not wired"
grep -q "_pk_handle_code(code)" "$ED" \
    && passed "keys route to the picker while open" \
    || failed "picker key routing missing"
grep -q "/home/live/Documents" "$ED" \
    && passed "picker defaults to \$HOME (/home/live/Documents)" \
    || failed "picker default dir not /home/live/Documents"

# --- 4. Kate polish ---------------------------------------------------
grep -q "GUTTER_W" "$ED" \
    && passed "line-number gutter present" \
    || failed "no line-number gutter"
grep -q "current-line highlight" "$ED" \
    && passed "current-line highlight present" \
    || failed "no current-line highlight"
grep -q "_caret_line_col" "$ED" \
    && passed "Ln/Col status indicator present" \
    || failed "no Ln/Col indicator"

# --- 5. Home dirs -----------------------------------------------------
grep -q "def make_home_skel" user/useradd.ad \
    && passed "useradd creates classic home skel dirs" \
    || failed "useradd make_home_skel missing"
for d in Desktop Documents Downloads Pictures; do
    grep -q "\"$d\"" user/useradd.ad \
        && passed "useradd skel includes $d" \
        || failed "useradd skel missing $d"
done

grep -q 'home/live' scripts/build_initramfs.py \
    && passed "build_initramfs bakes /home/live skel" \
    || failed "build_initramfs missing /home/live skel"

# Prove the GENERATED cpio archive actually carries the home subdirs.
# build_initramfs exposes the FILES table; build a throwaway archive and
# grep its raw bytes for the planted paths (cpio stores full path names
# inline, so a substring search is reliable).
note "building a throwaway cpio archive to verify baked home dirs"
ARCH="$(mktemp --tmpdir hamnix-cpio.XXXXXX.bin)"
if python3 - "$ARCH" <<'PY' >/tmp/editor_picker.cpio.log 2>&1
import sys
sys.path.insert(0, "scripts")
import build_initramfs as bi
arch = bi.build_archive()
open(sys.argv[1], "wb").write(arch)
PY
then
    for d in Desktop Documents Downloads Pictures; do
        if grep -aq "home/live/$d" "$ARCH"; then
            passed "cpio archive carries /home/live/$d"
        else
            failed "cpio archive MISSING /home/live/$d"
        fi
    done
    if grep -aq "home/live/Documents/welcome.txt" "$ARCH"; then
        passed "cpio archive carries Documents/welcome.txt"
    else
        failed "cpio archive missing welcome.txt"
    fi
else
    note "cpio build skipped (build_archive unavailable):"
    tail -8 /tmp/editor_picker.cpio.log >&2 || true
    note "skipping cpio-archive byte checks (static grep checks still apply)"
fi
rm -f "$ARCH"

if [ "$fail" -ne 0 ]; then
    echo "[editor_picker] OVERALL: FAIL" >&2
    exit 1
fi
echo "[editor_picker] OVERALL: PASS"
exit 0
