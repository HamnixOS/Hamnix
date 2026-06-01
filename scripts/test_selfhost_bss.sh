#!/usr/bin/env bash
# scripts/test_selfhost_bss.sh — self-hosting milestone: NATIVE on-device
# execution of a program that uses BOTH .bss (zero-init array global) and
# .data (initialised string + non-zero scalar globals), emitted by the
# Adder-in-Adder backend.
#
# This closes the native RIP-relative-DATA gap left by
# scripts/test_selfhost_elf.sh (whose program had gdata_len == 0, so its
# native exec only exercised code — the .data/.bss RIP path was emulator-
# proven only). Here the emitted ELF has a real .data segment AND a .bss
# tail (p_memsz > p_filesz), so the CPU running it at CPL-3 proves the
# whole BSS model works natively, end to end.
#
# Two-phase pipeline (two QEMU boots in one test):
#
#   PHASE A — EMIT (boot #1):
#     /bin/codegen_bss_selftest runs the full on-device pipeline, emits a
#     complete user ELF for:
#       tag:  Array[8, uint32]            # zero-init array -> .bss
#       name: Array[4, uint8] = "Hi"      # string literal  -> .data
#       base: int32 = 10                  # non-zero scalar  -> .data
#       def main() -> int32:
#           tag[0] = 3
#           tag[1] = 4
#           return tag[0] + tag[1] + name[1] + base
#     (3 + 4 + 'i'(105) + 10 = 122), and dumps the ELF image to serial as
#     hex between [selfhost_bss_emit] HEXBEGIN / HEXEND sentinels.
#
#   HOST: decode the hex into build/user/selfhost_bss_emitted.elf. The
#     initramfs builder auto-stages every build/user/*.elf at /bin/<name>,
#     so the emitted ELF lands at /bin/selfhost_bss_emitted.
#
#   PHASE B — EXEC (boot #2):
#     hamsh EXECs /bin/selfhost_bss_emitted natively at CPL-3; its _start
#     stub calls the compiled main() at code vaddr 0 and SYS_EXITs with
#     main()'s return value (122).
#
# PASS criterion:
#   PHASE A: "[selfhost_bss_emit] PASS" present, hex captured.
#   PHASE B: kernel scheduler reports "task: pid <N> exited (code=122)".
#
# The PASS line means: the CPU executed codegen.ad-emitted machine code
# at CPL-3 that read+wrote a .bss array AND read initialised .data, and
# produced exit code 122 — NOT an emulator.
#
# Shape borrowed from scripts/test_selfhost_elf.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
EMIT_ELF=build/user/codegen_bss_selftest.elf
EMITTED_ELF=build/user/selfhost_bss_emitted.elf
EXPECT_EXIT=122

# --- (1/8) Bootstrap: Python compiler -> ASM from the emitter ---------
echo "[selfhost_bss] (1/8) Bootstrap: compile codegen_bss_selftest.ad to assembly"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    --emit-asm \
    adder/compiler/codegen_bss_selftest.ad \
    -o /tmp/codegen_bss_bootstrap.elf >/dev/null
BOOT_S=adder/compiler/codegen_bss_selftest.s
if grep -q "^elf_emit_image:" "$BOOT_S" && \
   grep -q "^gen_program_with_globals:" "$BOOT_S"; then
    echo "[selfhost_bss] OK: elf_emit_image + gen_program_with_globals symbols present"
else
    echo "[selfhost_bss] FAIL: bss emitter assembly missing expected symbols"
    head -20 "$BOOT_S" || true
    rm -f "$BOOT_S"
    exit 1
fi
rm -f "$BOOT_S"

# --- (2/8) Build userland (incl. codegen_bss_selftest) ---------------
echo "[selfhost_bss] (2/8) Build userland"
bash scripts/build_user.sh >/dev/null
if [ ! -f "$EMIT_ELF" ]; then
    echo "[selfhost_bss] FAIL: $EMIT_ELF not built"
    exit 1
fi
echo "[selfhost_bss] OK: codegen_bss_selftest.elf built"

# --- (3/8) Build modules ---------------------------------------------
echo "[selfhost_bss] (3/8) Build kernel modules"
bash scripts/build_modules.sh >/dev/null

# --- (4/8) Embed hamsh as /init + rebuild kernel --------------------
echo "[selfhost_bss] (4/8) Embed hamsh as /init + rebuild kernel"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# Restore the default initramfs (and remove the emitted ELF) on exit.
trap 'rm -f "$EMITTED_ELF"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

