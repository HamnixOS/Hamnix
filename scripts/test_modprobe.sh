#!/usr/bin/env bash
# scripts/test_modprobe.sh — regression guard for the native userland
# modprobe (user/modprobe.ad).
#
# Premise: user/modprobe.ad resolves a module's dependency chain from a
# Linux-shape modules.dep and loads every module (deps first) via
# SYS_INIT_MODULE (175) — the userland counterpart to the in-kernel
# dep walker (kernel/modules_dep.ad).
#
# Fixture: we reuse the SAME stock-Linux .ko's the existing two-module
# dependency-chain test (scripts/test_l37_dependency_chain.sh) stages —
# crc32c_generic.ko (registers the "crc32c" shash) and libcrc32c.ko
# (looks that shash up via crypto_alloc_shash at its own init). These
# are tiny (~10 KiB each), so the userland read-whole-file-into-buffer
# path is cheap and the QEMU boot stays fast. The load ORDER is real:
# libcrc32c's init fails unless crc32c_generic ran first, so this is a
# genuine dependency, not a synthetic one.
#
# Both .ko's are host-dependent (built against the host's running
# kernel); if they aren't present we SKIP (exit 0) exactly like
# test_l37 — this is not a Hamnix regression.
#
# We stage them at tests/linux-modules/{crc32c_generic,libcrc32c}.ko
# (the build_initramfs.py glob embeds each at /lib/modules/6.12/<name>.ko)
# plus a synthetic Linux-shape modules.dep at
# /lib/modules/6.12/modprobe-test.dep:
#
#       crc32c_generic.ko:
#       libcrc32c.ko: crc32c_generic.ko
#
# The .ko paths are relative to the dep file's directory
# (/lib/modules/6.12/), where the two .ko's live. We boot hamsh and
# drive:
#       modprobe -d /lib/modules/6.12/modprobe-test.dep -v libcrc32c
# libcrc32c's line names crc32c_generic as its dependency, so modprobe
# MUST load crc32c_generic BEFORE libcrc32c.
#
# Dependency-load ordering rule under test: depmod pre-flattens the
# full transitive dep set onto each line, listed most-dependent-FIRST;
# the conventional load order loads the deps RIGHT-TO-LEFT (leaf-most
# first), then the target last. For this 2-module chain that reduces to
# "crc32c_generic, then libcrc32c".
#
# Assertions (from the serial log, isolated to OUR modprobe run):
#   1. The fixture .ko's + modules.dep are in the cpio.
#   2. modprobe's verbose "loading crc32c_generic" appears BEFORE
#      "loading libcrc32c" (userland order proof).
#   3. modprobe reports BOTH modules loaded with a positive kernel slot
#      id ("loaded crc32c_generic (slot N)" / "loaded libcrc32c
#      (slot M)") and N < M (deps-first, both succeeded). SYS_INIT_MODULE
#      returns the slot id on success / -errno on failure, so a "loaded"
#      line is direct proof the kernel accepted and ran the module's
#      init. NOTE: we assert on modprobe's OWN output rather than the
#      kernel's "kmod_linux:" printk, because that kernel diagnostic only
#      surfaces on the serial console for boot-time loads, not for loads
#      issued from a userland syscall context (the module still loads;
#      the syscall returns a valid slot — only the printk is invisible
#      here). That printk routing is a kernel concern, out of scope for
#      this userland tool's regression guard.
#   4. No TRAP / BUG / panic, and no "init_module failed" from modprobe.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
LKM_DIR=tests/linux-modules
STAGED_DEP="$LKM_DIR/crc32c_generic.ko"   # the dependency module
STAGED_USER="$LKM_DIR/libcrc32c.ko"       # the dependent module
DEP_PATH=/lib/modules/6.12/modprobe-test.dep
BOOT_TIMEOUT="${MODPROBE_BOOT_TIMEOUT:-40}"

# --- 0. Locate the two stock .ko's on the host ----------------------
KREL="$(uname -r)"
HOST_LIB="/lib/modules/${KREL}/kernel"
DEP_CANDIDATES=(
    "${HOST_LIB}/crypto/crc32c_generic.ko"
    "${HOST_LIB}/crypto/crc32c_generic.ko.xz"
)
USER_CANDIDATES=(
    "${HOST_LIB}/lib/libcrc32c.ko"
    "${HOST_LIB}/lib/libcrc32c.ko.xz"
)
pick_one() {
    local -n arr=$1
    for c in "${arr[@]}"; do
        if [ -f "$c" ]; then echo "$c"; return 0; fi
    done
    return 1
}
DEP_SRC="$(pick_one DEP_CANDIDATES)" || DEP_SRC=""
USER_SRC="$(pick_one USER_CANDIDATES)" || USER_SRC=""
if [ -z "$DEP_SRC" ] || [ -z "$USER_SRC" ]; then
    echo "[test_modprobe] crc32c_generic.ko / libcrc32c.ko not present on"
    echo "                this host (dep=$DEP_SRC user=$USER_SRC)"
    echo "[test_modprobe] SKIP (host-dependent fixture, not a regression)"
    exit 0
