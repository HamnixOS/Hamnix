#!/usr/bin/env python3
# scripts/gen_tls_rsa_sigalg_fixture.py
#
# Generates tests/test_tls_rsa_sigalg_chain.ad: a deterministic regression
# for the PKCS#1 v1.5 signature-algorithm dispatch added alongside the
# baked DigiCert Global Root G2 anchor. It builds three real 3-level RSA
# chains (root -> intermediate -> leaf) that differ only in the signature
# hash, and drives lib/x509/chain.ad::validate_cert_chain over each:
#
#   (1) sha256WithRSAEncryption chain ............. validate => 1
#   (2) sha384WithRSAEncryption chain ............. validate => 1  (NEW)
#   (3) sha512WithRSAEncryption chain ............. validate => 1  (NEW)
#   (4) sha384 chain, leaf signature bit-flipped .. validate => 0  (NEW)
#
# Case (2) mirrors the real www.microsoft.com chain, which signs every
# certificate with SHA-384; case (1) mirrors the real Let's Encrypt /
# www.digicert.com SHA-256 chains. The chains are self-consistent (the
# root is the trust anchor), so no live network is needed — this guards
# the OID + digest dispatch offline, complementing the live-internet gate
# in scripts/test_tls_real_chain.sh.
#
# The RSA keys are generated once (here) and the resulting DER is embedded
# in the checked-in fixture, so CI never regenerates keys. Validity is a
# fixed 2026-01-01 .. 2036-01-01 window with now = 2026-06-01, matching
# tests/test_x509_chain_policy.ad. Re-run this script to regenerate.

import datetime
import os

from cryptography import x509
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests", "test_tls_rsa_sigalg_chain.ad")

NB = datetime.datetime(2026, 1, 1, 0, 0, 0, tzinfo=datetime.timezone.utc)
NA = datetime.datetime(2036, 1, 1, 0, 0, 0, tzinfo=datetime.timezone.utc)
NOW_GOOD = int(datetime.datetime(2026, 6, 1, 0, 0, 0,
                                 tzinfo=datetime.timezone.utc).timestamp())


def name(cn):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


SAN_CN = "sigalg.hamnix.local"


