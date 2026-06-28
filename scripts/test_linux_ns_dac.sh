#!/usr/bin/env bash
# scripts/test_linux_ns_dac.sh
#
# Proves REAL per-file POSIX DAC inside the Linux namespace, keyed off the
# mapped Linux uid. This closes the leak the multi-user work (#497) flagged:
# until now a non-root user (`dave`, uid 1000) inside `enter linux` could
# read root-owned /etc/shadow because the credential store shipped 0644 in
# the cpio.
#
# WHAT THIS GATES (all through the EXISTING kernel server-boundary perm
# check, fs/vfs.ad:chan_permission_check -> _perm_check_cpio, which fires
# on the Linux-ABI vfs_open path and keys off current_task_uid() with a
# hostowner==Linux-root bypass):
#
#   ROOT (hostowner) inside enter linux:
#     - /etc/shadow (0600 root)        -> OK   (root bypass)
#     - /etc/dac-root600.txt (0600)    -> OK   (root bypass, read)
#     - /etc/dac-world.txt (0644)      -> OK
#   DAVE (uid 1000) inside enter linux:
#     - /etc/shadow (0600 root)        -> EACCES  <- THE headline (leak shut)
#     - /etc/dac-root600.txt (0600)    -> EACCES  (read + write both denied)
#     - /etc/dac-world.txt (0644)      -> OK      (world-readable still works)
#
# REGRESSION: hostowner enter linux still reports uid 0; dave still 1000.
#
# HARNESS — mirrors scripts/test_shared_passwd_regular_user.sh exactly:
# hamsh as /init under the lean `-kernel` TCG path, with a STRIPPED RC that
# plants device binds + an overlay `linux` ns and does NOT enter runlevel 5
# (serial stays interactive). The DAC probe (tests/u-binary/u_dac_probe) is
# a static-PIE glibc ELF whose open()/getuid() run through the real Linux-
# ABI dispatch regardless of namespace; the cpio /etc/* fixtures (planted
# with KNOWN modes by build_initramfs.py under ENABLE_DAC_TEST=1) are
# reachable directly from the overlay's inherited native root.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

ensure_ubin_or_skip test_linux_ns_dac u_dac_probe dac_probe

