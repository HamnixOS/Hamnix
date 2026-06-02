#!/usr/bin/env python3
"""scripts/gen_secureboot_blob.py — task #171 (Part B test fixtures).

Generates the Secure Boot self-test artifacts consumed by
lib/secureboot/authenticode.ad (planted into the initramfs by
scripts/build_initramfs.py under ENABLE_EFI_TEST=1):

  secureboot-anchor   DER of a freshly-generated self-signed RSA-2048
                      cert. This is BOTH the signer cert and the embedded
                      trust anchor.
  secureboot-pe-good  a minimal valid PE32+ image + trailer
                      [u32 LE pe_len][u32 LE sig_len][sig], where `sig`
                      = RSASSA-PKCS1-v1.5-SHA256 over the Authenticode
                      image hash of the pe_len-byte PE portion.
  secureboot-pe-bad   identical, but one .text byte is flipped, so the
                      Authenticode digest no longer matches `sig`.

The Authenticode image hash (Microsoft "Calculating the PE Image Hash"):
SHA-256 over the whole PE file EXCEPT the 4-byte optional-header CheckSum
field and the 8-byte Certificate Table data-directory entry (index 4).
Since the test PE carries no real attribute certificate table, hashing
only the pe_len-byte PE portion (minus those two holes) is the complete,
spec-faithful digest the kernel verifier recomputes.

Keys are generated fresh on every build so nothing secret is committed;
the verifier trusts ONLY the embedded anchor it was handed, so a fresh
key per build is exactly the intended trust model.

The signature is over SHA256(authenticode_digest): the kernel verifier
calls rsa_pkcs1_v1_5_verify(message=authenticode_digest), which hashes
its message argument internally. We mirror that here by signing the
32-byte digest with PKCS1v15+SHA256.
"""

import struct
import hashlib

from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
import datetime


def _gen_keypair_and_cert():
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, u"Hamnix SecureBoot Test"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, u"Hamnix"),
    ])
    now = datetime.datetime(2020, 1, 1)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(0x171171)
        .not_valid_before(now)
        .not_valid_after(datetime.datetime(2099, 1, 1))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None),
                       critical=True)
        .sign(key, hashes.SHA256())
    )
    der = cert.public_bytes(serialization.Encoding.DER)
    return key, der


def _build_minimal_pe():
    """Build a minimal-but-valid PE32+ image with a CheckSum field and a
    Certificate Table data-directory entry. Returns (pe_bytes,
    text_byte_offset) where text_byte_offset points at a .text byte the
    'bad' fixture can flip.

    Layout:
      0x00  DOS header (64 bytes), e_lfanew @0x3C -> 0x40
      0x40  "PE\0\0"
      0x44  COFF file header (20 bytes)
      0x58  optional header (PE32+): magic 0x20B ... CheckSum @ +64,
            NumberOfRvaAndSizes @ +108 = 16, data dirs @ +112 (16*8=128).
            Certificate Table entry = dir index 4 -> +112+32 = +144.
            optional header size = 112 + 128 = 240.
      0x148 section table (1 section header, 40 bytes)
      0x200 .text section raw data (file-aligned)
    """
    SECT_ALIGN = 0x1000
    FILE_ALIGN = 0x200

    dos = bytearray(0x40)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 0x40)  # e_lfanew

    pe_sig = b"PE\x00\x00"

    # COFF file header (20 bytes).
    machine = 0x8664              # IMAGE_FILE_MACHINE_AMD64
    num_sections = 1
    opt_hdr_size = 240
    characteristics = 0x0022      # EXECUTABLE | LARGE_ADDRESS_AWARE
    coff = struct.pack("<HHIIIHH",
                       machine, num_sections,
                       0,        # TimeDateStamp
                       0,        # PointerToSymbolTable
                       0,        # NumberOfSymbols
                       opt_hdr_size,
                       characteristics)

    # Section data.
    text = bytes(range(256)) * 2          # 512 bytes of deterministic data
    text_rawsize = len(text)
    text_rawptr = FILE_ALIGN              # 0x200
    text_va = SECT_ALIGN                  # 0x1000

    headers_end = 0x148 + 40              # after the 1 section header
    size_of_headers = (headers_end + FILE_ALIGN - 1) & ~(FILE_ALIGN - 1)
    size_of_image = (text_va + text_rawsize + SECT_ALIGN - 1) & ~(SECT_ALIGN - 1)

    # Optional header (PE32+). Fields up to data directories.
    opt = bytearray(opt_hdr_size)
    struct.pack_into("<H", opt, 0, 0x20B)        # Magic = PE32+
    opt[2] = 14                                   # MajorLinkerVersion
    opt[3] = 0                                     # MinorLinkerVersion
    struct.pack_into("<I", opt, 4, text_rawsize)  # SizeOfCode
    # 8 SizeOfInitializedData / 12 SizeOfUninitializedData -> 0
    struct.pack_into("<I", opt, 16, text_va)      # AddressOfEntryPoint
    struct.pack_into("<I", opt, 20, text_va)      # BaseOfCode
    struct.pack_into("<Q", opt, 24, 0x140000000)  # ImageBase (PE32+)
    struct.pack_into("<I", opt, 32, SECT_ALIGN)   # SectionAlignment
    struct.pack_into("<I", opt, 36, FILE_ALIGN)   # FileAlignment
    struct.pack_into("<H", opt, 40, 6)            # MajorOSVersion
    struct.pack_into("<H", opt, 48, 6)            # MajorSubsystemVersion
    struct.pack_into("<I", opt, 56, size_of_image)
    struct.pack_into("<I", opt, 60, size_of_headers)
    # CheckSum @ +64 -- left 0 here; Authenticode skips it anyway.
    struct.pack_into("<I", opt, 64, 0)
    struct.pack_into("<H", opt, 68, 10)           # Subsystem = EFI_APPLICATION
    struct.pack_into("<H", opt, 70, 0)            # DllCharacteristics
    struct.pack_into("<Q", opt, 72, 0x100000)     # SizeOfStackReserve
    struct.pack_into("<Q", opt, 80, 0x1000)       # SizeOfStackCommit
    struct.pack_into("<Q", opt, 88, 0x100000)     # SizeOfHeapReserve
    struct.pack_into("<Q", opt, 96, 0x1000)       # SizeOfHeapCommit
    struct.pack_into("<I", opt, 108, 16)          # NumberOfRvaAndSizes
    # Data directories start at +112 (16 entries * 8 bytes).
    # Certificate Table = index 4 -> +112 + 4*8 = +144. Point it at a
    # nominal location past the PE portion (the real test trailer is
    # appended later; the kernel skips these 8 bytes regardless).
    struct.pack_into("<II", opt, 144, 0, 0)       # cert table RVA/size = 0

    # Section header (40 bytes) for ".text".
    sect = bytearray(40)
    sect[0:5] = b".text"
    struct.pack_into("<I", sect, 8, text_rawsize)   # VirtualSize
    struct.pack_into("<I", sect, 12, text_va)       # VirtualAddress
    struct.pack_into("<I", sect, 16, text_rawsize)  # SizeOfRawData
    struct.pack_into("<I", sect, 20, text_rawptr)   # PointerToRawData
    struct.pack_into("<I", sect, 36, 0x60000020)    # CODE|EXEC|READ

    out = bytearray()
    out += dos
    out += pe_sig
    out += coff
    out += opt
    out += sect
    # Pad to text_rawptr.
    assert len(out) <= text_rawptr, (len(out), text_rawptr)
    out += b"\x00" * (text_rawptr - len(out))
    text_file_off = len(out)
    out += text

    return bytes(out), text_file_off


