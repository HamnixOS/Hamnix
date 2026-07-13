#!/usr/bin/env bash
# scripts/test_sort_gnu_crosscheck.sh
#
# Strong, QEMU-free proof that native `user/sort.ad` matches GNU `sort`.
#
# The Adder `x86_64-linux` target compiles the SAME sort.ad source that
# ships in the Hamnix initramfs into a static host ELF (sys_read/sys_write
# resolve to Linux read/write via user/linux-runtime.S). We then feed a
# battery of fixtures through both the native binary and the system
# `sort`, with the SAME flags, and assert BYTE-IDENTICAL output. Because
# the sort is stable, the reference is `LC_ALL=C sort -s` (C collation to
# match sort.ad's bytewise compare; -s for the stable tie-break sort.ad
# guarantees). This is the deterministic gate for the -n/-r/-u/-f/-k/-t
# option set — in particular that -n orders 2 before 10 (not 1 10 2).
#
# Registered in scripts/ci_battery_manifest.txt (Tier-1, no QEMU).

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$PROJ_ROOT/build/sort_crosscheck"
rm -rf "$WORK"
mkdir -p "$WORK"
ELF="$WORK/sort.elf"

# --- compile the shipped sort.ad for the host -------------------------
OUT="$(python3 -m compiler.adder compile --target=x86_64-linux \
    user/sort.ad -o "$ELF" 2>&1)" || fail "compile errored:
$OUT"
echo "$OUT" | grep -q "Compiled to" || fail "compiler did not report success:
$OUT"
[ -f "$ELF" ] || fail "no ELF produced at $ELF"
file "$ELF" | grep -q "ELF 64-bit" || fail "not a 64-bit ELF: $(file "$ELF")"

pass=0
# chk <desc> <input-with-\n-escapes> [flags...]
chk() {
    local desc="$1"; shift
    local input="$1"; shift
    local mine gnu
    mine="$(printf '%b' "$input" | "$ELF" "$@")"
    gnu="$(printf '%b' "$input" | LC_ALL=C sort -s "$@")"
    if [ "$mine" != "$gnu" ]; then
        echo "  input : $(printf '%b' "$input" | tr '\n' '|')" >&2
        echo "  flags : $*" >&2
        echo "  native: $(printf '%s' "$mine" | tr '\n' '|')" >&2
        echo "  gnu   : $(printf '%s' "$gnu" | tr '\n' '|')" >&2
        fail "mismatch vs GNU sort: $desc"
    fi
    echo "  ok: $desc"
    pass=$((pass + 1))
}

chk "plain lexicographic"      'banana\napple\ncherry\napple\n'
chk "numeric 2<10 (not 1 10 2)" '2\n10\n1\n'                       -n
chk "numeric two lines"        '2\n10\n'                           -n
chk "reverse"                  'b\na\nc\n'                         -r
chk "numeric reverse"          '2\n10\n1\n'                        -nr
chk "unique adjacent dups"     'a\nb\na\nb\nc\n'                   -u
chk "fold case"                'Banana\napple\nCherry\n'           -f
chk "negative numerics"        '-5\n3\n-10\n0\n'                   -n
chk "key -k2 numeric"          'apple 3\nbanana 1\ncherry 2\n'     -k2 -n
chk "key -k2 string"           'x c\ny a\nz b\n'                   -k2
chk "key range -k1,2"          'a 2 z\nb 1 y\n'                    -k1,2
chk "sep -t, key2 numeric"     'apple,3\nbanana,1\ncherry,2\n'     -t, -k2 -n
chk "sep -t: key1"             'zeb:1\nabe:2\n'                    -t: -k1
chk "unique numeric key"       '5\n5\n3\n3\n1\n'                   -u -n
chk "combined -nru"            '10\n2\n10\n1\n2\n'                 -nru

echo "PASS: sort matches GNU sort byte-for-byte on $pass fixtures"
exit 0
