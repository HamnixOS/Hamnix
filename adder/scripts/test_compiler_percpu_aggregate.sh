#!/usr/bin/env bash
# scripts/test_compiler_percpu_aggregate.sh — compiler regression for
# `Percpu[Array[N, T]]` / `Percpu[Struct]` aggregate access.
#
# History: scalar `Percpu[T]` reads/writes correctly emitted
# `%gs:offset` segment-prefixed loads/stores. But indexing or
# member-accessing a Percpu AGGREGATE silently fell through to
# `leaq buf(%rip)` — that resolves to the master per-CPU template,
# not THIS CPU's slot. Silent miscompile. The LANGUAGE.md audit
# (f676865) flagged it as `TODO(adder)`. The fix wires gen_index_load,
# the IndexExpr store path, gen_member_load, and the MemberExpr store
# path to detect Percpu-aggregate identifiers and emit %gs:-prefixed
# accesses; `&percpu_aggregate[i]` is rejected explicitly (no
# %gs-relative leaq exists).
#
# Host-side test only: assemble the fixture with `compiler.adder asm`
# and grep the emitted .s for the expected `%gs:` prefix on each
# aggregate access. (Genuine multi-CPU runtime verification needs the
# kernel's setup_percpu_asm.S to wire the GS base MSR per CPU, which
# the standalone adder repo can't provide.)
#
# PASS criterion: every accessor in the fixture emits a `%gs:`-prefixed
# load or store; NO accessor emits a `leaq <symbol>(%rip)` for its
# aggregate base; the `&percpu_aggregate[i]` rejection still fires.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

SRC=tests/test_compiler_percpu_aggregate.ad
ASM="$TMP/percpu.s"

echo "[percpu_aggregate] compiling fixture: $SRC"
if ! python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$SRC" -o "$ASM" >"$TMP/build.log" 2>&1; then
    echo "[percpu_aggregate] FAIL: fixture did not compile"
    cat "$TMP/build.log"
    exit 1
fi

fail=0

# extract_fn <name>: print just the body of an emitted function symbol.
extract_fn() {
    local name="$1"
    awk -v fn="$name" '
        $0 ~ "^"fn":$" { capture=1; next }
        capture && $0 ~ /^[[:space:]]*\.size '"$name"'/ { exit }
        capture { print }
    ' "$ASM"
}

require_match() {
    local fn="$1"; local regex="$2"; local label="$3"
    if extract_fn "$fn" | grep -qE "$regex"; then
        echo "  [$fn] OK: $label"
    else
        echo "  [$fn] FAIL: missing '$label' ($regex)"
        echo "  --- body ---"
        extract_fn "$fn" | sed 's/^/      /'
        fail=1
    fi
}

refute_match() {
    local fn="$1"; local regex="$2"; local label="$3"
    if extract_fn "$fn" | grep -qE "$regex"; then
        echo "  [$fn] FAIL: unexpected '$label' ($regex)"
        echo "  --- body ---"
        extract_fn "$fn" | sed 's/^/      /'
        fail=1
    else
        echo "  [$fn] OK: $label"
    fi
}

# Array load/store accessors. Each must emit a %gs:-prefixed
# load/store of the right size, and must NOT leaq the array symbol.
for size_pair in \
        "load_arr_u64:movq:%gs:" \
        "store_arr_u64:movq:%gs:" \
        "load_arr_u32:movl:%gs:" \
        "store_arr_u32:movl:%gs:" \
        "load_arr_u16:movzwq:%gs:" \
        "store_arr_u16:movw:%gs:" \
        "load_arr_u8:movzbq:%gs:" \
        "store_arr_u8:movb:%gs:" ; do
    fn="${size_pair%%:*}"
    rest="${size_pair#*:}"
    mnemonic="${rest%%:*}"
    require_match "$fn" "${mnemonic} .*%gs:" "${mnemonic} via %gs:"
    refute_match  "$fn" 'leaq arr_u[0-9]+\(%rip\)' \
        "no flat-address leaq of the Percpu aggregate"
done

# Struct field load/store accessors. Each must emit a %gs:offset
# (literal disp, no index register) load/store.
require_match load_hits   'movq %gs:[0-9]+, %rax'  'movq %gs:offset for hits'
require_match store_hits  'movq %rax, %gs:[0-9]+'  'movq %rax, %gs:offset for hits'
require_match load_misses 'movl %gs:[0-9]+, %eax'  'movl %gs:offset for misses'
require_match store_misses 'movl %eax, %gs:[0-9]+' 'movl %eax, %gs:offset for misses'
require_match load_flag   'movzbq %gs:[0-9]+, %rax' 'movzbq %gs:offset for flag'
require_match store_flag  'movb .*, %gs:[0-9]+'    'movb to %gs:offset for flag'

for fn in load_hits store_hits load_misses store_misses load_flag store_flag; do
    refute_match "$fn" 'leaq stats\(%rip\)' \
        "no flat-address leaq of the Percpu struct"
done

# Sanity: NO accessor in this file leaqs the master template address.
# (A grep over the whole assembled output catches anything the
# per-function checks would miss.)
if grep -nE 'leaq (arr_u[0-9]+|stats)\(%rip\)' "$ASM"; then
    echo "[percpu_aggregate] FAIL: emitter still leaqs an aggregate Percpu symbol"
    fail=1
else
    echo "  [whole-file] OK: no leaq <percpu_aggregate>(%rip) anywhere"
fi

# Negative case: `&percpu_arr[i]` must be REJECTED at codegen, since
# %gs-relative leaq isn't expressible.
echo "[percpu_aggregate] verifying &percpu_aggregate[i] is rejected"
cat > "$TMP/reject_addrof.ad" <<'EOF'
arr_x: Percpu[Array[4, uint64]]

def get_ptr() -> uint64:
    p: Ptr[uint64] = &arr_x[0]
    return cast[uint64](p)
EOF
if python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$TMP/reject_addrof.ad" -o "$TMP/reject.s" \
        >"$TMP/reject.log" 2>&1; then
    echo "[percpu_aggregate] FAIL: &percpu_arr[i] silently compiled"
    cat "$TMP/reject.s" | tail -20
    fail=1
elif grep -q "Percpu" "$TMP/reject.log"; then
    echo "  [reject_addrof] OK: &percpu_arr[i] rejected"
else
    echo "[percpu_aggregate] FAIL: rejection had wrong shape:"
    cat "$TMP/reject.log"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[percpu_aggregate] FAIL"
    exit 1
fi

echo "[percpu_aggregate] PASS"
exit 0
