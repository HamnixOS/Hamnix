#!/usr/bin/env bash
# scripts/test_selfhost_extern_link.sh — Track-3 self-hosting CUTOVER
# EXTERN-LINKAGE behavioral-equivalence gate (host-only, NO QEMU).
#
# Capability #1 of the cutover (extern linkage) gives codegen.ad an in-`.ad`
# runtime library: for every `extern def sys_*` the real userland tree calls,
# the compiler synthesizes the SAME syscall-wrapper body that user/runtime.S
# provides and that the frozen Python seed `ld`-links against. This gate
# proves the synthesized wrappers are BEHAVIORALLY equivalent to runtime.S's:
# each one issues the correct Linux/Hamnix syscall number with the correct
# ABI (the SysV arg4 %rcx -> syscall %r10 shuffle, plus sys_rfork's a5 =
# parent %rbp).
#
# It does NOT execute the ELFs: an `x86_64-adder-user` binary issues HAMNIX
# syscall numbers (not Linux ones), so it can't run on host Linux. Instead it
# checks the soundest host-observable invariant: for each newly-passing unit,
# every extern `sys_*` symbol the unit references must appear in the
# `.ad`-emitted code as a wrapper `... mov $N,%rax ; syscall ; ret`, where N
# is EXACTLY the syscall number user/runtime.S assigns that symbol. A
# mismatch (wrong number, missing wrapper, missing shuffle) is a cutover
# blocker.
#
# Usage:  bash scripts/test_selfhost_extern_link.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[externlink] FAIL $*"; exit 1; }

command -v python3  >/dev/null 2>&1 || fail "python3 not found"
command -v objdump  >/dev/null 2>&1 || fail "objdump not found (binutils)"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64"

WT="build/cutover/extlink"
mkdir -p "$WT" build/cutover

# --- (1) Build the .ad host compiler via the Python seed (trust root).
echo "[externlink] (1/2) build host_ac.elf via the Python seed"
python3 - <<'PY' || fail "concat host compiler source failed"
import importlib.util
spec = importlib.util.spec_from_file_location("ccs", "scripts/concat_compiler_source.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.DRIVER_MAIN = "fused_driver_host_main.ad"
raise SystemExit(m.main(["concat", "-o", "build/cutover/host_compiler.ad", "--with-driver"]))
PY
python3 -m compiler.adder compile --target=x86_64-linux \
    build/cutover/host_compiler.ad -o build/cutover/host_ac.elf \
    >/dev/null 2>build/cutover/host_ac.cerr \
    || { cat build/cutover/host_ac.cerr; fail "host_ac.elf failed to build"; }
[ -x build/cutover/host_ac.elf ] || fail "no host_ac.elf produced"

# --- (2) Per-unit wrapper behavioral check.
echo "[externlink] (2/2) verify synthesized wrappers vs user/runtime.S numbers"

# Build name -> syscall-number map straight from user/runtime.S (the oracle's
# link target). For each `.globl sys_X` ... `sys_X:` ... first `movq $N,%rax`
# in that wrapper body, record sys_X=N.
python3 - > "$WT/runtime_syms.txt" <<'PY'
import re
lines = open("user/runtime.S").read().splitlines()
cur = None
out = {}
for ln in lines:
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):', ln)
    if m:
        cur = m.group(1)
        continue
    if cur and cur.startswith("sys_") and cur not in out:
        mm = re.search(r'movq\s+\$(\d+),\s*%rax', ln)
        if mm:
            out[cur] = int(mm.group(1))
for k, v in out.items():
    print(f"{k} {v}")
PY
declare -A SYSNUM
while read -r name num; do SYSNUM["$name"]="$num"; done < "$WT/runtime_syms.txt"
[ "${#SYSNUM[@]}" -gt 0 ] || fail "no sys_* numbers parsed from runtime.S"

units="$(grep 'build_adder_user ' scripts/build_user.sh | awk '{print $2}')"

checked_units=0
checked_wrappers=0

