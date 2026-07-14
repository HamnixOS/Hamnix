#!/usr/bin/env bash
# scripts/test_curl.sh — end-to-end test for the native `curl` (and a
# quick `wget`) binary fetching over HTTP and HTTPS from a fresh
# QEMU/SLIRP boot. The networking counterpart to scripts/test_hpm.sh,
# modelled directly on scripts/test_hpm_network.sh (same boot + outbound
# SLIRP setup that reaches https://255.one/ from inside the VM).
#
# WHAT THE TEST DOES
#
#   1. Build the userland (curl + wget + http9 ride in via build_user.sh)
#      and a hamsh-as-init initramfs so the box lands in the shell.
#   2. Boot QEMU with a virtio-net NIC backed by SLIRP user-mode
#      networking (gateway 10.0.2.2, DNS 10.0.2.3, guest 10.0.2.15) —
#      the same egress path GNOME Boxes uses.
#   3. From the shell, run an HTTPS fetch and an HTTP fetch against
#      https://255.one/ / http://255.one/ and assert the JSON body
#      appears in curl's output.
#
# REQUIRED MARKERS for PASS:
#   * "[dhcp] got ip=10.0.2.15"           — DHCP succeeded
#   * curl HTTPS output contains a known index.json key                 (TLS path)
#   * curl HTTP output contains a known index.json key                  (plain path)
#   * NO "TRAP: vector"                   — no panic
#
# NETWORK-DEPENDENCY POLICY (mirrors test_hpm_network.sh): if the host
# has no internet egress (CI sandbox without egress, or 255.one down)
# the fetch steps downgrade to SKIP — DHCP landing at 10.0.2.15 still
# proves the boot/network bring-up. The internet-reachability probe is a
# `ping 1.1.1.1` exactly as in test_hpm_network.sh.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_curl] (1/3) Build userland + hamsh-as-init initramfs"
bash scripts/build_user.sh >/dev/null
if [ ! -x "build/user/curl.elf" ]; then
    echo "[test_curl] FAIL: build/user/curl.elf missing after build"
    exit 1
fi
if [ ! -x "build/user/wget.elf" ]; then
    echo "[test_curl] FAIL: build/user/wget.elf missing after build"
    exit 1
fi
INIT_ELF="$HAMSH_ELF" \
    python3 scripts/build_initramfs.py >/dev/null

echo "[test_curl] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_curl] (3/3) Boot QEMU + drive curl / wget"
LOG=$(mktemp /tmp/test-curl.XXXXXX.log)
trap '[ "${CURL_KEEP_LOG:-0}" = 1 ] || rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

export QEMU_EXTRA_ARGS="-netdev user,id=n0 -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56"

set +e
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 180 \
    -- "echo CURL_START"                                         2 \
       "/bin/ping -c 2 -i 200 1.1.1.1"                           8 \
       "echo CURL_PING_DONE"                                     2 \
       "curl https://255.one/main/index.json"                   6 \
       "echo CURL_HTTPS_DONE"                                    2 \
       "curl http://255.one/main/index.json"                    6 \
       "echo CURL_HTTP_DONE"                                     2 \
       "curl 255.one/main/index.json"                            6 \
       "echo CURL_SCHEMELESS_DONE"                               2 \
       "wget -O /tmp/idx.json https://255.one/main/index.json"  6 \
       "cat /tmp/idx.json"                                       3 \
       "echo CURL_WGET_DONE"                                     2 \
       "exit"                                                    2
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_curl] --- captured (relevant lines) ---"
grep -E '\[dhcp\]|bytes from|CURL_|"name"|"version"|"packages"|curl:|wget:|saved' "$LOG" || true
echo "[test_curl] --- end ---"

fail=0

# 1. NO kernel panic / trap.
if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_curl] FAIL: kernel reported a CPU exception"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
else
    echo "[test_curl] OK: no kernel TRAP / panic"
fi

# 2. Shell came up.
if ! grep -F -q "CURL_START" "$LOG"; then
    echo "[test_curl] FAIL: shell never accepted the first command"
    tail -n 100 "$LOG"
    exit 1
fi

