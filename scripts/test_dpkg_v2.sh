#!/usr/bin/env bash
# scripts/test_dpkg_v2.sh — apt-path V2 regression: the two dpkg
# correctness features layered on top of test_dpkg_db.sh's V1 coverage.
#
#   1. Dedup/replace on `dpkg -i`: installing the SAME package twice
#      must leave EXACTLY ONE stanza in the status DB (the re-install
#      replaces the old stanza in place — no stale duplicate appended).
#   2. `dpkg -r <pkg>` (remove): deregisters a package — removes its
#      stanza from the status DB and deletes its .list manifest. After
#      a remove, `dpkg -l` no longer lists it and `dpkg -s` errors.
#      A `dpkg -r` on a not-installed package errors cleanly.
#
# Same fixture-generation shape as test_dpkg_db.sh (host ar + tar +
# gzip), separate QEMU boot. Drives, in one hamsh session:
#
#     /bin/dpkg -i /tests/sample.deb        first install
#     /bin/dpkg -i /tests/sample.deb        re-install (dedup path)
#     /bin/dpkg -l                          must list the pkg ONCE
#     /bin/dpkg -r <pkg>                    remove (deregister)
#     /bin/dpkg -l                          must NOT list the pkg
#     /bin/dpkg -s <pkg>                    must error (not installed)
#     /bin/dpkg -r <pkg>                    re-remove: must error
#     /bin/dpkg -r ghost-pkg                remove a never-installed pkg
#
# DB-PATH NOTE: dpkg V2 keeps the V1 flattened tmpfs DB paths
# (/tmp/dpkg-status, /tmp/dpkg.<pkg>.list) — the canonical
# /var/lib/dpkg/{status,info/<pkg>.list} migration is deferred to V3.
# PKG_NAME stays <=16 chars so the .list filename is exact.
#
# Shape mirrors scripts/test_dpkg_db.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# Fixture package identity. PKG_NAME must be <=16 chars.
PKG_NAME='hamnix-fixture'
PKG_VERSION='1.2.3'
PKG_ARCH='amd64'
PKG_MAINT='Hamnix Tests <noreply@hamnix.local>'
DESC_FIRST='DPKGV2_OK V2 dedup/remove fixture'
LIST_PATH="/tmp/dpkg.${PKG_NAME}.list"
DATA_ENTRY_A='./usr/bin/hamfix'
# A package name that is NOT in the DB — drives the `-r` error path.
GHOST_PKG='ghost-pkg'

echo "[test_dpkg_v2] (1/6) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

if [ ! -x "build/user/dpkg.elf" ]; then
    echo "[test_dpkg_v2] FAIL: build/user/dpkg.elf missing after build_user.sh"
    exit 1
fi

echo "[test_dpkg_v2] (2/6) Fabricate sample.deb via host ar+tar+gzip"
FIXTURE_DIR=$(mktemp -d --tmpdir hamnix-dpkgv2-fixture.XXXXXX)
cleanup_fixture() { rm -rf "$FIXTURE_DIR"; }

stage="$FIXTURE_DIR/stage"
mkdir -p "$stage"
printf '2.0\n' > "$stage/debian-binary"

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
 continuation line ok.
EOF
tar -C "$ctl_dir" -czf "$stage/control.tar.gz" ./control

data_dir="$FIXTURE_DIR/data"
mkdir -p "$data_dir/usr/bin"
printf 'binary\n' > "$data_dir/usr/bin/hamfix"
tar -C "$data_dir" -czf "$stage/data.tar.gz" ./usr/bin/hamfix

DEB_PATH="$FIXTURE_DIR/sample.deb"
( cd "$stage" && ar rc "$DEB_PATH" debian-binary control.tar.gz data.tar.gz )

echo "[test_dpkg_v2]   fixture: $DEB_PATH ($(stat -c%s "$DEB_PATH") bytes)"

echo "[test_dpkg_v2] (3/6) Plant /init = hamsh + /tests/sample.deb in cpio"
INIT_ELF="$HAMSH_ELF" HAMNIX_DEB_FIXTURE="$DEB_PATH" \
    python3 scripts/build_initramfs.py >/dev/null

trap 'cleanup_fixture; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_dpkg_v2] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_dpkg_v2] (5/6) Boot QEMU + drive /bin/dpkg via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; cleanup_fixture; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # Install the SAME .deb twice — the second install must REPLACE the
    # first stanza, not append a duplicate.
    printf '/bin/dpkg -i /tests/sample.deb\n'
    sleep 3
    printf '/bin/dpkg -i /tests/sample.deb\n'
    sleep 3
    # After the double install: dpkg -l must show the package once.
    printf 'echo DPKGV2_L1_START\n'
    printf '/bin/dpkg -l\n'
    sleep 2
    printf 'echo DPKGV2_L1_END\n'
    sleep 1
    # Remove the package.
    printf 'echo DPKGV2_RM_START\n'
    printf '/bin/dpkg -r %s\n' "$PKG_NAME"
    sleep 2
    printf 'echo DPKGV2_RM_END\n'
    sleep 1
    # After remove: dpkg -l must NOT list it.
    printf 'echo DPKGV2_L2_START\n'
    printf '/bin/dpkg -l\n'
    sleep 2
    printf 'echo DPKGV2_L2_END\n'
    sleep 1
    # After remove: dpkg -s must error (not installed).
    printf 'echo DPKGV2_S_START\n'
    printf '/bin/dpkg -s %s\n' "$PKG_NAME"
    sleep 2
    printf 'echo DPKGV2_S_END\n'
    sleep 1
    # Removing the already-removed package again must error cleanly.
    printf 'echo DPKGV2_RM2_START\n'
    printf '/bin/dpkg -r %s\n' "$PKG_NAME"
    sleep 2
    printf 'echo DPKGV2_RM2_END\n'
    sleep 1
    # Removing a never-installed package must error cleanly.
    printf 'echo DPKGV2_GHOST_START\n'
    printf '/bin/dpkg -r %s\n' "$GHOST_PKG"
    sleep 2
    printf 'echo DPKGV2_GHOST_END\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 60s qemu-system-x86_64 \
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

