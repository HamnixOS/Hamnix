#!/usr/bin/env bash
# scripts/test_interactive_forkexec.sh -- interactive multi-command
# fork+exec repro for the `enter linux {sh}` crash.
#
# The non-interactive dpkg path (test_dynamic_forkexec.sh) forks ONCE
# and works. The USER-REPORTED bug: an interactive Debian shell that
# fork+execs a child PER COMMAND in a loop crashes on the 2nd command
# with an NX exec-fault whose RIP resolves to a kernel high-half text
# VA (0xffffffff80xxxxxx) -> SIGSEGV + coredump. This test reproduces
# that with a long-lived dynamic-PIE parent (u_interactive_forkexec)
# that does NITERS=5 independent fork+execve(/bin/u_dynamic_hello)+reap
# cycles in a loop.
#
# PASS marker (greppable):  ITFE: all iters done
# FAIL signatures we explicitly catch:
#   NX exec-fault
#   capturing core
#   exited (code=139)

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_interactive_forkexec
CHILD_UBIN=tests/u-binary/u_dynamic_hello
LDSO=tests/distros/debian-minbase/rootfs/lib64/ld-linux-x86-64.so.2
LIBC=tests/distros/debian-minbase/rootfs/usr/lib/x86_64-linux-gnu/libc.so.6

if [ ! -e "$LDSO" ]; then
    echo "[test_interactive_forkexec] SKIP: $LDSO not staged"
    echo "    Build with: bash tests/distros/debian-minbase/BUILD.sh"
    exit 0
fi
if [ ! -f "$(readlink -f "$LDSO")" ]; then
    echo "[test_interactive_forkexec] SKIP: $LDSO does not resolve to a file"
    exit 0
fi
if [ ! -e "$LIBC" ] || [ ! -f "$(readlink -f "$LIBC")" ]; then
    echo "[test_interactive_forkexec] SKIP: $LIBC not staged or unresolved"
    exit 0
fi

echo "[test_interactive_forkexec] (1/5) Build fixtures"
make -C tests/u-binary/src/interactive_forkexec install >/dev/null 2>&1 || true
if [ ! -f "$UBIN" ]; then
    echo "[test_interactive_forkexec] SKIP: $UBIN not built (no host gcc?)"
    exit 0
fi
echo "[test_interactive_forkexec]   parent: $(file -b "$UBIN")"
make -C tests/u-binary/src/dynamic_hello install >/dev/null 2>&1 || true
if [ ! -f "$CHILD_UBIN" ]; then
    echo "[test_interactive_forkexec] SKIP: $CHILD_UBIN not built (no host gcc?)"
    exit 0
fi
echo "[test_interactive_forkexec]   child:  $(file -b "$CHILD_UBIN")"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_interactive_forkexec] (2/5) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

# Plant an /etc/hamsh.rc that defines a CLEAN `linux`-shape namespace,
# exactly like test_linux_apt_install_e2e.sh: bind the cpio root (#r/)
# as the read base + a writable tmpfs overlay (#t) on top, plus the
# device/proc servers. This makes the repro run the fixture INSIDE an
# `enter linux { ... }` rfork'd namespace child — the real `enter linux
# {sh}` path — rather than directly under hamsh's native root. The
# grandchild fork (the fixture forking a child per command) then happens
# from a task that is itself an rfork'd+execve'd namespace child, which
# is the configuration the user's crash reproduces in.
RC_TMP=$(mktemp /tmp/hamsh-rc-itfe.XXXXXX.rc)
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

echo "[test_interactive_forkexec] (3/5) Embed ld.so + libc + fixtures in initramfs"
HAMNIX_EMBED_UBIN=1 HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LDSO_REAL=$(readlink -f "$LDSO")
LIBC_REAL=$(readlink -f "$LIBC")
# The splice below re-runs build_archive(), which must see the SAME
# HAMNIX_HAMSH_RC / embed env so the re-emitted cpio still carries the
# /etc/hamsh.rc namespace recipe and the embedded ubins.
export HAMNIX_EMBED_UBIN=1
export HAMNIX_HAMSH_RC="$RC_TMP"
export INIT_ELF="$HAMSH_ELF"
python3 - "$LDSO_REAL" "$LIBC_REAL" <<'PYEOF'
import sys
import importlib.util
from pathlib import Path

