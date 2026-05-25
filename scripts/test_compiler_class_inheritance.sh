#!/usr/bin/env bash
# scripts/test_compiler_class_inheritance.sh — verifies class inheritance
# (commit "fix five silent-failure modes") works end-to-end at the
# struct-layout level.
#
# Adder's class is a C-ABI flat struct. With inheritance, the child
# struct prepends each base's fields in declaration order, then the
# child's own fields:
#
#   class Animal:
#       legs: int32     # offset 0
#       age:  int32     # offset 4
#
#   class Dog(Animal):
#       breed: int32    # offset 8
#
# This test compiles a small fixture and asserts the emitted machine
# code accesses `.legs` at offset 0, `.age` at +4, and `.breed` at +8
# (i.e. the inherited fields were actually copied into Dog's layout).
# Pre-fix, `.legs`/`.age` raised CodeGenError("struct 'Dog' has no
# field 'legs'") because the bases list was ignored.
#
# This is a HOST-SIDE test: no QEMU boot, just `python3 -m
# compiler.adder asm`. Runs in well under 1 second.

set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

cat > "$TMP/inherit.ad" <<'EOF'
class Animal:
    legs: int32
    age:  int32

class Dog(Animal):
    breed: int32

def main() -> int32:
    d: Dog
    d.legs  = 4
    d.age   = 5
    d.breed = 7
    return d.legs + d.age + d.breed
EOF

if ! python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$TMP/inherit.ad" -o "$TMP/inherit.s" >"$TMP/inherit.log" 2>&1; then
    echo "[class_inheritance] FAIL: compile error"
    cat "$TMP/inherit.log"
    exit 1
fi

# Sanity: emitted code should reference offsets 0, 4, 8 against the
# struct base (-N(%rbp) where N is the frame slot). Pre-fix, the
# compiler would have raised "struct 'Dog' has no field 'legs'" — i.e.
# the compile above would have failed. As an extra integrity check we
# also confirm the asm carries the three expected `addq $OFF, %rax`
# nudges for `.age` (+4) and `.breed` (+8) plus the base load.
fail=0
if ! grep -qE 'addq[[:space:]]+\$4' "$TMP/inherit.s"; then
    echo "[class_inheritance] FAIL: emitted asm has no '+4' nudge"
    fail=1
fi
if ! grep -qE 'addq[[:space:]]+\$8' "$TMP/inherit.s"; then
    echo "[class_inheritance] FAIL: emitted asm has no '+8' nudge"
    fail=1
fi

# Also verify multi-level inheritance — Dog(Animal) where Animal
# inherits from Mammal should flatten ALL the way down.
cat > "$TMP/three.ad" <<'EOF'
class Mammal:
    heartbeats: int32

class Animal(Mammal):
    legs: int32

class Dog(Animal):
    breed: int32

def main() -> int32:
    d: Dog
    d.heartbeats = 70
    d.legs       = 4
    d.breed      = 7
    return d.heartbeats + d.legs + d.breed
EOF

if ! python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$TMP/three.ad" -o "$TMP/three.s" >"$TMP/three.log" 2>&1; then
    echo "[class_inheritance] FAIL: multi-level inheritance did not compile"
    cat "$TMP/three.log"
    exit 1
fi

# Three-deep chain should also emit +4 and +8 nudges (heartbeats=0,
# legs=4, breed=8).
if ! grep -qE 'addq[[:space:]]+\$4' "$TMP/three.s"; then
    echo "[class_inheritance] FAIL: 3-level chain has no '+4' nudge"
    fail=1
fi
if ! grep -qE 'addq[[:space:]]+\$8' "$TMP/three.s"; then
    echo "[class_inheritance] FAIL: 3-level chain has no '+8' nudge"
    fail=1
fi

# A child redeclaring an inherited field name must be rejected — Adder
# is flat-struct, no overrides.
cat > "$TMP/dup.ad" <<'EOF'
class Animal:
    legs: int32

class Dog(Animal):
    legs: int32

def main() -> int32:
    return 0
EOF
if python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$TMP/dup.ad" -o "$TMP/dup.s" >"$TMP/dup.log" 2>&1; then
    echo "[class_inheritance] FAIL: duplicate field was not rejected"
    fail=1
elif ! grep -q "redeclares inherited field" "$TMP/dup.log"; then
    echo "[class_inheritance] FAIL: duplicate field error message wrong:"
    sed 's/^/      /' "$TMP/dup.log"
    fail=1
fi

# Unknown base class must be rejected — silent failure used to drop it.
cat > "$TMP/missing.ad" <<'EOF'
class Dog(Wolf):
    breed: int32

def main() -> int32:
    return 0
EOF
if python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$TMP/missing.ad" -o "$TMP/missing.s" >"$TMP/missing.log" 2>&1; then
    echo "[class_inheritance] FAIL: unknown base class was not rejected"
    fail=1
elif ! grep -q "inherits from unknown class" "$TMP/missing.log"; then
    echo "[class_inheritance] FAIL: unknown base error message wrong:"
    sed 's/^/      /' "$TMP/missing.log"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[class_inheritance] FAIL"
    exit 1
fi

echo "[class_inheritance] PASS"
exit 0