echo "[test_dac] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_dac] (2/4) Plant stripped /etc/hamsh.rc (device binds + linux ns)"
RC_TMP=$(mktemp /tmp/hamsh-rc-dac.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
bind '#c' /dev
bind '#s' /srv
bind '#p' /proc
bind '#/' /n
bind '#r/etc/passwd' /etc/passwd
bind '#r/etc/shadow' /etc/shadow
bind '#r/etc/group' /etc/group
bind '#r/etc/dac-world.txt' /etc/dac-world.txt
bind '#r/etc/dac-root600.txt' /etc/dac-root600.txt
linux = ns {
}
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[test_dac] (3/4) Build initramfs (hamsh as /init) + embed probe + DAC fixtures + kernel"
INIT_HAMSH=$(mktemp /tmp/hamsh-init-dac.XXXXXX.elf)
cp "$HAMSH_ELF" "$INIT_HAMSH"
HAMNIX_EMBED_UBIN=1 ENABLE_DAC_TEST=1 HAMNIX_HAMSH_RC="$RC_TMP" \
    INIT_ELF="$INIT_HAMSH" \
    python3 scripts/build_initramfs.py >/dev/null

mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-dac.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP" "$INIT_HAMSH"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_dac] (4/4) Boot QEMU + drive root + dave DAC probes"
set +e
(
    sleep 24
    printf 'echo SYNC_FLUSH\n'; sleep 3
    printf 'echo SYNC_FLUSH\n'; sleep 3

    # PHASE A (hostowner / root): every read OK (root bypass).
    printf 'echo HOST_DAC_BEGIN\n'; sleep 1
    printf 'enter linux { /bin/u_dac_probe }\n'; sleep 6
    printf 'enter linux { /bin/u_dac_probe }\n'; sleep 6
    printf 'echo HOST_DAC_END\n'; sleep 1

    # PHASE B: su to dave (non-root). The shared-shadow auth runs a
    # SHA-512 crypt which is CPU-heavy under TCG — generous settle.
    printf 'echo SU_BEGIN\n'; sleep 2
    printf 'su dave\n'; sleep 12
    printf 'hamnix\n'; sleep 22
    printf 'echo SU_AFTER\n'; sleep 5

    # PHASE C (dave): enforced — shadow/root600 denied, world OK.
    printf 'echo DAVE_DAC_BEGIN\n'; sleep 2
    printf 'enter linux { /bin/u_dac_probe }\n'; sleep 12
    printf 'enter linux { /bin/u_dac_probe }\n'; sleep 12
    printf 'echo DAVE_DAC_END\n'; sleep 2

    printf 'echo ALL_DONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 800s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[test_dac] --- captured output (tail) ---"
tail -300 "$LOG" | strings
echo "[test_dac] --- end output ---"

fail=0

# Marker-windowed search: assert `pat` appears between BEGIN and END.
between() {
    local beg="$1" end="$2" pat="$3"
    LC_ALL=C awk -v b="$beg" -v e="$end" -v p="$pat" '
        BEGIN { armed=0; found=0 }
        index($0,b)>0 { armed=1; next }
        index($0,e)>0 { armed=0 }
        armed && index($0,p)>0 { found=1 }
        END { exit found?0:1 }
    ' "$LOG"
}

if grep -a -F -q "TEST_RC_DONE_DEFINING_NS" "$LOG"; then
    echo "[test_dac] OK: stripped rc sourced + linux ns captured"
else
    echo "[test_dac] FAIL: stripped rc did not run"
    fail=1
fi

# --- ROOT (hostowner) window: every read OK -------------------------------
if between "HOST_DAC_BEGIN" "HOST_DAC_END" "DAC: uid=0 gid=0"; then
    echo "[test_dac] OK: root enter linux -> uid 0 (root) [no regression]"
else
    echo "[test_dac] FAIL: root enter linux did not report uid 0"
    fail=1
fi
if between "HOST_DAC_BEGIN" "HOST_DAC_END" "DAC: shadow_ro errno=0 OK"; then
    echo "[test_dac] OK: root reads /etc/shadow (root bypass)"
else
    echo "[test_dac] FAIL: root could NOT read /etc/shadow"
    fail=1
fi
if between "HOST_DAC_BEGIN" "HOST_DAC_END" "DAC: root600_ro errno=0 OK"; then
    echo "[test_dac] OK: root reads /etc/dac-root600.txt (root bypass)"
else
    echo "[test_dac] FAIL: root could NOT read /etc/dac-root600.txt"
    fail=1
fi
if between "HOST_DAC_BEGIN" "HOST_DAC_END" "DAC: world_ro errno=0 OK"; then
    echo "[test_dac] OK: root reads world-readable /etc/dac-world.txt"
else
    echo "[test_dac] FAIL: root could NOT read /etc/dac-world.txt"
    fail=1
fi

# --- DAVE (uid 1000) window: enforced -------------------------------------
if between "DAVE_DAC_BEGIN" "DAVE_DAC_END" "DAC: uid=1000 gid=1000"; then
    echo "[test_dac] OK: dave enter linux -> uid 1000 (non-root)"
else
    echo "[test_dac] FAIL: dave enter linux did not report uid 1000"
    fail=1
fi
# THE HEADLINE: dave is DENIED /etc/shadow.
if between "DAVE_DAC_BEGIN" "DAVE_DAC_END" "DAC: shadow_ro errno=13 EACCES"; then
    echo "[test_dac] OK: dave DENIED /etc/shadow (EACCES) -- leak shut"
else
    echo "[test_dac] FAIL: dave was NOT denied /etc/shadow (the #497 leak is OPEN)"
    fail=1
fi
if between "DAVE_DAC_BEGIN" "DAVE_DAC_END" "DAC: root600_ro errno=13 EACCES"; then
    echo "[test_dac] OK: dave DENIED read of root-owned 0600 file"
else
    echo "[test_dac] FAIL: dave was NOT denied read of root-owned 0600 file"
    fail=1
fi
if between "DAVE_DAC_BEGIN" "DAVE_DAC_END" "DAC: root600_wo errno=13 EACCES"; then
    echo "[test_dac] OK: dave DENIED write of root-owned 0600 file"
else
    echo "[test_dac] FAIL: dave was NOT denied write of root-owned 0600 file"
    fail=1
fi
# World-readable file MUST still be readable by dave.
if between "DAVE_DAC_BEGIN" "DAVE_DAC_END" "DAC: world_ro errno=0 OK"; then
    echo "[test_dac] OK: dave CAN read world-readable /etc/dac-world.txt"
else
    echo "[test_dac] FAIL: dave could NOT read the world-readable file (over-denial)"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_dac] PASS"
    exit 0
fi
echo "[test_dac] FAIL (rc=$rc)"
exit 1
