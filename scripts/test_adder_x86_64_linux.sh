#!/usr/bin/env bash
# scripts/test_adder_x86_64_linux.sh — smoke test for the `x86_64-linux`
# Adder target: a FREESTANDING Adder program (no libc, no Plan 9 base)
# compiled to a native x86_64 Linux ELF and run on the HOST kernel.
#
# This is the host-tooling unlock for the compiler fuzzer + host
# self-hosting. It proves the new target end-to-end:
#   1. compile tests/test_x86_64_linux_fileio.ad --target=x86_64-linux
#   2. assert a genuine static elf64-x86-64 executable was produced
#   3. run it ON THE HOST: it open(2)/write(2)/read(2)/close(2)'s a file
#      via raw Linux syscalls, then exits with a status derived from the
#      bytes it read back
#   4. assert BOTH the on-disk file contents AND the exit code — i.e. the
#      file I/O and the exit reached the real host Linux kernel
#
# HOST-ONLY: no QEMU, no Hamnix image. Needs only `as`/`ld`/`gcc` (binutils
# + a C driver to preprocess user/linux-runtime.S).
#
# Prints "[test_adder_x86_64_linux] PASS" on success, or
# "[test_adder_x86_64_linux] FAIL ..." and exits non-zero.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() {
    echo "[test_adder_x86_64_linux] FAIL $*"
    exit 1
}

# --- toolchain presence -------------------------------------------------
command -v as  >/dev/null 2>&1 || fail "as not found (apt install binutils)"
command -v ld  >/dev/null 2>&1 || fail "ld not found (apt install binutils)"
command -v gcc >/dev/null 2>&1 || fail "gcc not found (needed to preprocess user/linux-runtime.S)"

# This test only makes sense when the host is x86_64 (we run the ELF).
HOST_ARCH="$(uname -m)"
[ "$HOST_ARCH" = "x86_64" ] || fail "host is $HOST_ARCH, need x86_64 to run the produced ELF"

WORK="$PROJ_ROOT/build/x86_64_linux_test"
rm -rf "$WORK"
mkdir -p "$WORK"
SRC="tests/test_x86_64_linux_fileio.ad"
ELF="$WORK/fileio.elf"
DAT="$WORK/roundtrip.dat"

[ -f "$SRC" ] || fail "missing test source $SRC"

# --- compile ------------------------------------------------------------
COMPILE_OUT="$(python3 -m compiler.adder compile --target=x86_64-linux \
    "$SRC" -o "$ELF" 2>&1)" || fail "compile errored:
$COMPILE_OUT"
echo "$COMPILE_OUT" | grep -q "Compiled to" \
    || fail "compiler did not report success:
$COMPILE_OUT"
[ -f "$ELF" ] || fail "no ELF produced at $ELF"

# --- assert it is a genuine static elf64-x86-64 executable --------------
FILE_OUT="$(file "$ELF")"
echo "$FILE_OUT" | grep -q "ELF 64-bit" \
    || fail "not a 64-bit ELF: $FILE_OUT"
echo "$FILE_OUT" | grep -q "x86-64" \
    || fail "not x86-64: $FILE_OUT"
echo "$FILE_OUT" | grep -q "statically linked" \
    || fail "not statically linked: $FILE_OUT"

# --- run on the host ----------------------------------------------------
rm -f "$DAT"
"$ELF" "$DAT"
RC=$?

# Expected exit code: bytes written/read = 72 97 109 16 32; sum = 326;
# 326 & 0xFF = 70. The program returns 95 on a round-trip mismatch and
# 90-94 on a syscall failure, so 70 confirms the full open/write/read path.
[ "$RC" -eq 70 ] || fail "exit code $RC != 70 (program reported a syscall/round-trip failure)"

# --- assert the file actually hit the host filesystem -------------------
[ -f "$DAT" ] || fail "program did not create $DAT on the host filesystem"
SIZE=$(stat -c%s "$DAT")
[ "$SIZE" -eq 5 ] || fail "file size $SIZE != 5 bytes"
BYTES="$(od -An -tu1 "$DAT" | tr -s ' ' | sed 's/^ //;s/ $//')"
[ "$BYTES" = "72 97 109 16 32" ] \
    || fail "file bytes '$BYTES' != '72 97 109 16 32'"

echo "[test_adder_x86_64_linux] host-run ELF: exit=$RC, file=$SIZE bytes [$BYTES]"
echo "[test_adder_x86_64_linux] PASS"