echo "[test_dpkg_v2] --- captured output ---"
cat "$LOG"
echo "[test_dpkg_v2] --- end output ---"

fail=0

# (a) Both installs succeeded — the summary line appears at least once
# (it should appear twice; the install is idempotent on re-run).
INSTALL_COUNT=$(grep -F -c "dpkg: registered $PKG_NAME $PKG_VERSION (" "$LOG" || true)
if [ "$INSTALL_COUNT" -ge 2 ]; then
    echo "[test_dpkg_v2] OK: dpkg -i succeeded on both install + re-install"
else
    echo "[test_dpkg_v2] MISS: dpkg -i did not register $PKG_NAME twice (count=$INSTALL_COUNT)"
    fail=1
fi

# (b) DEDUP: after installing the SAME package twice, `dpkg -l` must
# list it EXACTLY ONCE. The serial log prefixes each line with
# "[NNNNNN] "; the `ii` row carries the package name. Slice the first
# -l window and count the rows.
L1_WINDOW=$(sed -n '/DPKGV2_L1_START/,/DPKGV2_L1_END/p' "$LOG")
L1_COUNT=$(echo "$L1_WINDOW" | grep -E -c "(^|\] )ii  +$PKG_NAME " || true)
if [ "$L1_COUNT" -eq 1 ]; then
    echo "[test_dpkg_v2] OK: dpkg -l lists $PKG_NAME exactly once after double install (dedup works)"
elif [ "$L1_COUNT" -eq 0 ]; then
    echo "[test_dpkg_v2] MISS: dpkg -l did not list $PKG_NAME at all after install"
    fail=1
else
    echo "[test_dpkg_v2] MISS: dpkg -l listed $PKG_NAME $L1_COUNT times (dedup FAILED — duplicate stanza)"
    fail=1
fi

# (c) REMOVE: `dpkg -r` prints the removal confirmation.
RM_WINDOW=$(sed -n '/DPKGV2_RM_START/,/DPKGV2_RM_END/p' "$LOG")
if echo "$RM_WINDOW" | grep -F -q "dpkg: removed $PKG_NAME"; then
    echo "[test_dpkg_v2] OK: dpkg -r printed 'dpkg: removed $PKG_NAME'"
else
    echo "[test_dpkg_v2] MISS: dpkg -r did not print the removal confirmation"
    fail=1
fi

# (d) After remove, `dpkg -l` must NOT list the package any more.
L2_WINDOW=$(sed -n '/DPKGV2_L2_START/,/DPKGV2_L2_END/p' "$LOG")
L2_COUNT=$(echo "$L2_WINDOW" | grep -E -c "(^|\] )ii  +$PKG_NAME " || true)
if [ "$L2_COUNT" -eq 0 ]; then
    echo "[test_dpkg_v2] OK: dpkg -l no longer lists $PKG_NAME after remove"
else
    echo "[test_dpkg_v2] MISS: dpkg -l still lists $PKG_NAME after remove (count=$L2_COUNT)"
    fail=1
fi

# (e) After remove, `dpkg -s` must error with the not-installed
# diagnostic.
S_WINDOW=$(sed -n '/DPKGV2_S_START/,/DPKGV2_S_END/p' "$LOG")
if echo "$S_WINDOW" | grep -F -q "package '$PKG_NAME' is not installed"; then
    echo "[test_dpkg_v2] OK: dpkg -s errors 'not installed' after remove"
else
    echo "[test_dpkg_v2] MISS: dpkg -s did not error after remove"
    fail=1
fi

# (f) Removing the already-removed package again must error cleanly
# with the dpkg remove diagnostic.
RM2_WINDOW=$(sed -n '/DPKGV2_RM2_START/,/DPKGV2_RM2_END/p' "$LOG")
if echo "$RM2_WINDOW" | grep -F -q "dpkg: package '$PKG_NAME' is not installed"; then
    echo "[test_dpkg_v2] OK: dpkg -r on an already-removed package errors cleanly"
else
    echo "[test_dpkg_v2] MISS: dpkg -r on an already-removed package did not error"
    fail=1
fi

# (g) Removing a never-installed package must error cleanly.
GHOST_WINDOW=$(sed -n '/DPKGV2_GHOST_START/,/DPKGV2_GHOST_END/p' "$LOG")
if echo "$GHOST_WINDOW" | grep -F -q "dpkg: package '$GHOST_PKG' is not installed"; then
    echo "[test_dpkg_v2] OK: dpkg -r on a never-installed package errors cleanly"
else
    echo "[test_dpkg_v2] MISS: dpkg -r on a never-installed package did not error"
    fail=1
fi

# (h) The remove path must not have left a corrupt status DB: no dpkg
# write/overflow error lines anywhere.
if grep -E -q "dpkg: (short write|status DB would exceed|cannot open status DB)" "$LOG"; then
    echo "[test_dpkg_v2] MISS: dpkg emitted a status-DB write error:"
    grep -E "dpkg: (short write|status DB would exceed|cannot open status DB)" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_dpkg_v2] OK: no status-DB write errors"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_dpkg_v2] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_dpkg_v2] (6/6) PASS"
echo "[test_dpkg_v2] PASS"
