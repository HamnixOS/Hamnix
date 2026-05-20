#!/usr/bin/env bash
# scripts/test_dpkg_db.sh — apt-path V1 regression: the dpkg package
# database. Companion to test_dpkg_deb_x.sh / test_dpkg_deb_info.sh;
# same fixture-generation shape (host ar + tar + gzip), separate QEMU
# boot.
#
# Builds the `dpkg` userland binary, fabricates a tiny .deb fixture on
# the host whose `control` carries the standard fields INCLUDING a
# multi-line Description (continuation lines starting with a space),
# plants it at /tests/sample.deb in the cpio initramfs, boots QEMU +
# hamsh, and drives:
#
#     /bin/dpkg -i /tests/sample.deb
#     cat /tmp/dpkg-status
#     cat /tmp/dpkg.hamnix-fixture.list
#     /bin/dpkg -l                  query: list installed packages
#     /bin/dpkg -s <pkg>            query: show one package's stanza
#     /bin/dpkg -L <pkg>            query: list one package's files
#     /bin/dpkg -s nonexistent-pkg  query: error path (not installed)
#
# Asserts:
#   * the summary line `dpkg: registered <pkg> <ver> (<N> files)`;
#   * the status DB stanza fields (Package/Status/Version/
#     Architecture/Maintainer/Description) AND the Description
#     continuation line are present;
#   * the per-package .list manifest contains the data.tar entry paths;
#   * `dpkg -l` lists the installed package with the `ii` prefix;
#   * `dpkg -s <pkg>` prints the package's status stanza fields;
#   * `dpkg -L <pkg>` prints the package's installed-file manifest;
#   * `dpkg -s nonexistent-pkg` emits the dpkg-query "is not installed"
#     diagnostic to stderr.
#
# DB-PATH NOTE: Hamnix tmpfs is a flat namespace (no directories)
# capped at TMPFS_NAME_LEN=32 bytes/name, and the cpio `/var` is
# read-only — so the canonical /var/lib/dpkg/{status,info/<pkg>.list}
# cannot be created. dpkg V1 writes flattened tmpfs names instead:
#       /tmp/dpkg-status
#       /tmp/dpkg.<pkg>.list   (pkg truncated to 16 chars for the name)
# V2 restores the canonical paths once tmpfs grows real nested dirs.
# The fixture package name (PKG_NAME) is kept <=16 chars so the .list
# filename is exact, not truncated.
#
# Shape mirrors scripts/test_dpkg_deb_x.sh: build user + modules +
# kernel, plant fixture, boot, grep serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

# Fixture package identity. PKG_NAME must be <=16 chars (the tmpfs
# name budget for /tmp/dpkg.<pkg>.list) so the manifest path is exact.
PKG_NAME='hamnix-fixture'
PKG_VERSION='1.2.3'
PKG_ARCH='amd64'
PKG_MAINT='Hamnix Tests <noreply@hamnix.local>'
DESC_FIRST='DPKGDB_OK V1 database fixture'
DESC_CONT_MARKER='DPKGDB_CONT continuation line ok'
LIST_PATH="/tmp/dpkg.${PKG_NAME}.list"
DATA_ENTRY_A='./usr/bin/hamfix'
DATA_ENTRY_B='./usr/share/doc/hamfix/readme'
# A package name that is NOT in the DB — drives the `-s` error path.
MISSING_PKG='nonexistent-pkg'

echo "[test_dpkg_db] (1/6) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

if [ ! -x "build/user/dpkg.elf" ]; then
    echo "[test_dpkg_db] FAIL: build/user/dpkg.elf missing after build_user.sh"
    exit 1
fi

echo "[test_dpkg_db] (2/6) Fabricate sample.deb via host ar+tar+gzip"
FIXTURE_DIR=$(mktemp -d --tmpdir hamnix-dpkgdb-fixture.XXXXXX)
cleanup_fixture() { rm -rf "$FIXTURE_DIR"; }

stage="$FIXTURE_DIR/stage"
mkdir -p "$stage"
printf '2.0\n' > "$stage/debian-binary"

# control.tar.gz: a `control` file with the standard fields. The
# Description deliberately has TWO continuation lines (each beginning
# with a space) so the V1 multi-line folding path is exercised.
ctl_dir="$FIXTURE_DIR/ctl"
mkdir -p "$ctl_dir"
cat > "$ctl_dir/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION
Section: misc
Priority: optional
Architecture: $PKG_ARCH
Maintainer: $PKG_MAINT
Description: $DESC_FIRST
 $DESC_CONT_MARKER
 second continuation paragraph line.
EOF
tar -C "$ctl_dir" -czf "$stage/control.tar.gz" ./control