here = Path.cwd()
spec = importlib.util.spec_from_file_location(
    "build_initramfs", here / "scripts" / "build_initramfs.py")
bi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bi)

import os
os.environ.setdefault("HAMNIX_EMBED_UBIN", "1")
os.environ.setdefault("INIT_ELF", "build/user/hamsh.elf")
archive = bi.build_archive()
trailer = bi.cpio_trailer()
assert archive.endswith(trailer), "archive shape changed; review me"
archive = archive[:-len(trailer)]

ldso_path = Path(sys.argv[1]).resolve()
ldso_data = ldso_path.read_bytes()
print(f"  injecting /lib64/ld-linux-x86-64.so.2 ({len(ldso_data)} bytes)")
archive += bi.cpio_entry("/lib64/ld-linux-x86-64.so.2", ldso_data)

libc_path = Path(sys.argv[2]).resolve()
libc_data = libc_path.read_bytes()
print(f"  injecting /lib/x86_64-linux-gnu/libc.so.6 ({len(libc_data)} bytes)")
archive += bi.cpio_entry("/lib/x86_64-linux-gnu/libc.so.6", libc_data)

archive += trailer
dest = here / "fs" / "initramfs_blob.S"
bi.emit_asm(archive, dest)
print(f"  rewrote {dest} (total {len(archive)} bytes)")
PYEOF

echo "[test_interactive_forkexec] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_interactive_forkexec] (5/5) Boot QEMU (KVM) + drive u_interactive_forkexec"
LOG=$(mktemp)
trap 'rm -f "$LOG" "$RC_TMP"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Boot under KVM, mirroring the user's repro environment.
export QEMU_EXTRA_ARGS="-enable-kvm -cpu host"

set +e
# Drive: launch the long-lived fixture, then feed it several command
# lines over the serial console (each triggers a fork+exec+reap), with
# pauses between so each blocking fgets read completes BEFORE the next
# line — exactly the interactive `enter linux {sh}` typing cadence. The
# fixture's child inherits DEVFD_CONS as stdin, so these lines reach it.
# Launch the fixture INSIDE the clean `linux` namespace via `enter`,
# then feed command lines over serial. This is the `enter linux {sh}`
# shape: a long-lived dynamic binary in an rfork'd+namespace'd task,
# reading the console and fork+exec'ing a child per command.
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 60 \
    -- "enter linux { /bin/u_interactive_forkexec }" 4 \
       "ls" 4 \
       "echo" 4 \
       "cat" 4 \
       "pwd" 4 \
       "quit" 4 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_interactive_forkexec] --- captured output (last 250 lines) ---"
tail -n 250 "$LOG"
echo "[test_interactive_forkexec] --- end output ---"

fail=0

if grep -a -F -q "ITFE: all iters done" "$LOG"; then
    echo "[test_interactive_forkexec] OK: all fork+exec iterations completed"
else
    echo "[test_interactive_forkexec] FAIL: 'ITFE: all iters done' not reached"
    fail=1
fi

# Crash signatures: any of these means the interactive shell bug reproduced.
if grep -a -E -q "NX exec-fault|capturing core|exited \(code=139\)" "$LOG"; then
    echo "[test_interactive_forkexec] FAIL: crash signature observed" \
         "(NX exec-fault / coredump / SIGSEGV)"
    grep -a -E "NX exec-fault|capturing core|exited \(code=139\)|ITFE:" "$LOG" | tail -20
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_interactive_forkexec] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_interactive_forkexec] PASS — interactive multi-fork+exec stable"
exit 0
