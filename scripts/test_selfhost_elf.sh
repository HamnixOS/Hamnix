#!/usr/bin/env bash
# scripts/test_selfhost_elf.sh — self-hosting milestone: NATIVE on-device
# execution of machine code emitted by the Adder-in-Adder backend.
#
# This closes the emulator -> native gap left by test_selfhost_codegen.sh
# (which only INTERPRETED the emitted bytes). Here the bytes that the
# self-hosted backend (lexer.ad -> parser.ad -> codegen.ad -> elf_emit.ad)
# emits are wrapped into a real elf32-i386 user ELF and then RUN by the
# CPU at CPL-3 under QEMU, producing an observable process exit code.
#
# Two-phase pipeline (two QEMU boots in one test):
#
#   PHASE A — EMIT (boot #1):
#     /bin/codegen_elf_selftest runs the full on-device pipeline, emits a
#     complete user ELF for a small REAL Adder program
#       def main() -> int32:
#           acc: int32 = 0; i: int32 = 65
#           while i <= 90: acc = acc + classify(i); i = i + 1
#           return acc
#       def classify(c: int32) -> int32:
#           if c >= 65 and c <= 90: return 1
#           return 0
#     (counts 'A'..'Z' -> 26), and dumps the ELF image to serial as hex
#     between [selfhost_elf_emit] HEXBEGIN / HEXEND sentinels.
#
#   HOST: decode the hex into build/user/selfhost_emitted.elf. The
#     initramfs builder auto-stages every build/user/*.elf at /bin/<name>,
#     so the emitted ELF lands at /bin/selfhost_emitted.
#
#   PHASE B — EXEC (boot #2):
#     hamsh EXECs /bin/selfhost_emitted natively at CPL-3; its _start stub
#     calls the compiled main() at code vaddr 0 and SYS_EXITs with main()'s
#     return value (26). The shell prints `echo selfhost_elf exit=$status`.
#
# PASS criterion:
#   PHASE A: "[selfhost_elf_emit] PASS" present, hex captured.
#   PHASE B: "[selfhost_elf] native exec exit=26" present.
#   => "[selfhost_elf] PASS"
#
# The PASS line means: the CPU actually executed codegen.ad-emitted
# machine code at CPL-3 and the compiled Adder program produced exit
# code 26 — NOT an emulator.
#
# Shape borrowed from scripts/test_selfhost_codegen.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
EMIT_ELF=build/user/codegen_elf_selftest.elf
EMITTED_ELF=build/user/selfhost_emitted.elf
EXPECT_EXIT=26

# --- (1/8) Bootstrap: Python compiler -> ASM from elf_emit.ad ---------
# Prove the new self-hosted ELF emitter is valid Adder and links against
# the Adder-in-Adder codegen.
echo "[selfhost_elf] (1/8) Bootstrap: compile elf_emit.ad to assembly"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    --emit-asm \
    adder/compiler/codegen_elf_selftest.ad \
    -o /tmp/codegen_elf_bootstrap.elf >/dev/null
BOOT_S=adder/compiler/codegen_elf_selftest.s
if grep -q "^elf_emit_image:" "$BOOT_S" && \
   grep -q "^gen_program_with_globals:" "$BOOT_S"; then
    echo "[selfhost_elf] OK: elf_emit_image + gen_program_with_globals symbols present"
else
    echo "[selfhost_elf] FAIL: elf_emit assembly missing expected symbols"
    head -20 "$BOOT_S" || true
    rm -f "$BOOT_S"
    exit 1
fi
rm -f "$BOOT_S"

# --- (2/8) Build userland (incl. codegen_elf_selftest) ---------------
echo "[selfhost_elf] (2/8) Build userland"
bash scripts/build_user.sh >/dev/null
if [ ! -f "$EMIT_ELF" ]; then
    echo "[selfhost_elf] FAIL: $EMIT_ELF not built"
    exit 1
fi
echo "[selfhost_elf] OK: codegen_elf_selftest.elf built"

# --- (3/8) Build modules ---------------------------------------------
echo "[selfhost_elf] (3/8) Build kernel modules"
bash scripts/build_modules.sh >/dev/null

