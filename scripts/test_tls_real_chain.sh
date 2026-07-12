#!/usr/bin/env bash
# scripts/test_tls_real_chain.sh — REAL public-internet cert-chain gate.
#
# Fetches the LIVE certificate chains of real public HTTPS sites, feeds the
# real DER through Hamnix's actual X.509 path validator
# (lib/x509/chain.ad::validate_cert_chain) on the x86_64-linux host target,
# and asserts each chain validates (rc=1) to a BAKED-IN production trust
# anchor. This is genuine real-world DER + real CA signatures exercised
# through the same code the in-kernel TLS client (drivers/net/tls.ad) runs.
#
# Anchors baked (identical to _tls_validation_init() in drivers/net/tls.ad):
#   - ISRG Root X1        (Let's Encrypt)          -> host /etc/ssl/certs
#   - DigiCert Global Root G2                      -> tests/fixtures/*.der
#
# Sites (each rooted at one of the baked anchors):
#   - valid-isrgrootx1.letsencrypt.org  RSA v1.5 SHA-256 -> ISRG Root X1
#   - www.debian.org                    RSA v1.5 SHA-256 -> ISRG Root X1  (apt)
#   - www.digicert.com                  RSA v1.5 SHA-256 -> DigiCert G2
#   - www.microsoft.com                 RSA v1.5 SHA-384 -> DigiCert G2   (v8)
#
# If the host has no outbound TLS egress (CI sandbox), the gate SKIPs
# (exit 0) — the OFFLINE sha256/384/512 dispatch is guarded deterministically
# by scripts/test_tls_rsa_sigalg.sh, and ECDSA/P-384 chains (github, ietf,
# google) are a documented gap (no P-384 curve yet).
#
# PASS criterion: at least one real chain validated AND zero validated-FAIL.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

HOSTS=(valid-isrgrootx1.letsencrypt.org www.debian.org www.digicert.com www.microsoft.com)
OUT="build/host"
TMP="$(mktemp -d -t hamnix-realchain-XXXXXX)"
FIX="tests/_real_chain_live.ad"
BIN="$OUT/test_real_chain_live"
mkdir -p "$OUT"
cleanup() { rm -rf "$TMP" "$FIX"; }
trap cleanup EXIT

ISRG_PEM="/etc/ssl/certs/ISRG_Root_X1.pem"
DG2_DER="tests/fixtures/digicert_global_root_g2.der"

# --- anchors: emit DER to temp files ---------------------------------------
ANCHOR_ISRG="$TMP/isrg_x1.der"
ANCHOR_DG2="$TMP/digicert_g2.der"
have_isrg=0
if [[ -f "$ISRG_PEM" ]] && openssl x509 -in "$ISRG_PEM" -outform DER -out "$ANCHOR_ISRG" 2>/dev/null; then
    have_isrg=1
fi
cp "$DG2_DER" "$ANCHOR_DG2"

# --- fetch live chains ------------------------------------------------------
declare -a GOT_HOSTS
for h in "${HOSTS[@]}"; do
    pem="$TMP/$h.pem"
    if echo | timeout 20 openssl s_client -connect "$h:443" -servername "$h" \
            -showcerts 2>/dev/null > "$pem" && grep -q "BEGIN CERTIFICATE" "$pem"; then
        GOT_HOSTS+=("$h")
        echo "[real] fetched chain: $h"
    else
        echo "[real] no egress / fetch failed: $h (skipping)"
    fi
done

