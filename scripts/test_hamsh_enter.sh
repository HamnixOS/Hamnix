#!/usr/bin/env bash
# scripts/test_hamsh_enter.sh — HAMSH_SPEC §18 stage 7 acceptance.
#
# `enter` / `spawn` + handles (§11):
#   * `sandbox = ns { ... }` captures a namespace as a first-class
#     value (a template — configured but not entered).
#   * `enter s { body }` is SYNCHRONOUS: forks a child that applies a
#     fresh instance of `s`, runs the body; the shell blocks and
#     propagates the exit status. `enter s { false }` returns
#     nonzero. A variable set inside does NOT leak back (subshell).
#   * `spawn s { body }` is ASYNCHRONOUS: returns a process handle
#     immediately; `kill $svc` terminates it; the view tears down on
#     the process's exit.
#
# Model: enter/spawn are thin wrappers over rfork(RFPROC|RFNAMEG) +
# apply-the-captured-template; they differ only in whether the parent
# calls wait.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

bash scripts/build_user.sh >/dev/null
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # Capture a namespace template.
    printf 'sandbox = ns {\nbind /sbx_mark /tmp\n}\n'
    sleep 2
    # enter — synchronous; the template's bind is applied inside.
    printf 'enter sandbox {\necho ENTER_RAN\ncat /proc/self/ns\n}\n'
    sleep 3
    # enter s { false } must return nonzero, blocking to completion.
    printf 'enter sandbox {\nfalse\n}\n'
    sleep 2
    printf 'echo ENTER_FALSE_STATUS $status\n'
    sleep 1
    # A variable set inside `enter` must NOT leak back to the shell.
    # (Assignment RHS is an expression — bare words are var refs — so
    # the literal is quoted.)
    printf 'leakvar = "outside"\n'
    sleep 1
    printf 'enter sandbox {\nleakvar = "inside"\n}\n'
    sleep 2
    printf 'echo LEAKCHECK $leakvar\n'
    sleep 1
    # spawn — async; returns a handle; kill terminates it.
    printf 'svc = spawn sandbox {\nsleep 200\n}\n'
    sleep 2
    printf 'echo SPAWN_HANDLE $svc\n'
    sleep 1
    printf 'kill $svc\n'
    sleep 2
    printf 'echo SPAWN_KILLED\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 70s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

echo "[test_hamsh_enter] --- captured ---"
cat "$LOG"
echo "[test_hamsh_enter] --- end ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_hamsh_enter] OK: $2"
    else
        echo "[test_hamsh_enter] MISS: $2"
        fail=1
    fi
}

# enter ran the body and applied the captured template's bind.
check "ENTER_RAN"             "enter runs the body synchronously"
check "/sbx_mark"             "enter applies the captured ns template"
# enter s { false } returns nonzero.
check "ENTER_FALSE_STATUS 1"  "enter s { false } returns nonzero"
# spawn returned a handle and kill terminated the process.
check "SPAWN_HANDLE"          "spawn returns a process handle"
check "SPAWN_KILLED"          "kill \$svc terminated the spawned process"
if grep -F -q "pid 5 exited (code=137)" "$LOG" \
        || grep -E -q "pid [0-9]+ exited \(code=137\)" "$LOG"; then
    echo "[test_hamsh_enter] OK: spawned process killed by SIGKILL (137)"
else
    echo "[test_hamsh_enter] MISS: spawned process not SIGKILL-terminated"
    fail=1
fi

# A variable set inside `enter` must NOT leak — $leakvar stays
# "outside", never "inside".
if grep -F -q "LEAKCHECK outside" "$LOG"; then
    echo "[test_hamsh_enter] OK: variable set inside enter does not leak back"
elif grep -F -q "LEAKCHECK inside" "$LOG"; then
    echo "[test_hamsh_enter] FAIL: variable set inside enter LEAKED to the shell"
    fail=1
else
    echo "[test_hamsh_enter] MISS: leak check produced no output"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_enter] FAIL"
    exit 1
fi
echo "[test_hamsh_enter] PASS"