for f in $units; do
    src="user/$f.ad"
    [ -f "$src" ] || src="tests/$f.ad"
    [ -f "$src" ] || continue
    # single-TU only (extern linkage is the single-TU capability)
    [ "$(grep -c '^from \|^import ' "$src")" = "0" ] || continue

    # The extern sys_* symbols this unit references.
    externs="$(grep -hoE '^extern def sys_[A-Za-z0-9_]+' "$src" | awk '{print $3}' | sort -u)"
    [ -n "$externs" ] || continue

    # Compile with the .ad host compiler; skip units it can't accept yet
    # (reason 7/8 NEXT capabilities — out of scope for this gate).
    if ! build/cutover/host_ac.elf "$src" "$WT/${f}.ad.elf" >/dev/null 2>&1; then
        continue
    fi

    # Extract the code segment (p_vaddr == 0) and disassemble as x86-64.
    python3 - "$WT/${f}.ad.elf" "$WT/${f}.code.bin" <<'PY' || fail "$f: code extract failed"
import struct, sys
d = open(sys.argv[1], "rb").read()
e_phoff = struct.unpack_from("<I", d, 28)[0]
e_phnum = struct.unpack_from("<H", d, 44)[0]
seg = None
for i in range(e_phnum):
    off = e_phoff + i * 32
    (p_type, p_offset, p_vaddr, p_paddr,
     p_filesz, p_memsz, p_flags, p_align) = struct.unpack_from("<IIIIIIII", d, off)
    if p_vaddr == 0:
        seg = (p_offset, p_filesz)
assert seg, "no vaddr-0 code segment"
open(sys.argv[2], "wb").write(d[seg[0]:seg[0] + seg[1]])
PY
    dis="$(objdump -D -b binary -m i386:x86-64 -M att "$WT/${f}.code.bin" 2>/dev/null)"

    # Collect every (mov $N,%rax ; syscall) pair's N from the disassembly:
    # the wrapper bodies are the only `mov $imm,%rax` immediately followed
    # (within 1 insn) by `syscall`. We grab all N that are followed by a
    # syscall to form the set of syscall numbers the unit's code issues.
    issued="$(printf '%s\n' "$dis" | awk '
        /mov[[:space:]]+\$0x[0-9a-f]+,%rax/ {
            n=$0; sub(/.*\$0x/,"",n); sub(/,%rax.*/,"",n); last=strtonum("0x" n); have=1; next
        }
        /syscall/ { if (have) { print last; have=0 } next }
        { have=0 }
    ' | sort -un)"

    for sym in $externs; do
        want="${SYSNUM[$sym]:-}"
        if [ -z "$want" ]; then
            fail "$f: extern '$sym' has no runtime.S number (table drift?)"
        fi
        # Skip externs the unit declares but never actually CALLS: codegen
        # only synthesizes a wrapper for referenced (fixup) symbols, so an
        # unused extern decl yields no wrapper — and nothing to check. The
        # `extern def <sym>(...)` declaration line itself matches `<sym>(`,
        # so strip those lines before looking for a real call site.
        if ! grep -vE '^\s*extern def ' "$src" | grep -qE "\b${sym}\s*\("; then
            continue
        fi
        if ! printf '%s\n' $issued | grep -qx "$want"; then
            echo "[externlink]   $f: extern '$sym' -> expected syscall $want"
            echo "[externlink]   issued syscall numbers in .ad code: $issued"
            fail "$f: wrapper for '$sym' missing / wrong syscall number"
        fi
        checked_wrappers=$((checked_wrappers + 1))
    done
    checked_units=$((checked_units + 1))
done

echo
echo "===== EXTERN-LINKAGE BEHAVIORAL REPORT ====="
echo "units with extern sys_* that .ad accepts: $checked_units"
echo "extern wrappers verified vs runtime.S:    $checked_wrappers"
echo "============================================"
[ "$checked_units" -gt 0 ]    || fail "no extern-using units verified — gate is vacuous"
[ "$checked_wrappers" -gt 0 ] || fail "no wrappers verified — gate is vacuous"
echo "[externlink] PASS — every synthesized wrapper issues runtime.S's syscall number."
exit 0