fi
echo "[test_modprobe] dep  module: $DEP_SRC"
echo "[test_modprobe] user module: $USER_SRC"

# Cleanup: un-stage the .ko's and restore the default initramfs on exit.
LOG=""
cleanup() {
    rm -f "$STAGED_DEP" "$STAGED_USER"
    [ -n "${INITRAMFS_LOG:-}" ] && rm -f "$INITRAMFS_LOG"
    [ -n "$LOG" ] && rm -f "$LOG"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- 1. Stage both .ko's under tests/linux-modules/ -----------------
mkdir -p "$LKM_DIR"
stage_one() {
    local src="$1" dst="$2"
    case "$src" in
        *.ko.xz) xz -dc "$src" > "$dst" ;;
        *.ko)    cp "$src" "$dst" ;;
    esac
}
stage_one "$DEP_SRC"  "$STAGED_DEP"
stage_one "$USER_SRC" "$STAGED_USER"
ls -l "$STAGED_DEP" "$STAGED_USER"

# --- 2. Build userland (incl. modprobe) + modules -------------------
echo "[test_modprobe] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null
if [ ! -s build/user/modprobe.elf ]; then
    echo "[test_modprobe] FAIL: build/user/modprobe.elf missing"
    exit 1
fi
echo "[test_modprobe] OK: build/user/modprobe.elf built"

# --- 3. Embed initramfs (/init=hamsh + fixture dep table) -----------
echo "[test_modprobe] (2/4) Embed initramfs (/init=hamsh, fixture dep)"
INITRAMFS_LOG=$(mktemp)
INIT_ELF="$HAMSH_ELF" ENABLE_MODPROBE_USERLAND_TEST=1 \
    python3 scripts/build_initramfs.py > "$INITRAMFS_LOG" 2>&1

fail=0
for needle in \
    "embedded /lib/modules/6.12/modprobe-test.dep" \
    "embedded /lib/modules/6.12/crc32c_generic.ko" \
    "embedded /lib/modules/6.12/libcrc32c.ko"
do
    if grep -F -q "$needle" "$INITRAMFS_LOG"; then
        echo "[test_modprobe] OK (cpio): '$needle'"
    else
        echo "[test_modprobe] MISS (cpio): '$needle'"
        fail=1
    fi
done
if [ "$fail" -ne 0 ]; then
    echo "[test_modprobe] --- build_initramfs.py stdout ---"
    cat "$INITRAMFS_LOG"
    exit 1
fi

# --- 4. Rebuild the bare-metal kernel image -------------------------
echo "[test_modprobe] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null
if [ ! -s "$ELF" ]; then
    echo "[test_modprobe] FAIL: kernel ELF missing"
    exit 1
fi
echo "[test_modprobe] OK: kernel ELF built ($(stat -c%s "$ELF") bytes)"

# --- 5. Boot QEMU and drive modprobe through hamsh ------------------
echo "[test_modprobe] (4/4) Boot QEMU and drive modprobe"
LOG=$(mktemp)

# Timing: the ISO-shim boot reaches hamsh's readline stage around
# ~8-12s; modprobe then reads + loads two ~10 KiB .ko's (fast), then
# exit. Mirrors the sleep/boot pattern of the existing L-track module
# tests (~8s boot budget, ~3-4s/command).
set +e
(
    sleep 8
    printf 'modprobe -d %s -v libcrc32c\n' "$DEP_PATH"
    sleep 4
    printf 'exit\n'
    sleep 1
) | timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
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

echo "[test_modprobe] qemu rc=$rc, log bytes=$(wc -c < "$LOG")"
echo "[test_modprobe] --- captured (modprobe / kmod_linux) ---"
grep -aE 'modprobe: |TRAP:|BUG:|PANIC|panic:' "$LOG" || true
echo "[test_modprobe] --- end ---"

if [ ! -s "$LOG" ]; then
    echo "[test_modprobe] FAIL: empty qemu log (kernel did not boot)"
    exit 1
fi