if [[ ${#GOT_HOSTS[@]} -eq 0 ]]; then
    echo "[real] SKIP: no outbound TLS egress (offline dispatch guarded by test_tls_rsa_sigalg.sh)"
    exit 0
fi

# --- generate the host fixture from the fetched DER ------------------------
python3 - "$TMP" "$have_isrg" "$ANCHOR_ISRG" "$ANCHOR_DG2" "$FIX" "${GOT_HOSTS[@]}" <<'PYEOF'
import sys, time, os, re
from cryptography import x509
from cryptography.hazmat.primitives import serialization

tmp, have_isrg, anchor_isrg, anchor_dg2, out = sys.argv[1:6]
hosts = sys.argv[6:]
have_isrg = have_isrg == "1"

def split_pem(path):
    blocks = []
    cur = []
    for line in open(path):
        if "BEGIN CERTIFICATE" in line:
            cur = [line]
        elif "END CERTIFICATE" in line:
            cur.append(line)
            blocks.append("".join(cur)); cur = []
        elif cur:
            cur.append(line)
    out = []
    for b in blocks:
        try:
            out.append(x509.load_pem_x509_certificate(b.encode()))
        except Exception:
            pass
    return out

def der(c): return c.public_bytes(serialization.Encoding.DER)

anchors = [("anchor_dg2", open(anchor_dg2,"rb").read())]
if have_isrg:
    anchors.insert(0, ("anchor_isrg", open(anchor_isrg,"rb").read()))

now = int(time.time())
blobs = []
host_chain = {}
for h in hosts:
    certs = split_pem(f"{tmp}/{h}.pem")
    # drop a trailing self-signed root the server may have sent
    if certs and certs[-1].subject == certs[-1].issuer:
        certs = certs[:-1]
    tag = re.sub(r'[^a-z0-9]', '_', h)
    names = []
    for i, c in enumerate(certs):
        nm = f"c_{tag}_{i}"
        blobs.append((nm, der(c))); names.append(nm)
    host_chain[h] = names

for nm, b in blobs + anchors:
    if len(b) > 4096:
        raise SystemExit(f"cert {nm} too big: {len(b)}")

def emit_init(nm, b):
    L = [f"def _init_{nm}():"]
    for i, x in enumerate(b):
        L.append(f"    {nm}[{i}] = 0x{x:02X}")
    L.append("")
    return "\n".join(L)

P = ['''# GENERATED live real-chain fixture (transient; DO NOT COMMIT)
from lib.asn1.asn1 import (asn1_init_oids,)
from lib.x509.x509 import (X509Cert, x509_parse,)
from lib.ec.p256 import (p256_init,)
from lib.rsa.rsa import (rsa_init,)
from lib.ecdsa.ecdsa import (ecdsa_init,)
from lib.x509.chain import (castore_init, castore_add_root, castore_count, validate_cert_chain,)

extern def sys_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64

def _strlen(s: Ptr[uint8]) -> uint64:
    n: uint64 = 0
    while s[n] != 0:
        n = n + 1
    return n

def _wstr(s: Ptr[uint8]):
    sys_write(1, s, _strlen(s))

def _wdec(value: uint64):
    if value == 0:
        sys_write(1, "0", 1)
        return
    digits: Array[24, uint8]
    n: uint64 = 0
    v: uint64 = value
    while v != 0:
        digits[n] = cast[uint8](v % 10) + 48
        v = v / 10
        n = n + 1
    out: Array[24, uint8]
    i: uint64 = 0
    while n > 0:
        n = n - 1
        out[i] = digits[n]
        i = i + 1
    sys_write(1, &out[0], i)

ok_count: int32 = 0
fail_count: int32 = 0
chain_ptrs: Array[8, Ptr[uint8]]
chain_lens: Array[8, uint64]
''']

for nm, b in blobs + anchors:
    P.append(f"{nm}: Array[4096, uint8]")
    P.append(f"{nm}_len: uint64 = {len(b)}")
P.append(f"NOW_REAL: uint64 = {now}")
P.append("")
for nm, b in blobs + anchors:
    P.append(emit_init(nm, b))
P.append("def _init_all():")
for nm, _ in blobs + anchors:
    P.append(f"    _init_{nm}()")
P.append("")

for h in hosts:
    names = host_chain[h]
    tag = re.sub(r'[^a-z0-9]', '_', h)
    L = [f"def _check_{tag}():"]
    L.append(f'    _wstr("[real] {h} (chain of {len(names)}) ")')
    if not names:
        L.append('    _wstr("no-certs SKIP\\n")')
        L.append("")
        P.append("\n".join(L)); continue
    for i, nm in enumerate(names):
        L.append(f"    chain_ptrs[{i}] = &{nm}[0]")
        L.append(f"    chain_lens[{i}] = {nm}_len")
    L.append(f'    rc: int32 = validate_cert_chain(&chain_ptrs[0], &chain_lens[0], cast[int32]({len(names)}), "{h}", NOW_REAL)')
    L.append('    _wstr("rc=")')
    L.append('    _wdec(cast[uint64](cast[int64](rc) & 0xff))')
    L.append('    if rc == 1:')
    L.append('        _wstr(" OK\\n")')
    L.append('        ok_count = ok_count + 1')
    L.append('    else:')
    L.append('        _wstr(" FAIL(want 1)\\n")')
    L.append('        fail_count = fail_count + 1')
    L.append("")
    P.append("\n".join(L))

M = ['''def main() -> int32:
    _wstr("[real] start\\n")
    asn1_init_oids()
    p256_init()
    rsa_init()
    ecdsa_init()
    castore_init()
    _init_all()''']
for nm, _ in anchors:
    M.append(f"    castore_add_root(&{nm}[0], {nm}_len)")
M.append('    _wstr("[real] anchors=")')
M.append('    _wdec(cast[uint64](cast[int64](castore_count()) & 0xff))')
M.append('    _wstr("\\n")')
for h in hosts:
    tag = re.sub(r'[^a-z0-9]', '_', h)
    M.append(f"    _check_{tag}()")
M.append('''    _wstr("[real] validated=")
    _wdec(cast[uint64](cast[int64](ok_count) & 0xff))
    _wstr(" failed=")
    _wdec(cast[uint64](fail_count))
    _wstr("\\n")
    if fail_count == 0:
        if ok_count > 0:
            _wstr("[real] PASS\\n")
            return 0
        _wstr("[real] SKIP (no chains)\\n")
        return 0
    _wstr("[real] FAIL\\n")
    return 1''')
P.append("\n".join(M))

open(out, "w").write("\n".join(P) + "\n")
print(f"[real] fixture: {len(blobs)} certs, {len(anchors)} anchors, now={now}")
PYEOF

if [[ ! -f "$FIX" ]]; then
    echo "[real] FAIL: fixture generation failed"; exit 1
fi

echo "[real] compiling live fixture for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux "$FIX" -o "$BIN" 2>"$OUT/real_compile.log"; then
    echo "[real] FAIL: fixture did not compile"; cat "$OUT/real_compile.log"; exit 1
fi

DUMP="$OUT/real_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[real] FAIL: fixture exited non-zero"; cat "$DUMP"; exit 1
fi
cat "$DUMP"

if grep -Fq "[real] FAIL" "$DUMP"; then
    echo "[real] FAIL: a real chain did not validate"; exit 1
fi
if grep -Fq "[real] PASS" "$DUMP"; then
    echo "[real] PASS"
    exit 0
fi
if grep -Fq "[real] SKIP" "$DUMP"; then
    echo "[real] SKIP (no chains reached)"
    exit 0
fi
echo "[real] FAIL: no verdict marker"
exit 1
