# Support Libraries (`lib/`)

> **Source of truth:** `lib/` (all subdirs)
> **Last verified against source:** 2026-06-10

## Purpose

Shared Adder libraries used across the kernel and userland: the 9P codec,
the crypto/PKI stack (TLS, SSH, secure boot, password hashing), the
compression codecs, and a software-Vulkan rasterizer. Each subdir is a
self-contained module (usually a single `.ad`).

## Key files

| Path | Role |
|--|--|
| `lib/9p/9p.ad` | 9P2000 wire codec (T/R message encode/decode) — see [../9p.md](../9p.md) |
| `lib/bigint/bigint.ad` | arbitrary-precision integers (RSA/EC math) |
| `lib/sha2/sha2.ad` | SHA-256/512 |
| `lib/crypt/sha512_crypt.ad` | `$6$` SHA-512 crypt for `/etc/shadow` |
| `lib/passwd/passwd.ad` + `shadow.ad` | passwd/shadow parsing |
| `lib/rsa/rsa.ad` | RSA |
| `lib/ec/p256.ad` | NIST P-256 curve |
| `lib/ecdsa/ecdsa.ad` | ECDSA signatures |
| `lib/asn1/asn1.ad` | ASN.1 DER |
| `lib/x509/x509.ad` + `chain.ad` | X.509 certs + chain validation |
| `lib/pgp/pgp.ad` | OpenPGP (package signing) |
| `lib/secureboot/authenticode.ad` | Authenticode / secure-boot blob verification |
| `lib/ssh/sshcrypto.ad` + `sshsign.ad` | SSH crypto + host/user key signing (for `user/sshd.ad`) |
| `lib/zlib/inflate.ad` | DEFLATE/zlib inflate (gzip, `.deb` data) |
| `lib/xz/xz.ad` | XZ/LZMA decompression |
| `lib/vk/vk_core.ad`, `vk_raster.ad`, `vk_selftest.ad`, `vk_window_demo.ad` | software-Vulkan core + rasterizer (GPU-track baseline; the DE's native software-raster path) |

## Architecture & data structures

These are leaf libraries — they expose codec/crypto entry functions
consumed elsewhere:

- **9P** (`lib/9p/9p.ad`) backs both the kernel 9P client
  (`sys/src/9/port/9p_client.ad`) and userland file servers
  (`user/distrofs.ad`). See [../9p.md](../9p.md) for the wire format.
- **Crypto/PKI** powers TLS 1.3 (`drivers/net/tls.ad`), SSH
  (`user/sshd.ad`), `hpm` package signature verification
  ([../packages.md](../packages.md)), `/etc/shadow` auth
  ([../security.md](../security.md)), and secure boot.
- **Compression** (`zlib`, `xz`) is used by the package manager, `.deb`
  extraction, and squashfs.
- **`lib/vk/`** is a software Vulkan/rasterizer — the native software-
  raster baseline for the desktop (NOT lavapipe); the GPU track builds on
  it. This subdir is the thinnest-documented here (see index coverage
  gaps).

## Entry points

Each library exposes its own API (grep the cited `.ad` for `def`). The
load-bearing consumers are: `lib/9p/9p.ad` ↔ 9P client/servers,
`lib/sha2` + `lib/crypt` ↔ auth, `lib/x509`/`lib/rsa`/`lib/ecdsa` ↔ TLS,
`lib/zlib`/`lib/xz` ↔ packages/squashfs, `lib/vk/*` ↔ the compositor.

## Invariants & gotchas

- These are pure leaf libraries — keep them free of kernel/namespace
  assumptions so both kernel and userland can link them.
- `lib/vk/` is the GPU baseline: native-first software rasterizer; the DE
  never needs the Linux namespace for graphics (Intel silicon via the
  L-shim `i915.ko` is a later phase — project memory).

## Related docs

- [../9p.md](../9p.md) — the wire format `lib/9p` implements.
- [../security.md](../security.md), [../packages.md](../packages.md) — crypto consumers.
- [networking.md](networking.md) — TLS consumer.
- [userland-de.md](userland-de.md) — the compositor that uses `lib/vk`.
