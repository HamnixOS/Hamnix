#!/usr/bin/env bash
# scripts/test_interactive_dash.sh -- REAL interactive dash repro for the
# `enter linux {sh}` crash.
#
# The synthetic fork+exec loop fixtures (test_interactive_forkexec) run
# clean, so the crash is specific to what REAL dash does in its
# interactive REPL (job-control process group, signal disposition, its
# particular fork+exec+wait sequence). This test embeds the HOST's real
# /bin/dash (the same binary that crashes in the user's repro — it uses
# the same /lib64/ld-linux-x86-64.so.2 + libc.so.6 we stage) and drives
# it interactively inside an `enter linux { ... }` clean namespace,
# feeding it commands that fork+exec a child (/bin/u_dynamic_hello).
#
# PASS: dash runs several forked commands with NO NX exec-fault / no
#       coredump / no SIGSEGV.
# FAIL signatures: "NX exec-fault", "capturing core", "code=139".

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

CHILD_UBIN=tests/u-binary/u_dynamic_hello
LDSO=tests/distros/debian-minbase/rootfs/lib64/ld-linux-x86-64.so.2
LIBC=tests/distros/debian-minbase/rootfs/usr/lib/x86_64-linux-gnu/libc.so.6
DASH_HOST=/bin/dash

if [ ! -e "$LDSO" ] || [ ! -f "$(readlink -f "$LDSO")" ]; then
    echo "[test_interactive_dash] SKIP: $LDSO not staged"
    exit 0
fi
if [ ! -e "$LIBC" ] || [ ! -f "$(readlink -f "$LIBC")" ]; then
    echo "[test_interactive_dash] SKIP: $LIBC not staged"
    exit 0
fi
if [ ! -x "$DASH_HOST" ]; then
    echo "[test_interactive_dash] SKIP: no host $DASH_HOST"
    exit 0
fi

echo "[test_interactive_dash] (1/5) Build child fixture"
make -C tests/u-binary/src/dynamic_hello install >/dev/null 2>&1 || true
if [ ! -f "$CHILD_UBIN" ]; then
    echo "[test_interactive_dash] SKIP: $CHILD_UBIN not built (no host gcc?)"
    exit 0
fi
echo "[test_interactive_dash]   child: $(file -b "$CHILD_UBIN")"
echo "[test_interactive_dash]   dash:  $(file -b "$DASH_HOST")"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_interactive_dash] (2/5) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

# Clean linux-shape namespace recipe (same as the apt e2e test).
RC_TMP=$(mktemp /tmp/hamsh-rc-idash.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
linux = ns clean {
    bind '#r/' /
    bind -bc '#t' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#t/tmp' /tmp
}
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[test_interactive_dash] (3/5) Embed dash + ld.so + libc + child in initramfs"
export HAMNIX_EMBED_UBIN=1
export HAMNIX_HAMSH_RC="$RC_TMP"
export INIT_ELF="$HAMSH_ELF"
python3 scripts/build_initramfs.py >/dev/null

LDSO_REAL=$(readlink -f "$LDSO")
LIBC_REAL=$(readlink -f "$LIBC")
DASH_REAL=$(readlink -f "$DASH_HOST")
python3 - "$LDSO_REAL" "$LIBC_REAL" "$DASH_REAL" <<'PYEOF'
import sys
import importlib.util
from pathlib import Path

here = Path.cwd()
spec = importlib.util.spec_from_file_location(
    "build_initramfs", here / "scripts" / "build_initramfs.py")
bi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bi)

archive = bi.build_archive()
trailer = bi.cpio_trailer()
assert archive.endswith(trailer), "archive shape changed; review me"
archive = archive[:-len(trailer)]

for vpath, host in (
        ("/lib64/ld-linux-x86-64.so.2", sys.argv[1]),
        ("/lib/x86_64-linux-gnu/libc.so.6", sys.argv[2]),
        ("/bin/dash", sys.argv[3])):
    data = Path(host).resolve().read_bytes()
    print(f"  injecting {vpath} ({len(data)} bytes)")
    archive += bi.cpio_entry(vpath, data)

archive += trailer
dest = here / "fs" / "initramfs_blob.S"
bi.emit_asm(archive, dest)
print(f"  rewrote {dest} (total {len(archive)} bytes)")
PYEOF

echo "[test_interactive_dash] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "[test_interactive_dash] (5/5) Boot QEMU (KVM) + drive interactive dash"
LOG=$(mktemp)
trap 'rm -f "$LOG" "$RC_TMP"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

export QEMU_EXTRA_ARGS="-enable-kvm -cpu host"

set +e
# enter the clean linux ns running real dash interactively, then type
# commands that fork+exec a child — exactly the user's `enter linux {sh}`
# then `ls` repro. Each /bin/u_dynamic_hello prints "U42 dynamic hello".
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 70 \
    -- "enter linux { /bin/dash }" 5 \
       "/bin/u_dynamic_hello" 5 \
       "/bin/u_dynamic_hello" 5 \
       "/bin/u_dynamic_hello" 5 \
       "echo DASH_STILL_ALIVE" 4 \
       "exit" 3 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_interactive_dash] --- captured output (last 250) ---"
tail -n 250 "$LOG" | strings
echo "[test_interactive_dash] --- end output ---"

fail=0
hits=$(grep -a -c -F "U42 dynamic hello" "$LOG" || true)
echo "[test_interactive_dash] forked-child 'U42 dynamic hello' count: $hits"
if [ "${hits:-0}" -lt 3 ]; then
    echo "[test_interactive_dash] FAIL: expected >=3 forked children to run"
    fail=1
fi
if ! grep -a -F -q "DASH_STILL_ALIVE" "$LOG"; then
    echo "[test_interactive_dash] FAIL: dash did not survive to echo DASH_STILL_ALIVE"
    fail=1
fi
if grep -a -E -q "NX exec-fault|capturing core|code=139" "$LOG"; then
    echo "[test_interactive_dash] FAIL: crash signature observed"
    grep -a -E "NX exec-fault|capturing core|code=139" "$LOG" | tail -10
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_interactive_dash] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_interactive_dash] PASS — real interactive dash forks commands without crashing"
exit 0