# --- (4/8) Embed hamsh as /init + rebuild kernel --------------------
echo "[selfhost_elf] (4/8) Embed hamsh as /init + rebuild kernel"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# Restore the default initramfs (and remove the emitted ELF) on exit so a
# failed run doesn't leave a stale /init or a stale staged binary behind.
trap 'rm -f "$EMITTED_ELF"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

run_qemu() {
    # $1 = log file, $2 = first command to type, $3 = regex to wait for
    # after the first command, $4 (optional) = a second command typed once
    # $3 matched, $5 (optional) = regex to wait for after the second.
    # hamsh's parser does NOT accept `cmd; cmd` compounds or `$status` in
    # the same line as another command, so phase B types the binary and
    # the status-echo as two SEPARATE prompt lines.
    local log="$1" cmd="$2" donere="$3" cmd2="${4:-}" donere2="${5:-}"
    local fifo
    fifo=$(mktemp -u)
    mkfifo "$fifo"
    (
        exec 3>"$fifo"
        for _ in $(seq 1 600); do
            grep -q "shell ready" "$log" 2>/dev/null && break
            sleep 0.1
        done
        sleep 1
        printf '%s\n' "$cmd" >&3
        for _ in $(seq 1 600); do
            grep -Eq "$donere" "$log" 2>/dev/null && break
            sleep 0.1
        done
        sleep 1
        if [ -n "$cmd2" ]; then
            printf '%s\n' "$cmd2" >&3
            for _ in $(seq 1 600); do
                grep -Eq "$donere2" "$log" 2>/dev/null && break
                sleep 0.1
            done
            sleep 1
        fi
        printf 'exit\n' >&3
        sleep 1
        exec 3>&-
    ) &
    local driver_pid=$!
    timeout 120s qemu-system-x86_64 \
        -kernel "$ELF" \
        -smp 2 \
        -nographic \
        -no-reboot \
        -m 256M \
        -monitor none \
        -serial stdio \
        < "$fifo" \
        > "$log" 2>&1
    local rc=$?
    kill "$driver_pid" 2>/dev/null
    wait "$driver_pid" 2>/dev/null || true
    rm -f "$fifo"
    return $rc
}

# --- (5/8) PHASE A: boot QEMU, run the on-device ELF emitter ----------
echo "[selfhost_elf] (5/8) PHASE A: emit ELF on-device"
LOG_A=$(mktemp)
set +e
run_qemu "$LOG_A" "/bin/codegen_elf_selftest" '\[selfhost_elf_emit\] (PASS|FAIL)'
qa_rc=$?
set -e

echo "[selfhost_elf] --- PHASE A emit lines ---"
grep -E '\[selfhost_elf_emit\]' "$LOG_A" | grep -v HEXBEGIN | grep -v HEXEND | head -20 || true
echo "[selfhost_elf] --- end ---"

if ! grep -F -q "[selfhost_elf_emit] PASS" "$LOG_A"; then
    echo "[selfhost_elf] FAIL: PHASE A did not reach PASS (qemu rc=${qa_rc})"
    tail -n 60 "$LOG_A"
    rm -f "$LOG_A"
    exit 1
fi
echo "[selfhost_elf] OK: PHASE A emitted ELF on-device"

# --- (6/8) HOST: reconstruct the emitted ELF -------------------------
echo "[selfhost_elf] (6/8) Reconstruct emitted ELF from serial hex"
# Extract the hex between HEXBEGIN and HEXEND, strip CRs, concatenate, and
# convert to binary. The dump is pure lowercase hex, 64 chars per line.
awk '/\[selfhost_elf_emit\] HEXBEGIN/{f=1;next} /\[selfhost_elf_emit\] HEXEND/{f=0} f' "$LOG_A" \
    | tr -d '\r\n ' > /tmp/selfhost_emitted.hex
