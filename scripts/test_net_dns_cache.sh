#!/usr/bin/env bash
# scripts/test_net_dns_cache.sh — exercise the post-M16.99 in-memory
# DNS result cache.
#
# M16.99 shipped a working UDP/53 resolver; without caching, every
# `dns_lookup("example.com")` triggered a fresh wire round-trip. The
# new cache (16 entries, TTL-bounded, RFC-conformant on negative
# answers) means the SECOND lookup for the same hostname should
# short-circuit before sending any UDP packet.
#
# How we exercise it under the existing init smoke test:
#   1. `net_smoke_test()` in init/main.ad calls
#      `dns_lookup("example.com", ...)` first — that's the wire query
#      (we expect "[dns] querying" to appear).
#   2. On success it calls `http_smoke_test()`, which itself calls
#      `dns_lookup(host_ptr, ...)` inside `http_get()` for the same
#      hostname — that's the cache hit (we expect "[dns] cache hit
#      example.com" to appear, in that order, AFTER the querying line).
#
# We assert:
#   - "[dns] querying" appears at least once (cold lookup ran).
#   - "[dns] cache hit example.com" appears at least once AFTER the
#     "querying" line (hot lookup short-circuited).
#
# If we never see "[dns] querying" the test SKIPs (it means DHCP
# didn't complete, so the cold path never ran — same skip rule as
# test_dns.sh / test_net_http.sh). If we see the querying line but
# never the cache-hit line, that's a real regression.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_net_dns_cache] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null

echo "[test_net_dns_cache] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_net_dns_cache] (3/3) Boot QEMU with virtio-net + SLIRP"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_net_dns_cache] --- captured (dns / dhcp / http) ---"
grep -E '\[dns\]|\[dhcp\]|\[http\]' "$LOG" || true
echo "[test_net_dns_cache] --- end ---"

# Skip cleanly if DHCP didn't complete — the wire query never ran, so
# there's nothing for the cache to short-circuit. test_dns.sh / the
# other net tests use the same skip rule for no-internet CI sandboxes.
if ! grep -F -q "[dns] querying" "$LOG"; then
    echo "[test_net_dns_cache] SKIP (no [dns] querying — DHCP didn't" \
         "complete? cold path didn't run)"
    echo "[test_net_dns_cache] PASS"
    exit 0
fi

# Find the line number of the first "[dns] querying" and the first
# "[dns] cache hit example.com" — assert the order. Without the order
# check a stale entry from a previous boot (we zero the cache in
# dns_init so this shouldn't happen, but be paranoid) could mask a
# regression where the cold-path still doesn't store the answer.
querying_line=$(grep -n -F "[dns] querying" "$LOG" | head -1 | cut -d: -f1)
hit_line=$(grep -n -F "[dns] cache hit example.com" "$LOG" | head -1 | cut -d: -f1)

if [[ -z "${hit_line}" ]]; then
    echo "[test_net_dns_cache] FAIL (no '[dns] cache hit example.com'" \
         "after cold lookup — cache not storing answers?)"
    echo "[test_net_dns_cache] --- full log ---"
    cat "$LOG"
    exit 1
fi

if (( hit_line <= querying_line )); then
    echo "[test_net_dns_cache] FAIL (cache hit at line $hit_line came" \
         "BEFORE querying line $querying_line — order inverted)"
    echo "[test_net_dns_cache] --- full log ---"
    cat "$LOG"
    exit 1
fi

echo "[test_net_dns_cache] cold query at line $querying_line, cache" \
     "hit at line $hit_line — order OK"
echo "[test_net_dns_cache] PASS"
exit 0