# data.tar.gz: a couple of nested paths so the .list manifest has
# something interesting to record. Content is irrelevant for V1 (the
# DB records metadata only; extraction is dpkg-deb -x).
data_dir="$FIXTURE_DIR/data"
mkdir -p "$data_dir/usr/bin" "$data_dir/usr/share/doc/hamfix"
printf 'binary\n' > "$data_dir/usr/bin/hamfix"
printf 'readme\n'  > "$data_dir/usr/share/doc/hamfix/readme"
tar -C "$data_dir" -czf "$stage/data.tar.gz" ./usr/bin/hamfix ./usr/share/doc/hamfix/readme

# Glue the three members in canonical order via ar(1).
DEB_PATH="$FIXTURE_DIR/sample.deb"
( cd "$stage" && ar rc "$DEB_PATH" debian-binary control.tar.gz data.tar.gz )

echo "[test_dpkg_db]   fixture: $DEB_PATH ($(stat -c%s "$DEB_PATH") bytes)"

echo "[test_dpkg_db] (3/6) Plant /init = hamsh + /tests/sample.deb in cpio"
INIT_ELF="$HAMSH_ELF" HAMNIX_DEB_FIXTURE="$DEB_PATH" \
    python3 scripts/build_initramfs.py >/dev/null

# Restore the canonical initramfs on exit so other tests in this
# worktree see a clean state.
trap 'cleanup_fixture; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_dpkg_db] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_dpkg_db] (5/6) Boot QEMU + drive /bin/dpkg via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; cleanup_fixture; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/dpkg -i /tests/sample.deb\n'
    sleep 3
    printf 'cat /tmp/dpkg-status\n'
    sleep 2
    printf 'cat %s\n' "$LIST_PATH"
    sleep 2
    # Query sub-commands: read back the DB the install above populated.
    printf 'echo DPKG_QUERY_L_START\n'
    printf '/bin/dpkg -l\n'
    sleep 2
    printf 'echo DPKG_QUERY_S_START\n'
    printf '/bin/dpkg -s %s\n' "$PKG_NAME"
    sleep 2
    printf 'echo DPKG_QUERY_BIGL_START\n'
    printf '/bin/dpkg -L %s\n' "$PKG_NAME"
    sleep 2
    printf 'echo DPKG_QUERY_MISS_START\n'
    printf '/bin/dpkg -s %s\n' "$MISSING_PKG"
    sleep 2
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
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

echo "[test_dpkg_db] --- captured output ---"
cat "$LOG"
echo "[test_dpkg_db] --- end output ---"

fail=0

# (a) Summary line printed by dpkg -i. The fixture data.tar has 2
# regular files plus 4 directory entries (usr, usr/bin, usr/share,
# usr/share/doc, usr/share/doc/hamfix) depending on how host tar emits
# them — assert the prefix + version rather than a brittle exact count.
if grep -F -q "dpkg: registered $PKG_NAME $PKG_VERSION (" "$LOG"; then
    echo "[test_dpkg_db] OK: summary line printed"
else
    echo "[test_dpkg_db] MISS: 'dpkg: registered $PKG_NAME $PKG_VERSION (...)' absent"
    fail=1
fi

# (b) Status DB stanza fields.
if grep -F -q "Package: $PKG_NAME" "$LOG"; then
    echo "[test_dpkg_db] OK: stanza Package field"
else
    echo "[test_dpkg_db] MISS: stanza Package field absent"
    fail=1
fi
if grep -F -q "Status: install ok installed" "$LOG"; then
    echo "[test_dpkg_db] OK: stanza Status field"
else
    echo "[test_dpkg_db] MISS: stanza Status field absent"
    fail=1
fi
if grep -F -q "Version: $PKG_VERSION" "$LOG"; then
    echo "[test_dpkg_db] OK: stanza Version field"
else
    echo "[test_dpkg_db] MISS: stanza Version field absent"
    fail=1
fi
if grep -F -q "Architecture: $PKG_ARCH" "$LOG"; then
    echo "[test_dpkg_db] OK: stanza Architecture field"
else
    echo "[test_dpkg_db] MISS: stanza Architecture field absent"
    fail=1
fi
if grep -F -q "Maintainer: $PKG_MAINT" "$LOG"; then
    echo "[test_dpkg_db] OK: stanza Maintainer field"
else
    echo "[test_dpkg_db] MISS: stanza Maintainer field absent"
    fail=1
fi
if grep -F -q "Description: $DESC_FIRST" "$LOG"; then
    echo "[test_dpkg_db] OK: stanza Description first line"
else
    echo "[test_dpkg_db] MISS: stanza Description first line absent"
    fail=1
