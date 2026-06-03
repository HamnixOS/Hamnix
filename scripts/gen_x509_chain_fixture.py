#!/usr/bin/env python3
# scripts/gen_x509_chain_fixture.py
#
# Generates tests/test_x509_chain_policy.ad: a deterministic RFC 5280 §6.1
# path-validation policy regression for lib/x509/chain.ad. We build a real
# 3-level ECDSA-P256 chain (root CA -> intermediate CA -> leaf) plus a set
# of crafted negative-case certificates, emit them all as DER byte-dumps
# into an Adder fixture, and drive lib/x509/chain.ad::validate_cert_chain
# over each, asserting the verdict.
#
# Determinism: all EC keys are derived from fixed 32-byte scalars (no RNG),
# and every notBefore/notAfter is a fixed timestamp, so the emitted DER is
# byte-stable across runs. Re-running this script must produce an identical
# fixture (modulo the cryptography lib version's DER encoder, which is
# itself stable).
#
# The fixture is checked in (Adder top-level Array literals don't survive to
# the linked image, so each cert is replayed via an _init_*()-style runtime
# fill — same shape as tests/test_chain_validate.ad). Re-run this script to
# regenerate after changing the cases.
#
# Cases (all asserted in tests/test_x509_chain_policy.ad::main):
#   (1) legitimate root->inter->leaf chain ......... validate => 1
#   (2) leaf signature bit-flipped ................. validate => 0
#   (3) wrong host ................................. validate => 0
#   (4) now past leaf notAfter (expired) .......... validate => 0
#   (5) empty CA store ............................. validate => 0
#   (6) intermediate is NOT a CA (cA=FALSE) ....... validate => 0
#   (7) intermediate lacks keyUsage keyCertSign ... validate => 0
#   (8) leaf carries an unknown CRITICAL extension  validate => 0
#   (9) leaf EKU lacks serverAuth (clientAuth only) validate => 0
#  (10) leaf issuer DN doesn't match inter subject  validate => 0
#  (11) pathLenConstraint=0 violated by an inter ... validate => 0
#
# Most negative cases reject BEFORE any signature verify, so they cost no EC
# math; only the legitimate case (1) and the bit-flip case (2) drive full
# ECDSA-P256 verifies. That keeps the QEMU runtime within budget.

import datetime
import os

from cryptography import x509
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID, ObjectIdentifier
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests", "test_x509_chain_policy.ad")

# Fixed validity window: certs valid 2026-01-01 .. 2036-01-01 UTC.
NB = datetime.datetime(2026, 1, 1, 0, 0, 0, tzinfo=datetime.timezone.utc)
NA = datetime.datetime(2036, 1, 1, 0, 0, 0, tzinfo=datetime.timezone.utc)
# A target "now" inside the window (2026-06-01 00:00:00 UTC).
NOW_GOOD = int(datetime.datetime(2026, 6, 1, 0, 0, 0,
                                 tzinfo=datetime.timezone.utc).timestamp())
# A "now" past notAfter (2036-06-01).
NOW_EXPIRED = int(datetime.datetime(2036, 6, 1, 0, 0, 0,
                                    tzinfo=datetime.timezone.utc).timestamp())


def key_from_scalar(n: int) -> ec.EllipticCurvePrivateKey:
    """Deterministic P-256 private key from a fixed scalar."""
    return ec.derive_private_key(n, ec.SECP256R1())


# Fixed scalars for each key (arbitrary but constant).
K_ROOT = 0x1111111111111111111111111111111111111111111111111111111111111111
K_INTER = 0x2222222222222222222222222222222222222222222222222222222222222222
K_LEAF = 0x3333333333333333333333333333333333333333333333333333333333333333
K_INTER2 = 0x4444444444444444444444444444444444444444444444444444444444444444

root_key = key_from_scalar(K_ROOT)
inter_key = key_from_scalar(K_INTER)
leaf_key = key_from_scalar(K_LEAF)
inter2_key = key_from_scalar(K_INTER2)


