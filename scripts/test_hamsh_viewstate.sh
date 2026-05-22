#!/usr/bin/env bash
# scripts/test_hamsh_viewstate.sh — HAMSH_SPEC §18 stage 9 acceptance.
#
# View vs state (§12). The namespace is the *view*; durable state
# lives in the file server behind it. `enter` / `spawn` instantiate a
# fresh, cheap COW copy of the *view* and discard it at the brace —
# but a file written through that view into a server-backed mount
# persists, because it lives in the SERVER, not the view.
#
# THE WIRING
# ----------
#   1. `distrofs post hamsh.dfs &`
#      Background-spawn the distrofs 9P file-server daemon in its new
#      `post` mode: it makes a bidirectional socketpair, publishes one
#      end on /srv/hamsh.dfs, and serves 9P over the other. The daemon
#      IS the persistent backing — its RAM tables live as long as the
#      daemon process, independent of any namespace view. (Across a
#      reboot the ext4 snapshot layer carries it — that is separately
#      proven by scripts/test_distrofs_persist.sh.)
#   2. `s = ns { mount /srv/hamsh.dfs /dfs }`
#      Capture a namespace TEMPLATE: a view that mounts the distrofs
#      daemon at /dfs. The template is configured, not entered.
#   3. `enter s { touch /dfs/x ; bind /tmp /dfs/transient }`
#      First entry: a fresh COW view applies the template, writes a
#      file THROUGH the view into the distrofs daemon's backing, and
#      also adds a TRANSIENT bind that belongs only to this view.
#   4. `enter s { cat /dfs/x ; cat /proc/self/ns }`
#      Second entry: a *different* fresh COW view re-applies the same
#      template. /dfs/x is THERE — the state persisted in the daemon.
#      The transient bind from entry #1 is GONE — the view was
#      discarded at the brace.
#
# ACCEPTANCE: /dfs/x visible on the re-enter (state durable), the
# transient bind absent (view ephemeral). That is §12 / §18.9.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamsh_viewstate] (1/3) Build userland (hamsh + distrofs)"
bash scripts/build_user.sh >/dev/null
if [ ! -x build/user/distrofs.elf ]; then
    echo "[test_hamsh_viewstate] FAIL: build/user/distrofs.elf missing"
    exit 1
fi

echo "[test_hamsh_viewstate] (2/3) Plant /init = hamsh, rebuild kernel"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_hamsh_viewstate] (3/3) Boot QEMU + drive the stage-9 scenario"
set +e
(
    sleep 3
    # 1) Background-spawn the distrofs daemon in post mode. It posts
    #    /srv/hamsh.dfs and serves 9P over its socketpair.
    printf 'distrofs post hamsh.dfs &\n'
    sleep 3
    # 2) Capture a namespace template that mounts the daemon at /dfs.
    printf 's = ns {\nmount /srv/hamsh.dfs /dfs\n}\n'
    sleep 2
    # 3) First entry: write a file through the view into the daemon,
    #    AND add a transient bind that belongs only to this view.
    printf 'enter s {\ntouch /dfs/stage9_marker\nbind /tmp /dfs/transient_bind\necho VS_WROTE\n}\n'
    sleep 4
    # 4) Second entry: a fresh view re-applies the template. The file
    #    must still be there (state in the daemon); the transient bind
    #    must be gone (view discarded).
    printf 'enter s {\ncat /dfs/stage9_marker\necho VS_REENTER_FILE_OK\n}\n'
    sleep 4
    # Show the re-entered view's namespace: /dfs is present (the
    # template re-applied), /dfs/transient_bind is NOT (it was the
    # previous view's transient bind, discarded at its brace).
    printf 'enter s {\necho VS_NS_DUMP_BEGIN\ncat /proc/self/ns\necho VS_NS_DUMP_END\n}\n'
    sleep 4
    printf 'exit\n'
    sleep 1
) | timeout 80s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 256M \
    -monitor none -serial stdio > "$LOG" 2>&1
set -e

echo "[test_hamsh_viewstate] --- captured ---"
cat "$LOG"
echo "[test_hamsh_viewstate] --- end ---"

fail=0
check() {
    if grep -F -q "$1" "$LOG"; then
        echo "[test_hamsh_viewstate] OK: $2"
    else
        echo "[test_hamsh_viewstate] MISS: $2"
        fail=1
    fi
}

# The daemon posted itself and serves.
check "[distrofs] posted to /srv, serving"  "distrofs post mode posted /srv/hamsh.dfs"
# First entry ran and wrote the marker file through the view.
check "VS_WROTE"               "first enter wrote a file through the distrofs-backed view"
# THE PROOF, half 1 — state is durable: the re-enter sees the file.
check "VS_REENTER_FILE_OK"     "re-enter ran"
if grep -F -q "VS_REENTER_FILE_OK" "$LOG"; then
    # cat must have succeeded — a failed cat prints to errstr, not the
    # echo. The echo follows cat on its own line; its presence plus no
    # "cat:" error line is the durable-state proof.
    if grep -E -q "cat: .*stage9_marker|stage9_marker.*not" "$LOG"; then
        echo "[test_hamsh_viewstate] FAIL: re-enter could not read the file — state NOT durable"
        fail=1
    else
        echo "[test_hamsh_viewstate] OK: file written in entry #1 is visible on re-enter (durable state)"
    fi
fi

# THE PROOF, half 2 — the view is ephemeral: the transient bind from
# entry #1 must NOT appear in entry #2's namespace dump.
if grep -F -q "VS_NS_DUMP_BEGIN" "$LOG" && \
        grep -F -q "VS_NS_DUMP_END" "$LOG"; then
    echo "[test_hamsh_viewstate] OK: re-entered view produced a /proc/self/ns dump"
    # Extract just the dump region and check the transient bind is absent.
    if sed -n '/VS_NS_DUMP_BEGIN/,/VS_NS_DUMP_END/p' "$LOG" \
            | grep -F -q "transient_bind"; then
        echo "[test_hamsh_viewstate] FAIL: transient bind LEAKED into the re-entered view"
        fail=1
    else
        echo "[test_hamsh_viewstate] OK: entry #1's transient bind is gone on re-enter (ephemeral view)"
    fi
else
    echo "[test_hamsh_viewstate] MISS: re-entered view namespace dump"
    fail=1
fi

# No CPU exception.
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_hamsh_viewstate] FAIL: kernel reported a CPU exception"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_viewstate] FAIL"
    exit 1
fi
echo "[test_hamsh_viewstate] PASS — a file written through one enter's" \
     "view into the distrofs-backed mount is durable on a later enter," \
     "while that view's transient binds are not (HAMSH_SPEC §18 stage 9)"
