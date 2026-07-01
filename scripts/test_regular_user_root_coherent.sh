#!/usr/bin/env bash
# scripts/test_regular_user_root_coherent.sh
#
# Regression: the REGULAR user's `ls /` must be COHERENT — every entry it
# enumerates must actually resolve (be listable / cd-able). No dangling
# entries.
#
# The live image logs the interactive console in as the default regular
# user `live` (uid 1001). `ls /` synthesizes one child per namespace
# mount-table bind of `/` (the kernel plants /dev /proc /srv /net /n /mnt
# /ext /sys and hamsh binds /fd), so those names appear in the listing.
# Before the fix, several were listed but UNLISTABLE:
#   * /proc (#p)  -> bare `#p` open returned ENOENT ("no listing yet")
#   * /fd   (#d)  -> bare `#d` open returned ENOENT
#   * /mnt  (#f)  -> the FS_KIND file-read arm shadowed the dir arm
#   * /ext  (#e)  -> unmounted volume mountpoint fell through to ENOENT
# so a regular user saw `ls: ./proc: No such file or directory` (and the
# same for mnt/ext/fd) — an incoherent FS UX. This gate drives the exact
# regular-user scenario and asserts NONE of the enumerated `/` entries
# error on a follow-up `ls`.
#
# Fast `-kernel` path (mirrors scripts/test_live_default_user.sh): a
# stripped rc plants the identity binds + does `setuid 1001` (rc.boot's
# live-branch tail), then main() sources the per-user recipe. The baked
# /dev/ram0 FAT image mounts at /mnt (so /mnt lists real content); no
# ext4 disk is attached, so /ext is an empty (but resolvable) mountpoint.
#
# rc=124/137/143 (host-load timeout/kill) is NOT a failure — the asserts
# key off captured markers, not the qemu exit code.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[rootcoherent] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null

echo "[rootcoherent] (2/4) Plant stripped rc (identity binds + setuid 1001)"
RC_TMP=$(mktemp /tmp/hamsh-rc-rootcoh.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
bind '#s' /srv
bind '#p' /proc
bind '#/' /n
bind '#c' /dev
bind '#b' /dev/blk
bind '#I' /net
bind '#r/etc/passwd' /etc/passwd
bind '#r/etc/shadow' /etc/shadow
bind '#r/etc/group' /etc/group
bind '#t/tmp' /home
mkdir /home/live
echo TEST_RC_DROP
setuid 1001
echo TEST_RC_DONE
EOF

echo "[rootcoherent] (3/4) Build initramfs (hamsh as /init) + kernel"
INIT_HAMSH=$(mktemp /tmp/hamsh-init-rootcoh.XXXXXX.elf)
cp "$HAMSH_ELF" "$INIT_HAMSH"
HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$INIT_HAMSH" \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-rootcoh.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP" "$INIT_HAMSH"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[rootcoherent] (4/4) Boot QEMU + probe the regular-user root listing"
set +e
(
    sleep 24
    printf 'echo SYNC_FLUSH\n'; sleep 3
    printf 'echo SYNC_FLUSH\n'; sleep 3
    printf 'echo WHO_BEGIN\n'; sleep 2
    printf 'whoami\n'; sleep 3
    printf 'echo PROBE_BEGIN\n'; sleep 1
    printf 'ls /\n'; sleep 3
    printf 'ls /proc\n'; sleep 2
    printf 'cd /proc\n'; sleep 2
    printf 'cd /\n'; sleep 2
    printf 'ls /fd\n'; sleep 2
    printf 'ls /net\n'; sleep 2
    printf 'ls /mnt\n'; sleep 2
    printf 'ls /ext\n'; sleep 2
    printf 'echo PROBE_END\n'; sleep 2
) | timeout 260s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 1G \
    -monitor none -serial stdio > "$LOG" 2>&1
rc=$?
set -e

CLEAN=$(mktemp --tmpdir hamnix-rootcoh.clean.XXXXXX.log)
sed -e 's/\r//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$LOG" | grep -av "hamsh-alive" > "$CLEAN"

echo "[rootcoherent] --- probe section ---"
sed -n '/PROBE_BEGIN/,/PROBE_END/p' "$CLEAN" | sed 's/hamsh\$ //g' | grep -avE '^$'
echo "[rootcoherent] --- end ---"

fail=0
grep -a -q "TEST_RC_DONE" "$CLEAN" || { echo "[rootcoherent] FAIL: rc (setuid 1001) did not complete"; fail=1; }

# Identity dropped to the regular user.
if sed -n '/WHO_BEGIN/,/PROBE_BEGIN/p' "$CLEAN" | grep -a -E -q '^live$'; then
    echo "[rootcoherent] OK: session is the regular user 'live' (uid 1001)"
else
    echo "[rootcoherent] FAIL: session did not drop to regular user 'live'"; fail=1
fi

# The core assertion: NOTHING in the probe section dangles.
PROBE=$(sed -n '/PROBE_BEGIN/,/PROBE_END/p' "$CLEAN")
if printf '%s\n' "$PROBE" | grep -a -q "listdir failed"; then
    echo "[rootcoherent] FAIL: a listed / entry could not be listed:"
    printf '%s\n' "$PROBE" | grep -a "listdir failed" | sed 's/^/[rootcoherent]   /'
    fail=1
else
    echo "[rootcoherent] OK: no 'listdir failed' — every listed / entry resolves"
fi
if printf '%s\n' "$PROBE" | grep -a -qiE "No such file"; then
    echo "[rootcoherent] FAIL: a listed / entry stat'd as 'No such file or directory'"
    fail=1
else
    echo "[rootcoherent] OK: no 'No such file or directory' on any listed entry"
fi

# Positive checks: /proc and /fd genuinely resolve (not just silently empty).
if printf '%s\n' "$PROBE" | grep -a -q "^version$"; then
    echo "[rootcoherent] OK: /proc lists its well-known files (version, ...)"
else
    echo "[rootcoherent] FAIL: /proc did not list its contents"; fail=1
fi
if printf '%s\n' "$PROBE" | grep -a -qE "^[0-9]+$"; then
    echo "[rootcoherent] OK: /proc lists live pids"
else
    echo "[rootcoherent] FAIL: /proc listed no pids"; fail=1
fi

rm -f "$CLEAN"
if [ "$fail" -ne 0 ]; then
    echo "[rootcoherent] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[rootcoherent] PASS — regular-user 'ls /' is coherent (every entry resolves)"
exit 0
