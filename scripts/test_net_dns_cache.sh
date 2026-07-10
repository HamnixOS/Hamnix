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

. "$PROJ_ROOT/scripts/_verdict.sh"
TAG=test_net_dns_cache

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

# Three-valued gate: a starved / non-booting run emits ZERO [dns]/[dhcp]
# markers. Route the zero-marker case through the shared discriminator FIRST
# (INCONCLUSIVE on timeout/OOM, FAIL on an observed crash).
verdict_boot_gate "$TAG" "$LOG" "$rc" '\[dns\]|\[dhcp\]'

# The cold wire query never ran. Previously this SKIPed to a bogus PASS —
# a false green: the gate reported success while asserting NOTHING about
# the cache. It is now INCONCLUSIVE (we did not observe the assertion),
# never PASS. Requires real internet, so this gate is NOT in the offline
# battery; a cold path that never fires means no internet or no DHCP lease.
if ! grep -F -q "[dns] querying" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "no '[dns] querying' line — the cold DNS lookup never ran (DHCP" \
        "didn't complete, or no internet), so the cache short-circuit could" \
        "not be observed. This is NOT proof the cache works. Run online."
fi

# The cold query ran but the resolver never got an answer (no '[dns] cache
# store' / '[dns] resolved') — that is an OFFLINE runner, not a broken
# cache. Without an answer there is nothing to store and the http leg
# cannot cache-hit. INCONCLUSIVE, not FAIL.
if ! grep -F -q "[dns] cache store example.com" "$LOG" \
   && ! grep -F -q "[dns] resolved example.com" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "'[dns] querying' fired but the resolver got no answer to store" \
        "(no '[dns] cache store'/'[dns] resolved') — the wire query timed out" \
        "(no internet). The cache cannot short-circuit an answer it never got."
fi

# Find the line number of the first "[dns] querying" and the first
# "[dns] cache hit example.com" — assert the order. Without the order
# check a stale entry from a previous boot (we zero the cache in
# dns_init so this shouldn't happen, but be paranoid) could mask a
# regression where the cold-path still doesn't store the answer.
querying_line=$(grep -n -F "[dns] querying" "$LOG" | head -1 | cut -d: -f1)
hit_line=$(grep -n -F "[dns] cache hit example.com" "$LOG" | head -1 | cut -d: -f1)

if [[ -z "${hit_line}" ]]; then
    echo "[test_net_dns_cache] --- full log ---"
    cat "$LOG"
    verdict_fail "$TAG" \
        "the resolver stored an answer for example.com but the second lookup" \
        "produced no '[dns] cache hit example.com' — the cache is not storing" \
        "or not consulting answers (qemu rc=$rc). Real regression."
fi

if (( hit_line <= querying_line )); then
    echo "[test_net_dns_cache] --- full log ---"
    cat "$LOG"
    verdict_fail "$TAG" \
        "the '[dns] cache hit' at line $hit_line came BEFORE the '[dns]" \
        "querying' at line $querying_line — order inverted, the cold path" \
        "did not store before the hot path read (qemu rc=$rc). Real regression."
fi

echo "[test_net_dns_cache] cold query at line $querying_line, cache" \
     "hit at line $hit_line — order OK"
verdict_pass "$TAG" "the cold dns_lookup(example.com) stored the answer and" \
    "the subsequent lookup short-circuited on a '[dns] cache hit' (in order)"