run_qemu() {
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
echo "[selfhost_bss] (5/8) PHASE A: emit ELF on-device"
LOG_A=$(mktemp)
set +e
run_qemu "$LOG_A" "/bin/codegen_bss_selftest" '\[selfhost_bss_emit\] (PASS|FAIL)'
qa_rc=$?
set -e

echo "[selfhost_bss] --- PHASE A emit lines ---"
grep -E '\[selfhost_bss_emit\]' "$LOG_A" | grep -v HEXBEGIN | grep -v HEXEND | head -20 || true
echo "[selfhost_bss] --- end ---"

if ! grep -F -q "[selfhost_bss_emit] PASS" "$LOG_A"; then
    echo "[selfhost_bss] FAIL: PHASE A did not reach PASS (qemu rc=${qa_rc})"
    tail -n 60 "$LOG_A"
    rm -f "$LOG_A"
    exit 1
fi
echo "[selfhost_bss] OK: PHASE A emitted ELF on-device"

# --- (6/8) HOST: reconstruct the emitted ELF -------------------------
echo "[selfhost_bss] (6/8) Reconstruct emitted ELF from serial hex"
awk '/\[selfhost_bss_emit\] HEXBEGIN/{f=1;next} /\[selfhost_bss_emit\] HEXEND/{f=0} f' "$LOG_A" \
    | tr -d '\r\n ' > /tmp/selfhost_bss_emitted.hex
HEXLEN=$(wc -c < /tmp/selfhost_bss_emitted.hex)
echo "[selfhost_bss] captured ${HEXLEN} hex chars ($((HEXLEN/2)) bytes)"
if [ "$HEXLEN" -lt 200 ] || [ $((HEXLEN % 2)) -ne 0 ]; then
    echo "[selfhost_bss] FAIL: implausible hex capture length ${HEXLEN}"
    rm -f "$LOG_A" /tmp/selfhost_bss_emitted.hex
    exit 1
fi
python3 -c "import binascii; open('$EMITTED_ELF','wb').write(binascii.unhexlify(open('/tmp/selfhost_bss_emitted.hex','rb').read().strip()))"
rm -f /tmp/selfhost_bss_emitted.hex "$LOG_A"
if [ ! -s "$EMITTED_ELF" ]; then
    echo "[selfhost_bss] FAIL: reconstructed ELF is empty"
    exit 1
fi
echo "[selfhost_bss] reconstructed $(file "$EMITTED_ELF")"
if [ "$(head -c4 "$EMITTED_ELF" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]; then
    echo "[selfhost_bss] FAIL: reconstructed file lacks ELF magic"
    exit 1
fi

# --- (7/8) Rebuild initramfs (auto-stages /bin/selfhost_bss_emitted) -
echo "[selfhost_bss] (7/8) Rebuild initramfs with emitted ELF + rebuild kernel"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

# --- (8/8) PHASE B: boot QEMU, EXEC the emitted ELF natively ---------
echo "[selfhost_bss] (8/8) PHASE B: native exec of self-host-emitted ELF"
LOG_B=$(mktemp)
set +e
run_qemu "$LOG_B" \
    "/bin/selfhost_bss_emitted" \
    "task: pid [0-9]+ exited \(code=" \
    "echo selfhost_bss native exec exit=\$status" \
    "selfhost_bss native exec exit="
qb_rc=$?
set -e

echo "[selfhost_bss] --- PHASE B exec lines ---"
grep -aE 'task: pid [0-9]+ exited|selfhost_bss native exec exit=|TRAP: vector' "$LOG_B" | head -10 || true
echo "[selfhost_bss] --- end ---"

fail=0
if grep -aE -q "task: pid [0-9]+ exited \(code=${EXPECT_EXIT}\)" "$LOG_B"; then
    echo "[selfhost_bss] OK: kernel reports emitted task exited code=${EXPECT_EXIT}"
    echo "[selfhost_bss] native exec exit=${EXPECT_EXIT}"
else
    echo "[selfhost_bss] MISS: kernel did not report code=${EXPECT_EXIT} exit"
    grep -aE "task: pid [0-9]+ exited" "$LOG_B" || true
    fail=1
fi

if grep -aF -q "selfhost_bss native exec exit=${EXPECT_EXIT}" "$LOG_B"; then
    echo "[selfhost_bss] OK: shell \$status echo also confirms exit=${EXPECT_EXIT}"
fi

if grep -aF -q "TRAP: vector" "$LOG_B"; then
    echo "[selfhost_bss] DIAG: kernel CPU exception during exec"
    grep -aF "TRAP: vector" "$LOG_B" | head -3 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[selfhost_bss] FAIL (qemu rc=${qb_rc})"
    echo "[selfhost_bss] --- PHASE B full log (last 100 lines) ---"
    tail -n 100 "$LOG_B"
    rm -f "$LOG_B"
    exit 1
fi
rm -f "$LOG_B"

echo "[selfhost_bss] PASS — CPU executed codegen.ad-emitted machine code at CPL-3 that used a .bss array + .data globals; compiled Adder main() returned exit=${EXPECT_EXIT}"
