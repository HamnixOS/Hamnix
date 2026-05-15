# Pynux M7.3: SHA-256 via the kernel crypto API.
#
# crypto_alloc_shash("sha256", ...) returns a shash transform; the
# crypto_shash_tfm_digest one-shot helper computes the digest of a
# buffer in one call (no shash_desc to construct). The first four
# bytes of SHA-256("hello") are 0x2c 0xf2 0x4d 0xba (the canonical
# 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824).

extern def crypto_alloc_shash(name: Ptr[char], type: uint32,
                              mask: uint32) -> Ptr[uint8]
# crypto_free_shash is inline; call crypto_destroy_tfm directly.
extern def crypto_destroy_tfm(mem: Ptr[uint8], tfm: Ptr[uint8])
extern def crypto_shash_tfm_digest(tfm: Ptr[uint8], data: Ptr[uint8],
                                   len: uint32, out: Ptr[uint8]) -> int32
extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def memset(dst: Ptr[uint8], v: int32, n: uint64) -> Ptr[uint8]
extern def _printk(fmt: str, val: int32) -> int32


pynux_digest: Array[32, uint8]


def init_module() -> int32:
    tfm: Ptr[uint8] = crypto_alloc_shash("sha256", 0, 0)
    if tfm == 0:
        _printk("[CRYPTO] crypto_alloc_shash FAILED\n", 0)
        return -12

    memset(&pynux_digest, 0, 32)
    rc: int32 = crypto_shash_tfm_digest(tfm, "hello", 5, &pynux_digest)
    _printk("[CRYPTO] digest rc = %d\n", rc)

    b0: int32 = 0
    memcpy(&b0, &pynux_digest, 1)
    b1: int32 = 0
    memcpy(&b1, &pynux_digest + 1, 1)
    b2: int32 = 0
    memcpy(&b2, &pynux_digest + 2, 1)
    b3: int32 = 0
    memcpy(&b3, &pynux_digest + 3, 1)
    _printk("[CRYPTO] sha256(hello)[0] = 0x%x\n", b0)
    _printk("[CRYPTO] sha256(hello)[1] = 0x%x\n", b1)
    _printk("[CRYPTO] sha256(hello)[2] = 0x%x\n", b2)
    _printk("[CRYPTO] sha256(hello)[3] = 0x%x\n", b3)

    # crypto_free_shash(tfm) is `crypto_destroy_tfm(tfm, crypto_shash_tfm(tfm))`.
    # crypto_shash_tfm returns the underlying crypto_tfm — itself just the
    # base pointer since struct crypto_shash starts with struct crypto_tfm.
    crypto_destroy_tfm(tfm, tfm)
    return 0


def cleanup_module():
    _printk("[CRYPTO] unregistered\n", 0)
