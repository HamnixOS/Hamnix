#!/usr/bin/env bash
# scripts/test_compiler_ptr_local.sh — compiler regression for `Ptr[T]`
# writes through `&local`.
#
# The bug, in two sentences: codegen stored scalar locals with a full
# 8-byte `movq` regardless of declared size, and read them back with a
# full 8-byte `movq`. When a callee wrote through `Ptr[int32]` to such
# a slot it correctly emitted `movl` (4 bytes), so the upper 4 bytes
# of the slot kept whatever junk was there from the local's
# initialiser — and the caller's readback saw that junk.
#
# Before the fix: every `&local` out-param across the kernel had to
# route through a top-level `Array[N, T]` global. With the fix, &local
# Just Works and three scratch globals (io_prp1_scratch / io_prp2_scratch
# in nvme.ad, _srv_open_scratch in syscall.ad, _srv_open_scratch_vfs in
# vfs.ad) can be retired.
#
# Two-layer test:
#   1. Host-side asm-shape check: compile a minimal `&local` reproducer
#      with `compiler.adder asm` and assert the emitted store for the
#      int32 local's initialiser is `movl` (sized), not `movq`. Catches
#      the bug at the asm-text level without a QEMU boot.
#   2. Userland fixture (tests/test_compiler_ptr_local.ad): compile to
#      an x86_64-adder-user ELF, plant at /bin/test_compiler_ptr_local,
#      boot QEMU + hamsh, drive the binary, grep the serial log for
#      the [ptr_local] PASS banner.
#
# Shape borrowed from scripts/test_lex_digit_idents.sh.
#
# PASS criterion (host side):   "movl %eax, -" appears in main's
#                                int32 = -1 init (and `movq %rax, -`
#                                does NOT appear for that init).
# PASS criterion (kernel side): `[ptr_local] PASS` in serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_compiler_ptr_local.elf

echo "[ptr_local] (1/6) Host-side asm-shape sanity check"
HOST_TMP="$(mktemp -d)"
trap 'rm -rf "$HOST_TMP"' EXIT
cat > "$HOST_TMP/repro.ad" <<'EOF'
def callee(out_a: Ptr[int32], out_b: Ptr[int32]):
    out_a[0] = 42
    out_b[0] = 99

def main() -> int32:
    a: int32 = -1
    b: int32 = -1
    callee(&a, &b)
    if a != 42:
        return 1
    if b != 99:
        return 2
    return 0
EOF
python3 -m compiler.adder asm --target=x86_64-adder-user \
    "$HOST_TMP/repro.ad" -o "$HOST_TMP/repro.s" >/dev/null

# After the fix, the int32 local's initialiser must use a sized store
# (movl), not a 64-bit movq. We don't pin the exact offset because
# alloc_local picks it, but the pattern below is unambiguous.
if grep -qE '^[[:space:]]+movl %eax, -[0-9]+\(%rbp\)' "$HOST_TMP/repro.s"; then
    echo "[ptr_local] OK: scalar int32 local init uses movl (sized store)"
else
    echo "[ptr_local] FAIL: no movl-sized store to a local found"
    echo "[ptr_local] --- emitted asm ---"
    cat "$HOST_TMP/repro.s"
    exit 1
fi

# After the fix, the readback of an int32 local must use a sign-
# extending load (movslq), not a 64-bit movq, so signed compares
# still work and `Ptr[int32]` writes round-trip.
if grep -qE '^[[:space:]]+movslq -[0-9]+\(%rbp\), %rax' "$HOST_TMP/repro.s"; then
    echo "[ptr_local] OK: scalar int32 local read uses movslq (sized signed load)"
else
    echo "[ptr_local] FAIL: no movslq-sized load from a local found"
    echo "[ptr_local] --- emitted asm ---"
    cat "$HOST_TMP/repro.s"
    exit 1
fi

echo "[ptr_local] (2/6) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[ptr_local] (3/6) Build tests/test_compiler_ptr_local.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_compiler_ptr_local.ad \
    -o "$TEST_ELF" >/dev/null

echo "[ptr_local] (4/6) Plant /init = hamsh + /bin/test_compiler_ptr_local in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[ptr_local] (5/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[ptr_local] (6/6) Boot QEMU + drive /bin/test_compiler_ptr_local via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; rm -rf "$HOST_TMP"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/test_compiler_ptr_local\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[ptr_local] --- captured output ---"
cat "$LOG"
echo "[ptr_local] --- end output ---"

fail=0

check_marker() {
    local marker="$1"
    local label="$2"
    if grep -F -q "$marker" "$LOG"; then
        echo "[ptr_local] OK: $label"
    else
        echo "[ptr_local] MISS: $label ($marker)"
        fail=1
    fi
}

check_marker "[ptr_local] start"                       "fixture ran"
check_marker "[ptr_local] case_two_int32 OK"           "two int32 &locals round-trip"
check_marker "[ptr_local] case_narrow_scalars OK"      "int16/int8 &locals round-trip"
check_marker "[ptr_local] case_u64 OK"                 "uint64 &local round-trip (no regression)"
check_marker "[ptr_local] case_signed_negative OK"     "signed negative round-trip (sign-extending load)"
check_marker "[ptr_local] case_dirty_upper_half OK"    "minimal upper-half-dirty repro fixed"
check_marker "[ptr_local] PASS"                        "fixture reached PASS"

if grep -F -q "[ptr_local] FAIL" "$LOG"; then
    echo "[ptr_local] MISS: per-assertion FAIL line(s) present:"
    grep -F "[ptr_local] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[ptr_local] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[ptr_local] PASS"
