#!/usr/bin/env bash
# scripts/test_compiler_module_private.sh — compiler regression for
# per-module symbol scoping (module-private leading-underscore names).
#
# Before the fix, merge_programs() flat-namespaced every module's
# top-level declarations, so two .ad files each defining a private
# `_helper` was a HARD ERROR. The fix mangles leading-underscore
# top-level names per-module (`<module>__<name>`) and rewrites
# intra-module references; non-underscore names stay global, and a
# name explicitly imported by another module is promoted to public.
#
# This drives a THREE-module fixture (tests/test_compiler_module_private.ad
# importing tests/modpriv_a.ad + tests/modpriv_b.ad) where all three
# modules define a private `_scale` with different bodies.
#
# Two-layer test:
#   1. Host-side: a minimal two-module reproducer (two files each with
#      a private `_helper`, both used) must compile via `compiler.adder`
#      — today's flat namespace rejects it with "duplicate top-level
#      definition". Also asserts the two `_helper`s land as distinct,
#      module-mangled symbols in the emitted assembly.
#   2. Kernel-side: build tests/test_compiler_module_private.ad as a
#      userland ELF, plant as /init, boot QEMU, grep for `[modpriv] PASS`
#      — which prints only if each module's `_scale` resolved to its
#      own body.
#
# PASS criterion: host repro compiles + distinct symbols emitted, and
#                 `[modpriv] PASS` in the serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

echo "[modpriv] (1/3) Host-side: two modules, same private helper name"
# A real two-module reproducer placed under tests/ so the import
# resolver (resolve_import) finds it as `tests.<stem>`.
cat > "$ROOT/tests/_modpriv_repro_a.ad" <<'EOF'
def _helper(x: int32) -> int32:
    return x + 1
def repro_a(x: int32) -> int32:
    return _helper(x)
EOF
cat > "$ROOT/tests/_modpriv_repro_main.ad" <<'EOF'
from tests._modpriv_repro_a import repro_a
extern def sys_exit(code: int32)
def _helper(x: int32) -> int32:
    return x + 2
def main():
    sys_exit(repro_a(0) + _helper(0))
EOF
trap "rm -rf $TMP; rm -f $ROOT/tests/_modpriv_repro_a.ad $ROOT/tests/_modpriv_repro_main.ad" EXIT

# `compile --emit-asm` (NOT `asm`) so import resolution + the
# per-module scoping pass run — the bare `asm` subcommand is
# single-file and would not merge the two modules.
mkdir -p build/user
if ! python3 -m compiler.adder compile --target=x86_64-adder-user --emit-asm \
        "$ROOT/tests/_modpriv_repro_main.ad" \
        -o build/user/_modpriv_repro_main.elf \
        >"$TMP/repro.log" 2>&1; then
    echo "[modpriv] FAIL: two-module same-private-helper repro did not compile"
    cat "$TMP/repro.log"
    exit 1
fi
cp "$ROOT/tests/_modpriv_repro_main.s" "$TMP/repro.s"
rm -f "$ROOT/tests/_modpriv_repro_main.s"
# Both `_helper`s must survive as DISTINCT, module-mangled symbols.
# (The bare `_helper` label must NOT appear as a definition.)
nhelper=$(grep -cE '^tests__modpriv_repro_(a|main)__helper:' "$TMP/repro.s" || true)
if [ "$nhelper" -ne 2 ]; then
    echo "[modpriv] FAIL: expected 2 module-mangled _helper symbols, got $nhelper"
    grep -nE '_helper' "$TMP/repro.s" || true
    exit 1
fi
echo "[modpriv] OK: two private _helper symbols mangled per-module"

echo "[modpriv] (2/3) Build tests/test_compiler_module_private.ad"
INIT_ELF=build/user/test_compiler_module_private.elf
# build/user is wiped by _build_lock.sh's clean-build auto-wipe; recreate
# it before compiling straight into it.
mkdir -p build/user
if ! python3 -m compiler.adder compile --target=x86_64-adder-user \
        tests/test_compiler_module_private.ad -o "$INIT_ELF" \
        >"$TMP/build.log" 2>&1; then
    echo "[modpriv] FAIL: fixture did not compile"
    cat "$TMP/build.log"
    exit 1
fi

INIT_ELF="$INIT_ELF" python3 scripts/build_initramfs.py >"$TMP/initramfs.log" 2>&1
python3 -m compiler.adder compile --target=x86_64-bare-metal init/main.ad \
    >"$TMP/kbuild.log" 2>&1

echo "[modpriv] (3/3) Boot QEMU + grep for [modpriv] PASS"
qemu-system-x86_64 -kernel init/main.elf -nographic \
    -append "console=ttyS0" -no-reboot -m 256M \
    > "$TMP/serial.log" 2>&1 &
QEMU=$!
for _i in $(seq 1 60); do
    sleep 1
    if grep -q "\[modpriv\] PASS" "$TMP/serial.log" 2>/dev/null; then break; fi
    kill -0 $QEMU 2>/dev/null || break
done
kill -9 $QEMU 2>/dev/null || true
wait $QEMU 2>/dev/null || true

if grep -q "\[modpriv\] PASS" "$TMP/serial.log"; then
    echo "[modpriv] PASS"
    exit 0
fi
echo "[modpriv] FAIL"
tail -30 "$TMP/serial.log"
exit 1
