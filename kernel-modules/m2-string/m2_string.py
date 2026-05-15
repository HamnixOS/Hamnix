# Pynux M2.1 use site: pointer parameters and indexing. The print_chars
# function takes a Ptr[char] + length and loops byte-by-byte, exercising
# IndexExpr load (movzbq) on a 1-byte element type, then printing each
# ord value via _printk.

extern def _printk(fmt: str, c: int32) -> int32


def print_chars(s: Ptr[char], n: int32):
    i: int32 = 0
    while i < n:
        c: int32 = s[i]
        _printk("[M2-STR] byte=%d\n", c)
        i = i + 1


def init_module() -> int32:
    # "ABCDE" is a Ptr[char] (RIP-relative address of an interned literal).
    print_chars("ABCDE", 5)
    return 0


def cleanup_module():
    _printk("[M2-STR] cleanup\n", 0)