# Isolate OUR modprobe run from any boot-time module loading: slice the
# log from the first "modprobe: loading" line our tool prints.
mp_start=$(grep -aFn "modprobe: loading" "$LOG" | head -1 | cut -d: -f1 || true)
if [ -z "$mp_start" ]; then
    echo "[test_modprobe] FAIL: modprobe never printed a 'loading' line"
    echo "[test_modprobe] --- full log tail ---"
    tail -200 "$LOG"
    exit 1
fi
SLICE=$(mktemp)
tail -n "+${mp_start}" "$LOG" > "$SLICE"

# Assertion 4: no kernel-level explosion (whole log).
for bad in "TRAP:" "BUG:" "PANIC" "panic:" "init returned -"; do
    if grep -aF -q "$bad" "$LOG"; then
        echo "[test_modprobe] FAIL: detected '$bad' in log"
        grep -aF "$bad" "$LOG" | head -5
        fail=1
    fi
done
# And our tool must not have hit a fatal dep init failure.
if grep -aF -q "modprobe: init_module failed" "$SLICE"; then
    echo "[test_modprobe] FAIL: modprobe reported an init_module failure"
    grep -aF "modprobe: init_module failed" "$SLICE" | head
    fail=1
fi

# Assertion 2: userland-side order proof (modprobe -v).
mp_dep=$(grep -aFn "modprobe: loading crc32c_generic" "$SLICE" | head -1 | cut -d: -f1 || true)
mp_usr=$(grep -aFn "modprobe: loading libcrc32c" "$SLICE" | head -1 | cut -d: -f1 || true)
if [ -z "$mp_dep" ]; then
    echo "[test_modprobe] FAIL: modprobe never reported 'loading crc32c_generic'"
    fail=1
fi
if [ -z "$mp_usr" ]; then
    echo "[test_modprobe] FAIL: modprobe never reported 'loading libcrc32c'"
    fail=1
fi
if [ -n "$mp_dep" ] && [ -n "$mp_usr" ]; then
    if [ "$mp_dep" -lt "$mp_usr" ]; then
        echo "[test_modprobe] OK: modprobe loaded crc32c_generic BEFORE libcrc32c (slice lines $mp_dep < $mp_usr)"
    else
        echo "[test_modprobe] FAIL: modprobe order wrong (dep line $mp_dep !< user line $mp_usr)"
        fail=1
    fi
fi

# Assertion 3: both modules loaded with a positive kernel slot id, and
# the dependency (crc32c_generic) got a LOWER slot than the dependent
# (libcrc32c) — i.e. it was accepted by the kernel first. The slot id is
# the SYS_INIT_MODULE return value; a "loaded ... (slot N)" line means
# the kernel ran the module's init and handed back slot N (>= 1).
ld_dep=$(grep -aoE "loaded crc32c_generic \(slot [0-9]+\)" "$SLICE" | head -1 || true)
ld_usr=$(grep -aoE "loaded libcrc32c \(slot [0-9]+\)" "$SLICE" | head -1 || true)
if [ -z "$ld_dep" ]; then
    echo "[test_modprobe] FAIL: modprobe never confirmed 'loaded crc32c_generic (slot N)'"
    fail=1
fi
if [ -z "$ld_usr" ]; then
    echo "[test_modprobe] FAIL: modprobe never confirmed 'loaded libcrc32c (slot N)'"
    fail=1
fi
if [ -n "$ld_dep" ] && [ -n "$ld_usr" ]; then
    s_dep=$(echo "$ld_dep" | grep -oE 'slot [0-9]+' | grep -oE '[0-9]+')
    s_usr=$(echo "$ld_usr" | grep -oE 'slot [0-9]+' | grep -oE '[0-9]+')
    echo "[test_modprobe] OK: kernel accepted crc32c_generic as slot $s_dep, libcrc32c as slot $s_usr"
    if [ "$s_dep" -lt "$s_usr" ]; then
        echo "[test_modprobe] OK: dependency took a lower kernel slot than dependent ($s_dep < $s_usr)"
    else
        echo "[test_modprobe] FAIL: dependency slot $s_dep !< dependent slot $s_usr (load order wrong)"
        fail=1
    fi
fi
rm -f "$SLICE"

if [ "$fail" -ne 0 ]; then
    echo "[test_modprobe] FAIL (qemu rc=$rc)"
    echo "[test_modprobe] --- full log tail ---"
    tail -200 "$LOG"
    exit 1
fi

echo "[test_modprobe] PASS (modprobe -v libcrc32c loaded crc32c_generic first via modules.dep)"
