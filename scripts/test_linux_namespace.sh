#!/usr/bin/env bash
# scripts/test_linux_namespace.sh - Linux runtime namespace primitives.
#
# Verifies that `enter linux { ... }` works end-to-end against the
# `/var/lib/distros/default` distro tree that build_initramfs.py
# populates (busybox-musl applet symlinks + tests/distros/default/
# fixture):
#
#   1. `enter linux { /bin/ls / }`             — lists distro root,
#                                                showing bin/ etc/.
#   2. `enter linux { /bin/echo hello world }` — runs a Linux ABI
#                                                static-PIE binary
#                                                (busybox echo applet)
#                                                inside the namespace.
#   3. `enter linux { /bin/cat /etc/debian_version }` — reads the
#                                                distro tree's
#                                                /etc/debian_version
#                                                via the `/` rebind
#                                                ("12.4" fixture).
#   4. `enter linux { /bin/ls }`               — lists cwd (`/`) — proves
#                                                cwd is sane inside the
#                                                clean namespace and
#                                                resolves the same as
#                                                `/bin/ls /`.
#
# This is the regression test the linux-namespace task's
# acceptance criteria call for. Per [[feedback-regression-prone-needs-
# test]] — broken Linux ns is exactly the silent-fail surface that
# wants a CI grep test.
#
# DRIVE STRATEGY: this test does NOT boot the default rc.boot path.
# The default boot runs etc/rc.boot which spawns sshd-as-detached;
# sshd's accept-loop currently does enough non-blocking polls to
# starve the interactive hamsh of CPU (a separate known bug —
# heartbeat regresses, stdin polling stalls). To exercise the
# namespace primitives reliably we drop hamsh as /init directly
# (INIT_ELF=hamsh.elf) and plant a custom /etc/hamsh.rc via
# HAMNIX_HAMSH_RC that defines the same `linux = ns clean { … }`
# template rc.boot uses, with no service spawns. This is the cleanest
# isolation of the namespace surface; the sshd-starvation work lives
# elsewhere.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_linux_namespace] (1/4) Build userland (hamsh + helpers)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_linux_namespace] (2/4) Plant /etc/hamsh.rc with the linux recipe"
# /etc/hamsh.rc is run by hamsh-as-PID-1 when invoked with no rc-path
# argv. This stripped-down recipe captures the linux runtime namespace
# without launching any boot services (rc.boot's sshd is what wedges
# the heartbeat — see header). Same `ns clean { ... }` body
# rc.boot uses; the test must match the production shape so failures
# here flag real regressions, not divergence between rcs.
RC_TMP=$(mktemp /tmp/hamsh-rc-linuxns.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
linux = ns clean {
    bind /var/lib/distros/default /
    bind /home /home
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}
debian = ns clean {
    bind /var/lib/distros/default /
    bind /home /home
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[test_linux_namespace] (3/4) Build initramfs (hamsh as /init)"
HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

LOG=$(mktemp /tmp/test-linux-ns.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP"
    # Restore the default initramfs (default /init shim + no rc override)
    # so subsequent tests boot the production path.
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py \
        >/dev/null
}
trap cleanup EXIT

echo "[test_linux_namespace] (3/4) Build kernel"
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

echo "[test_linux_namespace] (4/4) Boot QEMU + drive test commands"
set +e
(
    # Wait for hamsh to source /etc/hamsh.rc and reach the interactive
    # prompt. With INIT_ELF=hamsh.elf and no rc.boot, this is fast
    # (~3-5 s of post-kernel bring-up; no boot services to spawn).
    sleep 6

    # 1. enter linux { /bin/ls / } — lists distro root (bin/, etc/, ...)
    printf 'echo BANNER_LS_ROOT_START\n'; sleep 1
    printf 'enter linux { /bin/ls / }\n'; sleep 3
    printf 'echo BANNER_LS_ROOT_END\n'; sleep 1

    # 2. enter linux { /bin/echo hello world } — Linux ABI binary in ns
    printf 'echo BANNER_ECHO_START\n'; sleep 1
    printf 'enter linux { /bin/echo hello world }\n'; sleep 3
    printf 'echo BANNER_ECHO_END\n'; sleep 1

    # 3. enter linux { /bin/cat /etc/debian_version } — distro-tree read
    printf 'echo BANNER_CAT_START\n'; sleep 1
    printf 'enter linux { /bin/cat /etc/debian_version }\n'; sleep 3
    printf 'echo BANNER_CAT_END\n'; sleep 1

    # 4. enter linux { /bin/ls } — bare ls (cwd) inside the ns. The
    #    rfork inherits hamsh's cwd which is "/", so this should match
    #    `/bin/ls /`.
    printf 'echo BANNER_LS_DOT_START\n'; sleep 1
    printf 'enter linux { /bin/ls }\n'; sleep 3
    printf 'echo BANNER_LS_DOT_END\n'; sleep 1

    # 5. debian alias also resolves.
    printf 'echo BANNER_ALIAS_START\n'; sleep 1
    printf 'enter debian { /bin/cat /etc/debian_version }\n'; sleep 3
    printf 'echo BANNER_ALIAS_END\n'; sleep 1

    # 6. UNDEFINED template must LOUDLY refuse and NOT run the body in
    #    the current namespace (the silent-no-op bug). The body prints a
    #    sentinel; if it appears, the body ran (regression). The stderr
    #    error string "enter: not a namespace:" MUST appear.
    printf 'echo BANNER_UNDEF_START\n'; sleep 1
    printf 'enter foobar { echo BODY_RAN_IN_CURRENT_NS }\n'; sleep 2
    printf 'echo BANNER_UNDEF_END\n'; sleep 1

    printf 'echo BANNER_DONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 60s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[test_linux_namespace] --- captured output (tail) ---"
tail -200 "$LOG" | strings
echo "[test_linux_namespace] --- end output ---"

fail=0

check_present() {
    local needle="$1"
    local label="$2"
    if grep -F -q "$needle" "$LOG"; then
        echo "[test_linux_namespace] OK: $label"
    else
        echo "[test_linux_namespace] MISS: $label  ('$needle')"
        fail=1
    fi
}

# Banner-window assertion: VALUE must appear within 30 lines of BANNER.
# Mirrors the helper in test_distro_namespace.sh.
check_banner_value() {
    local banner="$1"
    local value="$2"
    local label="$3"
    if awk -v b="$banner" -v v="$value" '
        BEGIN { armed=0; win=0; found=0 }
        index($0, "[atkbd-diag]") > 0 { next }
        index($0, b) > 0 { armed=1; win=0; next }
        armed { win++ ; if (index($0, v) > 0) { found=1; exit }
                if (win > 30) armed=0 }
        END { exit found ? 0 : 1 }
    ' "$LOG"; then
        echo "[test_linux_namespace] OK: $label"
    else
        echo "[test_linux_namespace] MISS: $label" \
             "(banner='$banner' value='$value')"
        fail=1
    fi
}

# Tighter banner-window assertion: VALUE must appear AFTER the line
# that issues the `enter` command, so the hamsh-prompt character-by-
# character echo of the input doesn't trip the substring search. The
# `enter` line is identified by the verbatim source containing the
# closing "}" — once hamsh accepts the final newline, all subsequent
# bytes within `win` lines are the namespace child's output.
check_banner_post_enter_value() {
    local banner="$1"
    local value="$2"
    local label="$3"
    if awk -v b="$banner" -v v="$value" '
        BEGIN { armed=0; past_enter=0; win=0; found=0 }
        index($0, "[atkbd-diag]") > 0 { next }
        index($0, b) > 0 { armed=1; past_enter=0; win=0; next }
        armed && index($0, "enter linux { /bin/ls / }") > 0 { past_enter=1; next }
        armed && index($0, "enter linux { /bin/echo") > 0 { past_enter=1; next }
        armed && index($0, "enter linux { /bin/cat") > 0 { past_enter=1; next }
        armed && index($0, "enter linux { /bin/ls }") > 0 { past_enter=1; next }
        armed && index($0, "enter debian { /bin/cat") > 0 { past_enter=1; next }
        armed && past_enter { win++ ; if (index($0, v) > 0) { found=1; exit }
                if (win > 30) armed=0 }
        END { exit found ? 0 : 1 }
    ' "$LOG"; then
        echo "[test_linux_namespace] OK: $label"
    else
        echo "[test_linux_namespace] MISS: $label" \
             "(banner='$banner' value='$value' post-enter)"
        fail=1
    fi
}

# Companion: assert VALUE is ABSENT in the same banner window. Used to
# pin "this error string MUST NOT appear" — e.g. "ls: /: No such file".
check_banner_absent() {
    local banner="$1"
    local value="$2"
    local label="$3"
    if awk -v b="$banner" -v v="$value" '
        BEGIN { armed=0; win=0; found=0 }
        index($0, "[atkbd-diag]") > 0 { next }
        index($0, b) > 0 { armed=1; win=0; next }
        armed { win++ ; if (index($0, v) > 0) { found=1; exit }
                if (win > 30) armed=0 }
        END { exit found ? 1 : 0 }
    ' "$LOG"; then
        echo "[test_linux_namespace] OK: $label"
    else
        echo "[test_linux_namespace] FAIL: $label" \
             "(banner='$banner' must NOT contain '$value')"
        fail=1
    fi
}

# Sanity: hamsh sourced the rc and defined the linux/debian ns values.
check_present "TEST_RC_DONE_DEFINING_NS" \
              "/etc/hamsh.rc captured linux + debian ns values"

# 1. ls / inside the linux ns lists distro root from the distro tree.
# The "ls: /: No such file or directory" failure is the bug the linux-
# namespace task aimed to fix — assert the negative AND positive
# (busybox prints names one-per-line; the distro tree has /bin and
# /etc so both should appear). busybox ls colorises with ANSI escapes
# so the visible "bin" / "etc" tokens land on their own lines amid
# control bytes; the substring match still picks them up.
check_banner_absent "BANNER_LS_ROOT_START" "ls: /: No such file" \
                    "enter linux { /bin/ls / } does NOT report ENOENT"
check_banner_post_enter_value "BANNER_LS_ROOT_START" "bin" \
                    "enter linux { /bin/ls / } shows bin/"
check_banner_post_enter_value "BANNER_LS_ROOT_START" "etc" \
                    "enter linux { /bin/ls / } shows etc/"

# 2. /bin/echo hello world runs and prints "hello world".
check_banner_value "BANNER_ECHO_START" "hello world" \
                   "enter linux { /bin/echo hello world } prints"

# 3. /bin/cat /etc/debian_version reads "12.4" from the distro tree.
check_banner_value "BANNER_CAT_START" "12.4" \
                   "enter linux { /bin/cat /etc/debian_version } reads distro"

# 4. /bin/ls (no arg) lists cwd; cwd is /, same as `ls /`.
check_banner_post_enter_value "BANNER_LS_DOT_START" "bin" \
                   "enter linux { /bin/ls } lists cwd shows bin/"

# 5. debian alias resolves the same backing tree.
check_banner_value "BANNER_ALIAS_START" "12.4" \
                   "enter debian alias also reads distro"

# 6. Undefined-template enter: LOUD error fires, body does NOT run.
#    This is the silent-no-op root-cause fix (exec_enter refuses a
#    non-VT_NS name instead of running the body in the current ns).
check_banner_value "BANNER_UNDEF_START" "not a namespace" \
                   "enter foobar { } prints loud 'not a namespace' error"
check_banner_absent "BANNER_UNDEF_START" "BODY_RAN_IN_CURRENT_NS" \
                   "enter foobar { } does NOT run the body in current ns"

# 7. rc.de-user now exposes the linux/debian templates (DE terminal can
#    enter the Linux ns from the desktop). Static grep — no boot needed.
if grep -Eq "^linux = ns clean \{" etc/rc.de-user \
   && grep -Eq "^debian = ns clean \{" etc/rc.de-user \
   && grep -q "bind '#distro' /" etc/rc.de-user; then
    echo "[test_linux_namespace] OK: rc.de-user defines linux+debian (#distro) templates"
else
    echo "[test_linux_namespace] FAIL: rc.de-user missing linux/debian #distro templates"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_linux_namespace] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_linux_namespace] PASS"