def _authenticode_digest(pe: bytes) -> bytes:
    """Recompute the Authenticode SHA-256 image hash exactly as the kernel
    verifier does: hash the whole PE EXCEPT the 4-byte CheckSum field and
    the 8-byte Certificate Table data-directory entry."""
    e_lfanew = struct.unpack_from("<I", pe, 0x3C)[0]
    assert pe[e_lfanew:e_lfanew + 4] == b"PE\x00\x00"
    opt = e_lfanew + 24
    cksum_off = opt + 64
    certdir_off = opt + 144
    h = hashlib.sha256()
    i = 0
    n = len(pe)
    while i < n:
        if cksum_off <= i < cksum_off + 4:
            i += 1
            continue
        if certdir_off <= i < certdir_off + 8:
            i += 1
            continue
        h.update(pe[i:i + 1])
        i += 1
    return h.digest()


def build_secureboot_fixtures():
    """Returns dict: {'secureboot-anchor': bytes,
                      'secureboot-pe-good': bytes,
                      'secureboot-pe-bad': bytes}."""
    key, anchor_der = _gen_keypair_and_cert()
    pe, text_off = _build_minimal_pe()

    # GOOD: sign the Authenticode digest of the pristine PE.
    digest = _authenticode_digest(pe)
    # Sign SHA256(digest): rsa_pkcs1_v1_5_verify hashes its message arg,
    # and our message IS `digest`, so the signature must be over
    # SHA256(digest). PKCS1v15 + SHA256 over `digest` does exactly that.
    sig = key.sign(digest, padding.PKCS1v15(), hashes.SHA256())

    def assemble(pe_bytes, sig_bytes):
        trailer = struct.pack("<II", len(pe_bytes), len(sig_bytes))
        return pe_bytes + sig_bytes + trailer

    good = assemble(pe, sig)

    # BAD: flip one .text byte (the PE changes -> digest changes ->
    # the SAME signature no longer verifies). Trailer keeps the SAME
    # pe_len/sig_len so the verifier walks it identically; only the hash
    # differs.
    pe_bad = bytearray(pe)
    pe_bad[text_off] ^= 0xFF
    bad = assemble(bytes(pe_bad), sig)

    return {
        "secureboot-anchor": anchor_der,
        "secureboot-pe-good": good,
        "secureboot-pe-bad": bad,
    }


if __name__ == "__main__":
    # Standalone self-check: prove the in-Python verifier accepts good +
    # rejects bad, so a build failure here is caught before the kernel run.
    fx = build_secureboot_fixtures()
    cert = x509.load_der_x509_certificate(fx["secureboot-anchor"])
    pub = cert.public_key()

    def verify(blob):
        pe_len, sig_len = struct.unpack("<II", blob[-8:])
        pe = blob[:pe_len]
        sig = blob[pe_len:pe_len + sig_len]
        digest = _authenticode_digest(pe)
        try:
            pub.verify(sig, digest, padding.PKCS1v15(), hashes.SHA256())
            return True
        except Exception:
            return False

    assert verify(fx["secureboot-pe-good"]), "good blob failed self-check"
    assert not verify(fx["secureboot-pe-bad"]), "bad blob unexpectedly verified"
    print("[gen_secureboot_blob] self-check OK: good accepted, bad rejected")
    for name, data in fx.items():
        print(f"[gen_secureboot_blob]   {name}: {len(data)} bytes")