fi
# (c) Multi-line Description folding — the continuation line must be
# present (it begins with a space in the wire format).
if grep -F -q "$DESC_CONT_MARKER" "$LOG"; then
    echo "[test_dpkg_db] OK: Description continuation line folded in"
else
    echo "[test_dpkg_db] MISS: Description continuation line absent"
    fail=1
fi

# (d) Per-package .list manifest entries.
if grep -F -q "$DATA_ENTRY_A" "$LOG"; then
    echo "[test_dpkg_db] OK: .list has data entry $DATA_ENTRY_A"
else
    echo "[test_dpkg_db] MISS: .list missing $DATA_ENTRY_A"
    fail=1
fi
if grep -F -q "$DATA_ENTRY_B" "$LOG"; then
    echo "[test_dpkg_db] OK: .list has data entry $DATA_ENTRY_B"
else
    echo "[test_dpkg_db] MISS: .list missing $DATA_ENTRY_B"
    fail=1
fi

# (e) dpkg itself must not emit an error line. Error paths all start
# with "dpkg: " followed by a known failure shape. The summary line
# also starts with "dpkg: registered" — exclude it.
if grep -E -q "dpkg: (not an ar|ar header|gzip inflate|cannot open|control file not found|control file has no|tar header checksum|short write|unsupported compression|status DB would exceed|no matching)" "$LOG"; then
    echo "[test_dpkg_db] MISS: dpkg emitted an error line:"
    grep -E "dpkg: (not an ar|ar header|gzip inflate|cannot open|control file not found|control file has no|tar header checksum|short write|unsupported compression|status DB would exceed|no matching)" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_dpkg_db] OK: no dpkg error lines"
fi

# (f) cat must not report 'cannot open' for either DB file.
if grep -F -q "cat: cannot open /tmp/dpkg-status" "$LOG"; then
    echo "[test_dpkg_db] MISS: status DB file never created"
    fail=1
fi
if grep -F -q "cat: cannot open $LIST_PATH" "$LOG"; then
    echo "[test_dpkg_db] MISS: .list file never created"
    fail=1
fi

# (g) `dpkg -l` lists the installed package. The row carries the real
# dpkg `ii` desired/status prefix followed by the package name. The
# serial log prefixes each line with "[NNNNNN] ", so the `ii` token is
# matched anywhere on the line rather than anchored at column 0.
if grep -E -q "(^|\] )ii  +$PKG_NAME " "$LOG"; then
    echo "[test_dpkg_db] OK: dpkg -l listed $PKG_NAME with ii prefix"
else
    echo "[test_dpkg_db] MISS: dpkg -l did not list $PKG_NAME (ii row absent)"
    fail=1
fi

# (h) `dpkg -s <pkg>` prints the package's status stanza. The stanza
# output lands in the window between the -s and -L echo markers; we
# slice that window and confirm the Package + Status lines are inside
# it (the Status line is unique to the status DB stanza, so this is a
# genuine read-back via -s, not an echo of the -i parse).
S_WINDOW=$(sed -n '/DPKG_QUERY_S_START/,/DPKG_QUERY_BIGL_START/p' "$LOG")
if echo "$S_WINDOW" | grep -F -q "Package: $PKG_NAME" \
   && echo "$S_WINDOW" | grep -F -q "Status: install ok installed"; then
    echo "[test_dpkg_db] OK: dpkg -s printed the $PKG_NAME stanza"
else
    echo "[test_dpkg_db] MISS: dpkg -s did not print the $PKG_NAME stanza"
    fail=1
fi

# (i) `dpkg -L <pkg>` prints the per-package file manifest. Slice the
# window after the -L marker and confirm a known data.tar entry path
# appears there (so we know it came from -L, not the earlier `cat`).
L_WINDOW=$(sed -n '/DPKG_QUERY_BIGL_START/,/DPKG_QUERY_MISS_START/p' "$LOG")
if echo "$L_WINDOW" | grep -F -q "$DATA_ENTRY_A"; then
    echo "[test_dpkg_db] OK: dpkg -L printed the $PKG_NAME file manifest"
else
    echo "[test_dpkg_db] MISS: dpkg -L did not print the file manifest"
    fail=1
fi

# (j) `dpkg -s <missing>` errors with the dpkg-query diagnostic.
if grep -F -q "dpkg-query: package '$MISSING_PKG' is not installed" "$LOG"; then
    echo "[test_dpkg_db] OK: dpkg -s on a missing package errors correctly"
else
    echo "[test_dpkg_db] MISS: dpkg -s on a missing package did not error"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_dpkg_db] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_dpkg_db] (6/6) PASS"
echo "[test_dpkg_db] PASS"