def name(cn: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


ROOT_DN = name("Hamnix Policy Test Root CA")
INTER_DN = name("Hamnix Policy Test Intermediate CA")
LEAF_CN = "policy.hamnix.local"
LEAF_DN = name(LEAF_CN)
OTHER_DN = name("Hamnix Policy OTHER Intermediate CA")

SAN = x509.SubjectAlternativeName([x509.DNSName(LEAF_CN)])

# Fixed serials (deterministic).
S_ROOT = 0x01
S_INTER = 0x02
S_LEAF = 0x03


def build_root():
    b = (x509.CertificateBuilder()
         .subject_name(ROOT_DN).issuer_name(ROOT_DN)
         .public_key(root_key.public_key())
         .serial_number(S_ROOT)
         .not_valid_before(NB).not_valid_after(NA)
         .add_extension(x509.BasicConstraints(ca=True, path_length=None),
                        critical=True)
         .add_extension(x509.KeyUsage(
             digital_signature=False, content_commitment=False,
             key_encipherment=False, data_encipherment=False,
             key_agreement=False, key_cert_sign=True, crl_sign=True,
             encipher_only=False, decipher_only=False), critical=True))
    return b.sign(root_key, hashes.SHA256())


def build_inter(*, ca=True, key_cert_sign=True, path_length=None,
                issuer_key=root_key, issuer_dn=ROOT_DN, subject_dn=INTER_DN,
                subject_key=inter_key, serial=S_INTER):
    b = (x509.CertificateBuilder()
         .subject_name(subject_dn).issuer_name(issuer_dn)
         .public_key(subject_key.public_key())
         .serial_number(serial)
         .not_valid_before(NB).not_valid_after(NA)
         .add_extension(x509.BasicConstraints(ca=ca, path_length=path_length),
                        critical=True)
         .add_extension(x509.KeyUsage(
             digital_signature=False, content_commitment=False,
             key_encipherment=False, data_encipherment=False,
             key_agreement=False, key_cert_sign=key_cert_sign,
             crl_sign=True, encipher_only=False, decipher_only=False),
             critical=True))
    return b.sign(issuer_key, hashes.SHA256())


def build_leaf(*, issuer_key=inter_key, issuer_dn=INTER_DN,
               not_after=NA, eku=(ExtendedKeyUsageOID.SERVER_AUTH,),
               unknown_critical=False, subject_key=leaf_key, serial=S_LEAF):
    b = (x509.CertificateBuilder()
         .subject_name(LEAF_DN).issuer_name(issuer_dn)
         .public_key(subject_key.public_key())
         .serial_number(serial)
         .not_valid_before(NB).not_valid_after(not_after)
         .add_extension(x509.BasicConstraints(ca=False, path_length=None),
                        critical=True)
         .add_extension(SAN, critical=False)
         .add_extension(x509.KeyUsage(
             digital_signature=True, content_commitment=False,
             key_encipherment=False, data_encipherment=False,
             key_agreement=False, key_cert_sign=False, crl_sign=False,
             encipher_only=False, decipher_only=False), critical=True))
    if eku is not None:
        b = b.add_extension(x509.ExtendedKeyUsage(list(eku)), critical=False)
    if unknown_critical:
        # An extension OID we don't process, marked critical -> must reject.
        # 1.3.6.1.4.1.99999.1 is in a private arc; harmless content.
        b = b.add_extension(
            x509.UnrecognizedExtension(
                ObjectIdentifier("1.3.6.1.4.1.99999.1"), b"\x01\x02\x03"),
            critical=True)
    return b.sign(issuer_key, hashes.SHA256())


def der(cert) -> bytes:
    return cert.public_bytes(serialization.Encoding.DER)


# ---- Build all certs -------------------------------------------------------
root_cert = build_root()
inter_cert = build_inter()
leaf_cert = build_leaf()

# Negative-case intermediates / leaves (signatures are valid where it
# matters; the policy check is what must reject them).
inter_nonca = build_inter(ca=False)                       # case 6
inter_no_kcs = build_inter(key_cert_sign=False)           # case 7
leaf_unknown_crit = build_leaf(unknown_critical=True)     # case 8
leaf_clientauth = build_leaf(eku=(ExtendedKeyUsageOID.CLIENT_AUTH,))  # case 9
# case 10: leaf issued by an intermediate whose SUBJECT DN differs from what
# the leaf names as issuer. We build a leaf that claims issuer=OTHER_DN but
# we present the real INTER cert in the chain -> DN mismatch, no parent found.
leaf_wrong_issuer = build_leaf(issuer_key=inter_key, issuer_dn=OTHER_DN)

# case 11: root sets pathLenConstraint=0, meaning zero intermediates may
# appear below it. We build a 3-cert chain root->inter(pathlen-bounded)->leaf
# that violates it: an intermediate signed by a pathlen=0 root.
root_pl0 = build_inter(ca=True, key_cert_sign=True, path_length=0,
                       issuer_key=root_key, issuer_dn=ROOT_DN,
                       subject_dn=ROOT_DN, subject_key=root_key,
                       serial=0x10)
# inter2 signed by the pathlen=0 root, then a leaf under inter2: that places
# one intermediate below the pathlen=0 CA -> violation.
inter_under_pl0 = build_inter(ca=True, key_cert_sign=True,
                              issuer_key=root_key, issuer_dn=ROOT_DN,
                              subject_dn=INTER_DN, subject_key=inter2_key,
                              serial=0x11)
leaf_under_pl0 = build_leaf(issuer_key=inter2_key, issuer_dn=INTER_DN,
                            serial=0x12)

CERTS = [
    ("root_der", der(root_cert)),
    ("inter_der", der(inter_cert)),
    ("leaf_der", der(leaf_cert)),
    ("inter_nonca_der", der(inter_nonca)),
    ("inter_nokcs_der", der(inter_no_kcs)),
    ("leaf_uncrit_der", der(leaf_unknown_crit)),
    ("leaf_clientauth_der", der(leaf_clientauth)),
    ("leaf_wrongissuer_der", der(leaf_wrong_issuer)),
    ("root_pl0_der", der(root_pl0)),
    ("inter_under_pl0_der", der(inter_under_pl0)),
    ("leaf_under_pl0_der", der(leaf_under_pl0)),
]

# Sanity: every DER must fit the parser's caps (cert <= 2048; SPKI handled
# upstream). Our certs are all small ECDSA certs (~400-550 bytes).
for nm, blob in CERTS:
    assert len(blob) <= 2048, f"{nm} too big: {len(blob)}"


def emit_cert_init(nm: str, blob: bytes) -> str:
    lines = [f"def _init_{nm}():"]
    for i, b in enumerate(blob):
        lines.append(f"    {nm}[{i}] = 0x{b:02X}")
    lines.append("")
    return "\n".join(lines)


HEADER = '''# tests/test_x509_chain_policy.ad
#
# GENERATED by scripts/gen_x509_chain_fixture.py — DO NOT EDIT BY HAND.
# Re-run that script to regenerate after changing the test cases.
#
# Deterministic RFC 5280 §6.1 path-validation policy regression for the
# native X.509 chain validator (lib/x509/chain.ad + lib/x509/x509.ad).
# A real ECDSA-P256 root->intermediate->leaf chain is generated by the
# Python `cryptography` lib from fixed key scalars, so the DER is stable.
#
# Asserts (all pass => `[x509-chain] PASS`):
#   (1) legitimate root->inter->leaf chain ......... validate => 1
#   (2) leaf signature bit-flipped ................. validate => 0
#   (3) wrong host ................................. validate => 0
#   (4) now past leaf notAfter (expired) ........... validate => 0
#   (5) empty CA store ............................. validate => 0
#   (6) intermediate is NOT a CA (cA=FALSE) ........ validate => 0
#   (7) intermediate lacks keyUsage keyCertSign .... validate => 0
#   (8) leaf carries an unknown CRITICAL extension . validate => 0
#   (9) leaf EKU lacks serverAuth (clientAuth only)  validate => 0
#  (10) leaf issuer DN != intermediate subject DN .. validate => 0
#  (11) pathLenConstraint=0 violated by an inter ... validate => 0
#
# Driven by scripts/test_x509_chain_policy.sh.

from lib.asn1.asn1 import (
    asn1_init_oids,
)
from lib.x509.x509 import (
    X509Cert,
    x509_parse,
)
from lib.ec.p256 import (
    p256_init,
)
from lib.rsa.rsa import (
    rsa_init,
)
from lib.ecdsa.ecdsa import (
    ecdsa_init,
)
from lib.x509.chain import (
    castore_init,
    castore_add_root,
    castore_remove_all,
    castore_count,
    validate_cert_chain,
)

extern def sys_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64
extern def sys_exit(code: uint64)


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


def _wdec_signed(value: int64):
    if value < 0:
        sys_write(1, "-", 1)
        _wdec(cast[uint64](-value))
        return
    _wdec(cast[uint64](value))


fail_count: int32 = 0


def _check_eq_i32(a: int32, b: int32, label: Ptr[uint8]):
    if a != b:
        _wstr("[x509-chain] FAIL: ")
        _wstr(label)
        _wstr(" got=")
        _wdec_signed(cast[int64](a))
        _wstr(" want=")
        _wdec_signed(cast[int64](b))
        _wstr("\\n")
        fail_count = fail_count + 1


chain_ptrs: Array[8, Ptr[uint8]]
chain_lens: Array[8, uint64]
'''


def emit():
    parts = [HEADER, ""]
    # Declare each Array + its length global.
    for nm, blob in CERTS:
        parts.append(f"{nm}: Array[1024, uint8]")
        parts.append(f"{nm}_len: uint64 = {len(blob)}")
    parts.append("")
    # Constants.
    parts.append(f"NOW_GOOD: uint64 = {NOW_GOOD}")
    parts.append(f"NOW_EXPIRED: uint64 = {NOW_EXPIRED}")
    parts.append("")
    # Per-cert init fns.
    for nm, blob in CERTS:
        parts.append(emit_cert_init(nm, blob))
    # _init_all().
    parts.append("def _init_all():")
    for nm, _ in CERTS:
        parts.append(f"    _init_{nm}()")
    parts.append("")
    # main().
    parts.append(MAIN)
    text = "\n".join(parts)
    if not text.endswith("\n"):
        text += "\n"
    with open(OUT, "w") as f:
        f.write(text)
    print(f"wrote {OUT}")
    for nm, blob in CERTS:
        print(f"  {nm}: {len(blob)} bytes")


MAIN = '''
def _validate1(leaf: Ptr[uint8], leaf_len: uint64,
               host: Ptr[char], now_unix: uint64) -> int32:
    chain_ptrs[0] = leaf
    chain_lens[0] = leaf_len
    return validate_cert_chain(&chain_ptrs[0], &chain_lens[0],
                               cast[int32](1), host, now_unix)


def _validate2(leaf: Ptr[uint8], leaf_len: uint64,
               inter: Ptr[uint8], inter_len: uint64,
               host: Ptr[char], now_unix: uint64) -> int32:
    chain_ptrs[0] = leaf
    chain_lens[0] = leaf_len
    chain_ptrs[1] = inter
    chain_lens[1] = inter_len
    return validate_cert_chain(&chain_ptrs[0], &chain_lens[0],
                               cast[int32](2), host, now_unix)


def main() -> int32:
    _wstr("[x509-chain] start\\n")

    asn1_init_oids()
    p256_init()
    rsa_init()
    ecdsa_init()
    castore_init()
    _init_all()

    # Seed the CA store with the real root.
    slot: int32 = castore_add_root(&root_der[0], root_der_len)
    _check_eq_i32(slot, 0, "castore_add_root root -> slot 0")
    _check_eq_i32(castore_count(), 1, "castore_count == 1")

    # (1) Legitimate leaf+inter chain (root from store). Drives 2 ECDSA
    # verifies (~10s in QEMU).
    _wstr("[x509-chain] case 1: legitimate chain (ecdsa verify ~10s)\\n")
    rc: int32 = _validate2(&leaf_der[0], leaf_der_len,
                           &inter_der[0], inter_der_len,
                           "policy.hamnix.local", NOW_GOOD)
    _check_eq_i32(rc, 1, "(1) legitimate chain => 1")

    # (2) Bit-flip the leaf signature. Offset chosen inside the trailing
    # ECDSA signature SEQUENCE (last 8 bytes are well within `s`).
    flip_at: uint64 = leaf_der_len - 4
    saved: uint8 = leaf_der[flip_at]
    leaf_der[flip_at] = saved ^ 0x01
    _wstr("[x509-chain] case 2: leaf sig bit-flipped\\n")
    rc = _validate2(&leaf_der[0], leaf_der_len,
                    &inter_der[0], inter_der_len,
                    "policy.hamnix.local", NOW_GOOD)
    _check_eq_i32(rc, 0, "(2) flipped leaf sig => 0")
    leaf_der[flip_at] = saved

    # (3) Wrong host.
    _wstr("[x509-chain] case 3: wrong host\\n")
    rc = _validate2(&leaf_der[0], leaf_der_len,
                    &inter_der[0], inter_der_len,
                    "evil.hamnix.local", NOW_GOOD)
    _check_eq_i32(rc, 0, "(3) wrong host => 0")

    # (4) Expired (now past notAfter). Rejects at leaf validity, pre-verify.
    _wstr("[x509-chain] case 4: expired leaf\\n")
    rc = _validate2(&leaf_der[0], leaf_der_len,
                    &inter_der[0], inter_der_len,
                    "policy.hamnix.local", NOW_EXPIRED)
    _check_eq_i32(rc, 0, "(4) expired leaf => 0")

    # (6) Intermediate is NOT a CA (cA=FALSE). Rejects at issuer policy,
    # pre-verify.
    _wstr("[x509-chain] case 6: non-CA intermediate\\n")
    rc = _validate2(&leaf_der[0], leaf_der_len,
                    &inter_nonca_der[0], inter_nonca_der_len,
                    "policy.hamnix.local", NOW_GOOD)
    _check_eq_i32(rc, 0, "(6) non-CA intermediate => 0")

    # (7) Intermediate lacks keyCertSign. Rejects at issuer policy.
    _wstr("[x509-chain] case 7: intermediate without keyCertSign\\n")
    rc = _validate2(&leaf_der[0], leaf_der_len,
                    &inter_nokcs_der[0], inter_nokcs_der_len,
                    "policy.hamnix.local", NOW_GOOD)
    _check_eq_i32(rc, 0, "(7) inter without keyCertSign => 0")

    # (8) Leaf carries an unknown CRITICAL extension. Rejects at leaf policy.
    _wstr("[x509-chain] case 8: leaf unknown critical extension\\n")
    rc = _validate2(&leaf_uncrit_der[0], leaf_uncrit_der_len,
                    &inter_der[0], inter_der_len,
                    "policy.hamnix.local", NOW_GOOD)
    _check_eq_i32(rc, 0, "(8) leaf unknown critical ext => 0")

    # (9) Leaf EKU is clientAuth only (no serverAuth). Rejects at leaf policy.
    _wstr("[x509-chain] case 9: leaf EKU without serverAuth\\n")
    rc = _validate2(&leaf_clientauth_der[0], leaf_clientauth_der_len,
                    &inter_der[0], inter_der_len,
                    "policy.hamnix.local", NOW_GOOD)
    _check_eq_i32(rc, 0, "(9) leaf EKU without serverAuth => 0")

    # (10) Leaf issuer DN doesn't match intermediate subject DN. No parent
    # found in the chain -> reject.
    _wstr("[x509-chain] case 10: issuer/subject DN mismatch\\n")
    rc = _validate2(&leaf_wrongissuer_der[0], leaf_wrongissuer_der_len,
                    &inter_der[0], inter_der_len,
                    "policy.hamnix.local", NOW_GOOD)
    _check_eq_i32(rc, 0, "(10) DN mismatch => 0")

    # (11) pathLenConstraint=0 root, with a leaf under an intermediate
    # below it (one intermediate => violates pathlen 0). Reject.
    # Re-seed the CA store with the pathlen=0 root.
    castore_remove_all()
    pslot: int32 = castore_add_root(&root_pl0_der[0], root_pl0_der_len)
    _check_eq_i32(pslot, 0, "(11) pathlen-root add => slot 0")
    _wstr("[x509-chain] case 11: pathLenConstraint=0 violated\\n")
    chain_ptrs[0] = &leaf_under_pl0_der[0]
    chain_lens[0] = leaf_under_pl0_der_len
    chain_ptrs[1] = &inter_under_pl0_der[0]
    chain_lens[1] = inter_under_pl0_der_len
    rc = validate_cert_chain(&chain_ptrs[0], &chain_lens[0],
                             cast[int32](2),
                             "policy.hamnix.local", NOW_GOOD)
    _check_eq_i32(rc, 0, "(11) pathLenConstraint=0 violated => 0")

    # Restore the normal root for the (5) empty-store case ordering clarity.
    castore_remove_all()

    # (5) Empty CA store -> no anchor -> reject (even the legitimate chain).
    _wstr("[x509-chain] case 5: empty CA store\\n")
    _check_eq_i32(castore_count(), 0, "(5) castore empty")
    rc = _validate2(&leaf_der[0], leaf_der_len,
                    &inter_der[0], inter_der_len,
                    "policy.hamnix.local", NOW_GOOD)
    _check_eq_i32(rc, 0, "(5) empty CA store => 0")

    _wstr("[x509-chain] failures=")
    _wdec(cast[uint64](fail_count))
    _wstr("\\n")
    if fail_count == 0:
        _wstr("[x509-chain] PASS\\n")
        return 0
    _wstr("[x509-chain] FAIL\\n")
    return 1
'''


if __name__ == "__main__":
    emit()
