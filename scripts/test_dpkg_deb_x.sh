#!/usr/bin/env bash
# scripts/test_dpkg_deb_x.sh — V0 apt-path regression.
#
# Builds the dpkg_deb userland binary, fabricates a tiny .deb fixture
# on the host (ar archive containing debian-binary, control.tar.gz,
# data.tar.gz), plants the fixture in the cpio initramfs at
# /tests/sample.deb, boots QEMU + hamsh, and drives:
#
#     /bin/dpkg_deb -x /tests/sample.deb /tmp/extracted
#     cat /tmp/extracted/hello.txt
#
# Asserts the cat output matches the known-byte payload, proving the
# end-to-end ar walk + gzip inflate + ustar extract pipeline.
#
# Shape mirrors scripts/test_inflate.sh (build user + tests + kernel,
# plant fixture, boot, grep serial log).
#
# Path-shape constraints to keep tmpfs happy:
#   - tmpfs caps file names at 32 chars (TMPFS_NAME_LEN) and per-file
#     data at 4096 bytes (TMPFS_FILE_CAP). Our fixture's data.tar
#     entry is `./hello.txt` → /tmp/extracted/hello.txt (24 chars,
#     well under the cap), payload is ~30 bytes.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

# Known-byte payload extracted dpkg_deb is expected to write back out
# under /tmp/extracted/hello.txt. Includes a marker token the test
# greps on (with-spaces). The trailing newline keeps the byte count
# stable across editors.
FIXTURE_PAYLOAD='DPKGDEB_FIXTURE_OK hello from a deb
'
FIXTURE_MARKER='DPKGDEB_FIXTURE_OK hello from a deb'

echo "[test_dpkg_deb_x] (1/6) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

if [ ! -x "build/user/dpkg_deb.elf" ]; then
    echo "[test_dpkg_deb_x] FAIL: build/user/dpkg_deb.elf missing after build_user.sh"
    exit 1
fi

echo "[test_dpkg_deb_x] (2/6) Fabricate sample.deb via host ar+tar+gzip"
FIXTURE_DIR=$(mktemp -d --tmpdir hamnix-deb-fixture.XXXXXX)
cleanup_fixture() { rm -rf "$FIXTURE_DIR"; }

stage="$FIXTURE_DIR/stage"
mkdir -p "$stage"
printf '2.0\n' > "$stage/debian-binary"

# control.tar.gz: minimal — just a `control` file with the standard
# Debian fields. The V0 dpkg-deb skips control entirely (only data.tar
# is extracted), but the ar archive must still contain it in canonical
# order or downstream apt tooling would reject the package.
ctl_dir="$FIXTURE_DIR/ctl"
mkdir -p "$ctl_dir"
cat > "$ctl_dir/control" <<'EOF'
Package: hamnix-dpkg-deb-fixture
Version: 0.0.1
Section: misc
Priority: optional
Architecture: all
Maintainer: Hamnix Tests <noreply@hamnix.local>
Description: V0 dpkg-deb -x fixture
 Single-file package used by scripts/test_dpkg_deb_x.sh to verify the
 Hamnix userland dpkg-deb extracts data.tar.gz members under QEMU.
EOF
tar -C "$ctl_dir" -czf "$stage/control.tar.gz" ./control

# data.tar.gz: a single `./hello.txt` carrying the known payload. The
# `./` prefix is the Debian convention (dpkg_deb's _strip_dot_slash
# handles it).
data_dir="$FIXTURE_DIR/data"
mkdir -p "$data_dir"
printf '%s' "$FIXTURE_PAYLOAD" > "$data_dir/hello.txt"
tar -C "$data_dir" -czf "$stage/data.tar.gz" ./hello.txt

# Glue the three members in canonical order via ar(1).
DEB_PATH="$FIXTURE_DIR/sample.deb"
( cd "$stage" && ar rc "$DEB_PATH" debian-binary control.tar.gz data.tar.gz )

echo "[test_dpkg_deb_x]   fixture: $DEB_PATH ($(stat -c%s "$DEB_PATH") bytes)"

echo "[test_dpkg_deb_x] (3/6) Plant /init = hamsh + /tests/sample.deb in cpio"
INIT_ELF="$HAMSH_ELF" HAMNIX_DEB_FIXTURE="$DEB_PATH" \
    python3 scripts/build_initramfs.py >/dev/null

# Restore the canonical initramfs (init=user/init.elf, no fixture) on
# exit so subsequent tests in the same worktree see a clean state.
trap 'cleanup_fixture; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_dpkg_deb_x] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_dpkg_deb_x] (5/6) Boot QEMU + drive /bin/dpkg_deb via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; cleanup_fixture; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/dpkg_deb -x /tests/sample.deb /tmp/extracted\n'
    sleep 3
    printf 'cat /tmp/extracted/hello.txt\n'
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
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

echo "[test_dpkg_deb_x] --- captured output ---"
cat "$LOG"
echo "[test_dpkg_deb_x] --- end output ---"

fail=0

# Pre-checks: dpkg_deb itself shouldn't print any error line. The
# error path always starts with "dpkg-deb:" (see write_str(2, ...)).
if grep -F -q "dpkg-deb:" "$LOG"; then
    echo "[test_dpkg_deb_x] MISS: dpkg-deb emitted an error line:"
    grep -F "dpkg-deb:" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_dpkg_deb_x] OK: no dpkg-deb error lines"
fi

# Primary signal: cat output of the extracted file matches the known
# fixture marker.
if grep -F -q "$FIXTURE_MARKER" "$LOG"; then
    echo "[test_dpkg_deb_x] OK: extracted /tmp/extracted/hello.txt contents match"
else
    echo "[test_dpkg_deb_x] MISS: fixture marker (\"$FIXTURE_MARKER\") absent"
    fail=1
fi

# Belt-and-braces: cat must NOT report "cannot open" — that's the
# failure shape when dpkg_deb fell over silently and the extracted
# file never appeared.
if grep -F -q "cat: cannot open /tmp/extracted/hello.txt" "$LOG"; then
    echo "[test_dpkg_deb_x] MISS: cat could not open extracted file"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_dpkg_deb_x] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_dpkg_deb_x] (6/6) PASS"
echo "[test_dpkg_deb_x] PASS"
