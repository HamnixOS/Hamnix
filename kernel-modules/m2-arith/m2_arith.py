# Pynux M2.0 use site: function with parameter, local variables, while
# loop, if statement, and binary arithmetic — every feature M2.0 added to
# the x86_64 codegen.
#
# Computes 1+2+...+10 = 55 and prints it via _printk. init_module returns
# 0 only if the computed sum matches the expected value.

extern def _printk(fmt: str, val: int32) -> int32


def sum_to(n: int32) -> int32:
    s: int32 = 0
    i: int32 = 1
    while i <= n:
        s = s + i
        i = i + 1
    return s


def init_module() -> int32:
    total: int32 = sum_to(10)
    _printk("[M2-ARITH] sum 1..10 = %d\n", total)
    if total == 55:
        _printk("[M2-ARITH] PASS\n", 0)
        return 0
    _printk("[M2-ARITH] FAIL\n", 0)
    return -1


def cleanup_module():
    _printk("[M2-ARITH] cleanup\n", 0)
