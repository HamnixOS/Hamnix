#!/usr/bin/env bash
# scripts/test_hamsh_fdbind.sh — HAMSH_SPEC §18 stage 4 acceptance.
#
# Stdio-as-/fd + pipe/redirect/dup as bind (§7):
#   * `a | b`     resolves to pipe-Chan binds at /fd/1 (producer) and
#                 /fd/0 (consumer) — the pipeline carries data through.
#   * `cmd > f`   binds a file Chan at /fd/1 — output lands in the file.
#   * `cmd 2>&1`  dup-as-bind: /fd/1's Chan is bound also at /fd/2.
#   * CRITICAL (§6): a LOCAL pipe does NO mountrpc. /dev/mountrpc — the
#     cumulative 9P-T-message counter — must read the SAME value before
#     and after a local pipeline. Same shape as the Phase D FD_*_MARK
#     tripwire tests: a local pipe is direct Chan reads, never 9P.
#
# The model: pipe / redirect / dup are ALL the one operation —
# sys_fdbind, "bind a Chan at an /fd/N name". /fd/N is a name in the
# process's Pgrp namespace, served by the `#d` device; the Linux
# integer fd is a Layer-2 mapping onto that name.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_hamsh_log.sh"
. "$(dirname "$0")/_qemu_drive.sh"

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

# Prompt-gated drive (scripts/_qemu_drive.sh): wait for hamsh's banner
# before sending the first command, instead of a fixed `sleep 3` that
# loses the first line whenever boot is slow (the input used to be
# shoved at the 16550 RX FIFO before hamsh was even up — the classic
# fixed-sleep flake this harness exists to kill). Command list, in
# order:
#   * §6 tripwire: sample /dev/mountrpc BEFORE a local pipe.
#   * pipe: a | b carries data through a pipe Chan. The assertion is the
#     CONSUMER's computed answer (`seq 1000 1041 | wc -l` -> 42), not a
#     payload string: `echo PIPE_PAYLOAD | cat` used to "prove" the pipe,
#     but `echo` is a hamsh BUILTIN — when the builtin bypassed the pipe and
#     wrote to the console, the payload still appeared on serial and this
#     gate stayed green while pipelines were entirely broken. A count no
#     stage prints cannot be faked by a leak. See scripts/test_pipe.sh.
#   * a 3-stage pipeline still wires every /fd correctly (19 matches x 5
#     bytes = 95).
#   * §6 tripwire: sample mountrpc AFTER — a local pipe must NOT
#     marshal 9P, so the counter is unchanged.
#   * redirect: cmd > file binds a file Chan at /fd/1. echo is a hamsh
#     builtin (runs in-process), so redirect an EXTERNAL — the last
#     pipeline stage `cat` gets the `> file` bind.
#   * dup: cmd 2>&1 — /fd/2's Chan IS /fd/1's Chan.
set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 120 \
    -- 'echo MRPC_BEFORE `{ cat /dev/mountrpc }' 2 \
       'seq 1000 1041 | wc -l' 4 \
       'seq 1000 1099 | grep 7 | wc -c' 5 \
       'echo MRPC_AFTER `{ cat /dev/mountrpc }' 2 \
       'echo REDIR_CONTENT | cat > /tmp/fdbind_out' 3 \
       'cat /tmp/fdbind_out' 2 \
       'echo DUP_LINE 2>&1' 2 \
       'exit' 1
set -e

echo "[test_hamsh_fdbind] --- captured ---"
cat "$LOG"
echo "[test_hamsh_fdbind] --- end ---"

fail=0
# Assert on command OUTPUT only — hamsh's interactive line editor echoes
# typed input, so a plain `grep` of the log would also match the command
# being typed. hamsh_ran (scripts/_hamsh_log.sh) ignores the prompt-
# prefixed input-echo lines.
check() {
    if hamsh_ran "$LOG" "$1"; then
        echo "[test_hamsh_fdbind] OK: $2"
    else
        echo "[test_hamsh_fdbind] MISS: $2"
        fail=1
    fi
}

# pipe carries the payload — proves the pipe Chan binds at /fd/1 + /fd/0.
# EXACT-LINE match: a substring grep for "42" also matches the kernel's
# "[001042]" timestamps and the "[hamsh-alive] tick=42" heartbeat.
check_eq() {
    if hamsh_out_eq "$LOG" "$1"; then
        echo "[test_hamsh_fdbind] OK: $2"
    else
        echo "[test_hamsh_fdbind] MISS: $2"
        fail=1
    fi
}
check_absent() {
    if hamsh_out_eq "$LOG" "$1"; then
        echo "[test_hamsh_fdbind] MISS: $2"
        fail=1
    else
        echo "[test_hamsh_fdbind] OK: $2"
    fi
}
check_eq "42" "a | b — pipe Chan carries data (seq | wc -l = 42)"
check_absent "1000" "a | b — producer did NOT leak to the console"
check_eq "95" "3-stage pipeline wires every /fd (grep | wc -c = 95)"
check_absent "1007" "3-stage — no intermediate stage output on the console"
# redirect lands the bytes in the file via a file-Chan bind at /fd/1
check "REDIR_CONTENT"        "cmd > file — file Chan bound at /fd/1"
# dup-as-bind: 2>&1 reaches stdout
check "DUP_LINE"             "cmd 2>&1 — dup is a bind over channels"

# --- §6 CRITICAL: a local pipe does ZERO mountrpc -------------------
# The serial log prefixes each line with a [NNNNNN] timestamp, so the
# counter value is the field AFTER the MRPC_* label: pull the last
# whitespace-separated token on the COMMAND-OUTPUT line. _ho_outlines
# drops the prompt-prefixed input-echo line (whose last token would be
# the typed `}` plus the line editor's cursor-redraw escape).
before=$(_ho_outlines "$LOG" | grep -F "MRPC_BEFORE " | head -1 | awk '{print $NF}')
after=$(_ho_outlines "$LOG" | grep -F "MRPC_AFTER " | head -1 | awk '{print $NF}')
if [ -z "$before" ] || [ -z "$after" ]; then
    echo "[test_hamsh_fdbind] MISS: could not sample /dev/mountrpc counter"
    fail=1
elif [ "$before" = "$after" ]; then
    echo "[test_hamsh_fdbind] OK: local pipe did 0 mountrpc (before=$before after=$after)"
else
    echo "[test_hamsh_fdbind] FAIL: local pipe marshalled 9P (before=$before after=$after)"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_fdbind] FAIL"
    exit 1
fi
echo "[test_hamsh_fdbind] PASS"