# 3. DHCP succeeded.
if grep -F -q "[dhcp] got ip=10.0.2.15" "$LOG"; then
    echo "[test_curl] OK: DHCP got ip=10.0.2.15"
else
    echo "[test_curl] FAIL: DHCP did NOT bind 10.0.2.15"
    fail=1
fi

# 4. Internet egress probe — gates the fetch assertions to SKIP when
# the host has no outbound connectivity (same policy as test_hpm_network).
internet_block=$(sed -n '/CURL_START/,/CURL_PING_DONE/p' "$LOG")
internet_alive=0
if echo "$internet_block" | grep -E -q "bytes from 1.1.1.1: icmp_seq="; then
    echo "[test_curl] OK: ping 1.1.1.1 replied (internet reachable)"
    internet_alive=1
else
    echo "[test_curl] NOTE: ping 1.1.1.1 didn't reply — host may have no"
    echo "[test_curl]       internet egress; fetch steps downgraded to SKIP"
fi

# A known key in 255.one's main/index.json. The repo index is JSON with
# package metadata; "name" and "version" are present for every entry.
KEYRE='"(name|version|packages)"'

# 5. HTTPS fetch (the TLS path).
https_block=$(sed -n '/CURL_PING_DONE/,/CURL_HTTPS_DONE/p' "$LOG")
https_ok=0
if echo "$https_block" | grep -E -q "$KEYRE"; then
    https_ok=1
    echo "[test_curl] OK: curl HTTPS fetch returned JSON (TLS path works)"
fi

# 6. HTTP fetch (the plain-TCP path).
http_block=$(sed -n '/CURL_HTTPS_DONE/,/CURL_HTTP_DONE/p' "$LOG")
http_ok=0
if echo "$http_block" | grep -E -q "$KEYRE"; then
    http_ok=1
    echo "[test_curl] OK: curl HTTP fetch returned JSON (plain TCP works)"
fi

# 6b. Scheme-less fetch (`curl 255.one/...`, no http://) — the hands-on-QA
# bug shape. Must behave like the explicit-http path (curl defaults to
# http://), NOT fail "malformed or unsupported URL".
schemeless_block=$(sed -n '/CURL_HTTP_DONE/,/CURL_SCHEMELESS_DONE/p' "$LOG")
schemeless_ok=0
if echo "$schemeless_block" | grep -F -q "malformed or unsupported URL"; then
    echo "[test_curl] FAIL: scheme-less 'curl 255.one/...' still rejects the URL"
    fail=1
elif echo "$schemeless_block" | grep -E -q "$KEYRE"; then
    schemeless_ok=1
    echo "[test_curl] OK: scheme-less curl fetch returned JSON (http:// default)"
fi

# 7. wget -> file -> cat round-trip.
wget_block=$(sed -n '/CURL_SCHEMELESS_DONE/,/CURL_WGET_DONE/p' "$LOG")
wget_ok=0
if echo "$wget_block" | grep -E -q "saved [0-9]+ bytes"; then
    if echo "$wget_block" | grep -E -q "$KEYRE"; then
        wget_ok=1
        echo "[test_curl] OK: wget saved a file and the body round-tripped"
    fi
fi

if [ "$https_ok" -eq 1 ] && [ "$http_ok" -eq 1 ] && [ "$schemeless_ok" -eq 1 ] && [ "$wget_ok" -eq 1 ]; then
    echo "[test_curl] OK: curl + wget fetch HTTP, HTTPS and scheme-less correctly"
elif [ "$internet_alive" -eq 1 ]; then
    echo "[test_curl] FAIL: internet reachable but a fetch assertion missed"
    echo "[test_curl]       (https_ok=$https_ok http_ok=$http_ok schemeless_ok=$schemeless_ok wget_ok=$wget_ok)"
    fail=1
else
    echo "[test_curl] SKIP: fetch assertions — no host internet egress"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_curl] FAIL (qemu rc=$rc)"
    echo "[test_curl] --- full log (last 200 lines) ---"
    tail -n 200 "$LOG"
    exit 1
fi
echo "[test_curl] PASS (qemu rc=$rc)"