def gen_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def build_chain(halg, tag):
    """root -> inter -> leaf, all signed with hash `halg`. Returns (root_der,
    inter_der, leaf_der)."""
    root_key = gen_key()
    inter_key = gen_key()
    leaf_key = gen_key()
    root_dn = name(f"Hamnix SigAlg {tag} Root CA")
    inter_dn = name(f"Hamnix SigAlg {tag} Intermediate CA")
    leaf_dn = name(SAN_CN)

    root = (x509.CertificateBuilder()
            .subject_name(root_dn).issuer_name(root_dn)
            .public_key(root_key.public_key()).serial_number(0x01)
            .not_valid_before(NB).not_valid_after(NA)
            .add_extension(x509.BasicConstraints(ca=True, path_length=None),
                           critical=True)
            .add_extension(x509.KeyUsage(
                digital_signature=False, content_commitment=False,
                key_encipherment=False, data_encipherment=False,
                key_agreement=False, key_cert_sign=True, crl_sign=True,
                encipher_only=False, decipher_only=False), critical=True)
            .sign(root_key, halg))

    inter = (x509.CertificateBuilder()
             .subject_name(inter_dn).issuer_name(root_dn)
             .public_key(inter_key.public_key()).serial_number(0x02)
             .not_valid_before(NB).not_valid_after(NA)
             .add_extension(x509.BasicConstraints(ca=True, path_length=0),
                            critical=True)
             .add_extension(x509.KeyUsage(
                 digital_signature=False, content_commitment=False,
                 key_encipherment=False, data_encipherment=False,
                 key_agreement=False, key_cert_sign=True, crl_sign=True,
                 encipher_only=False, decipher_only=False), critical=True)
             .sign(root_key, halg))

    leaf = (x509.CertificateBuilder()
            .subject_name(leaf_dn).issuer_name(inter_dn)
            .public_key(leaf_key.public_key()).serial_number(0x03)
            .not_valid_before(NB).not_valid_after(NA)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None),
                           critical=True)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(SAN_CN)]),
                           critical=False)
            .add_extension(x509.KeyUsage(
                digital_signature=True, content_commitment=False,
                key_encipherment=True, data_encipherment=False,
                key_agreement=False, key_cert_sign=False, crl_sign=False,
                encipher_only=False, decipher_only=False), critical=True)
            .add_extension(x509.ExtendedKeyUsage(
                [ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .sign(inter_key, halg))

    d = serialization.Encoding.DER
    return (root.public_bytes(d), inter.public_bytes(d), leaf.public_bytes(d))


r256, i256, l256 = build_chain(hashes.SHA256(), "SHA256")
r384, i384, l384 = build_chain(hashes.SHA384(), "SHA384")
r512, i512, l512 = build_chain(hashes.SHA512(), "SHA512")

CERTS = [
    ("root256_der", r256), ("inter256_der", i256), ("leaf256_der", l256),
    ("root384_der", r384), ("inter384_der", i384), ("leaf384_der", l384),
    ("root512_der", r512), ("inter512_der", i512), ("leaf512_der", l512),
]
for nm, b in CERTS:
    assert len(b) <= 2048, f"{nm} too big: {len(b)}"


def emit_init(nm, b):
    out = [f"def _init_{nm}():"]
    for i, x in enumerate(b):
        out.append(f"    {nm}[{i}] = 0x{x:02X}")
    out.append("")
    return "\n".join(out)


HEADER = '''# tests/test_tls_rsa_sigalg_chain.ad
#
# GENERATED by scripts/gen_tls_rsa_sigalg_fixture.py — DO NOT EDIT BY HAND.
#
# Deterministic PKCS#1 v1.5 signature-algorithm dispatch regression for
# lib/x509/chain.ad. Three real RSA-2048 root->inter->leaf chains signed
# respectively with sha256/sha384/sha512WithRSAEncryption, plus a tamper
# case. Case (2) mirrors the real www.microsoft.com SHA-384 chain that
# now validates to the baked DigiCert Global Root G2 anchor.
#
# Runs on the x86_64-linux host target (no QEMU) via
# scripts/test_tls_rsa_sigalg.sh. Asserts `[sigalg] PASS`.

from lib.asn1.asn1 import (asn1_init_oids,)
from lib.x509.x509 import (X509Cert, x509_parse,)
from lib.ec.p256 import (p256_init,)
from lib.rsa.rsa import (rsa_init,)
from lib.ecdsa.ecdsa import (ecdsa_init,)
from lib.x509.chain import (
    castore_init, castore_add_root, castore_remove_all, castore_count,
    validate_cert_chain,
)

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


fail_count: int32 = 0


def _expect(rc: int32, want: int32, label: Ptr[uint8]):
    _wstr("[sigalg] ")
    _wstr(label)
    _wstr(" rc=")
    _wdec(cast[uint64](cast[int64](rc) & 0xff))
    if rc == want:
        _wstr(" OK\\n")
    else:
        _wstr(" FAIL want=")
        _wdec(cast[uint64](cast[int64](want) & 0xff))
        _wstr("\\n")
        fail_count = fail_count + 1


chain_ptrs: Array[8, Ptr[uint8]]
chain_lens: Array[8, uint64]
'''


def emit():
    P = [HEADER, ""]
    for nm, b in CERTS:
        P.append(f"{nm}: Array[2048, uint8]")
        P.append(f"{nm}_len: uint64 = {len(b)}")
    P.append(f"NOW_GOOD: uint64 = {NOW_GOOD}")
    P.append("")
    for nm, b in CERTS:
        P.append(emit_init(nm, b))
    P.append("def _init_all():")
    for nm, _ in CERTS:
        P.append(f"    _init_{nm}()")
    P.append("")
    P.append(MAIN)
    open(OUT, "w").write("\n".join(P) + "\n")
    print("wrote", OUT)
    for nm, b in CERTS:
        print(f"  {nm}: {len(b)} bytes")


MAIN = '''def _validate2(leaf: Ptr[uint8], leaf_len: uint64,
               inter: Ptr[uint8], inter_len: uint64,
               host: Ptr[char], now_unix: uint64) -> int32:
    chain_ptrs[0] = leaf
    chain_lens[0] = leaf_len
    chain_ptrs[1] = inter
    chain_lens[1] = inter_len
    return validate_cert_chain(&chain_ptrs[0], &chain_lens[0],
                               cast[int32](2), host, now_unix)


def _run(root: Ptr[uint8], root_len: uint64,
         inter: Ptr[uint8], inter_len: uint64,
         leaf: Ptr[uint8], leaf_len: uint64, want: int32,
         label: Ptr[uint8]):
    castore_remove_all()
    slot: int32 = castore_add_root(root, root_len)
    if slot < 0:
        _wstr("[sigalg] ")
        _wstr(label)
        _wstr(" FAIL: castore_add_root rejected root\\n")
        fail_count = fail_count + 1
        return
    rc: int32 = _validate2(leaf, leaf_len, inter, inter_len,
                           "sigalg.hamnix.local", NOW_GOOD)
    _expect(rc, want, label)


def main() -> int32:
    _wstr("[sigalg] start\\n")
    asn1_init_oids()
    p256_init()
    rsa_init()
    ecdsa_init()
    castore_init()
    _init_all()

    _run(&root256_der[0], root256_der_len,
         &inter256_der[0], inter256_der_len,
         &leaf256_der[0], leaf256_der_len, 1, "(1) sha256WithRSA chain")

    _run(&root384_der[0], root384_der_len,
         &inter384_der[0], inter384_der_len,
         &leaf384_der[0], leaf384_der_len, 1, "(2) sha384WithRSA chain")

    _run(&root512_der[0], root512_der_len,
         &inter512_der[0], inter512_der_len,
         &leaf512_der[0], leaf512_der_len, 1, "(3) sha512WithRSA chain")

    # (4) Tamper the SHA-384 leaf signature: flip a byte well inside the
    # trailing signatureValue BIT STRING -> must reject (0), NOT -1.
    flip_at: uint64 = leaf384_der_len - 4
    saved: uint8 = leaf384_der[flip_at]
    leaf384_der[flip_at] = saved ^ 0x01
    _run(&root384_der[0], root384_der_len,
         &inter384_der[0], inter384_der_len,
         &leaf384_der[0], leaf384_der_len, 0, "(4) tampered sha384 leaf")
    leaf384_der[flip_at] = saved

    _wstr("[sigalg] failures=")
    _wdec(cast[uint64](fail_count))
    _wstr("\\n")
    if fail_count == 0:
        _wstr("[sigalg] PASS\\n")
        return 0
    _wstr("[sigalg] FAIL\\n")
    return 1
'''


if __name__ == "__main__":
    emit()