HEXLEN=$(wc -c < /tmp/selfhost_emitted.hex)
echo "[selfhost_elf] captured ${HEXLEN} hex chars ($((HEXLEN/2)) bytes)"
if [ "$HEXLEN" -lt 200 ] || [ $((HEXLEN % 2)) -ne 0 ]; then
    echo "[selfhost_elf] FAIL: implausible hex capture length ${HEXLEN}"
    rm -f "$LOG_A" /tmp/selfhost_emitted.hex
    exit 1
fi
# hex -> binary via python3 (xxd is not guaranteed present on the host).
python3 -c "import binascii; open('$EMITTED_ELF','wb').write(binascii.unhexlify(open('/tmp/selfhost_emitted.hex','rb').read().strip()))"
rm -f /tmp/selfhost_emitted.hex "$LOG_A"
if [ ! -s "$EMITTED_ELF" ]; then
    echo "[selfhost_elf] FAIL: reconstructed ELF is empty"
    exit 1
fi
echo "[selfhost_elf] reconstructed $(file "$EMITTED_ELF")"
# Sanity: must be an ELF (0x7f 'E' 'L' 'F').
if [ "$(head -c4 "$EMITTED_ELF" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]; then
    echo "[selfhost_elf] FAIL: reconstructed file lacks ELF magic"
    exit 1
fi

# --- (7/8) Rebuild initramfs (auto-stages /bin/selfhost_emitted) -----
echo "[selfhost_elf] (7/8) Rebuild initramfs with emitted ELF + rebuild kernel"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# --- (8/8) PHASE B: boot QEMU, EXEC the emitted ELF natively ---------
# The authoritative observable is the kernel scheduler's own
# "task: pid <N> exited (code=<X>)" line — emitted when the CPU runs the
# emitted binary's _start -> compiled main() -> SYS_EXIT at CPL-3. We
# ALSO type a status echo as a separate prompt line for a second,
# user-visible witness of the same exit code.
echo "[selfhost_elf] (8/8) PHASE B: native exec of self-host-emitted ELF"
LOG_B=$(mktemp)
set +e
run_qemu "$LOG_B" \
    "/bin/selfhost_emitted" \
    "task: pid [0-9]+ exited \(code=" \
    "echo selfhost_elf native exec exit=\$status" \
    "selfhost_elf native exec exit="
qb_rc=$?
set -e

echo "[selfhost_elf] --- PHASE B exec lines ---"
grep -aE 'task: pid [0-9]+ exited|selfhost_elf native exec exit=|TRAP: vector' "$LOG_B" | head -10 || true
echo "[selfhost_elf] --- end ---"

fail=0
# Primary: kernel scheduler reports the emitted task exited with code 26.
if grep -aE -q "task: pid [0-9]+ exited \(code=${EXPECT_EXIT}\)" "$LOG_B"; then
    echo "[selfhost_elf] OK: kernel reports emitted task exited code=${EXPECT_EXIT}"
    echo "[selfhost_elf] native exec exit=${EXPECT_EXIT}"
else
    echo "[selfhost_elf] MISS: kernel did not report code=${EXPECT_EXIT} exit"
    grep -aE "task: pid [0-9]+ exited" "$LOG_B" || true
    fail=1
fi

# Secondary witness: hamsh's $status echo (best-effort; the primary
# kernel line is the gating assertion).
if grep -aF -q "selfhost_elf native exec exit=${EXPECT_EXIT}" "$LOG_B"; then
    echo "[selfhost_elf] OK: shell \$status echo also confirms exit=${EXPECT_EXIT}"
fi

if grep -aF -q "TRAP: vector" "$LOG_B"; then
    echo "[selfhost_elf] DIAG: kernel CPU exception during exec"
    grep -aF "TRAP: vector" "$LOG_B" | head -3 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[selfhost_elf] FAIL (qemu rc=${qb_rc})"
    echo "[selfhost_elf] --- PHASE B full log (last 100 lines) ---"
    tail -n 100 "$LOG_B"
    rm -f "$LOG_B"
    exit 1
fi
rm -f "$LOG_B"

echo "[selfhost_elf] PASS — CPU executed codegen.ad-emitted machine code at CPL-3; compiled Adder main() returned exit=${EXPECT_EXIT}"
