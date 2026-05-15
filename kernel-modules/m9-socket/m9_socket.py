# Pynux M9.3: a kernel UDP socket bound to port 9999.
#
# sock_create_kern → kernel_bind to a Pynux-constructed sockaddr_in →
# sock_release. After load, the bound socket is briefly visible to the
# kernel (until release). Demonstrates Pynux participating directly as
# a network endpoint via the kernel socket API.

extern def sock_create_kern(net: Ptr[uint8], family: int32, type: int32,
                            protocol: int32, res: Ptr[uint8]) -> int32
extern def sock_release(sock: Ptr[uint8])
extern def kernel_bind(sock: Ptr[uint8], addr: Ptr[uint8],
                       addrlen: int32) -> int32
extern def memset(dst: Ptr[uint8], v: int32, n: uint64) -> Ptr[uint8]
extern def init_net() -> int32
extern def _printk(fmt: str, val: int32) -> int32


# struct sockaddr_in (16 bytes)
#   sin_family u16 @ 0     AF_INET = 2
#   sin_port   u16 @ 2     network byte order
#   sin_addr   u32 @ 4     network byte order (0 = INADDR_ANY)
#   pad        8 bytes @ 8
class SockaddrIn:
    sin_family: int16              # 0
    sin_port:   int16              # 2
    sin_addr:   int32              # 4
    pad:        Array[8, uint8]    # 8..16


AF_INET_VAL:     int32 = 2
SOCK_DGRAM_VAL:  int32 = 2
IPPROTO_UDP_VAL: int32 = 17

# htons(9999): 9999 = 0x270F → byte-swapped = 0x0F27
PORT_9999_BE: int16 = 0x0F27

pynux_sa: SockaddrIn


def init_module() -> int32:
    sock: Ptr[uint8] = 0
    rc: int32 = sock_create_kern(init_net, AF_INET_VAL, SOCK_DGRAM_VAL,
                                  IPPROTO_UDP_VAL, &sock)
    _printk("[SOCK] sock_create_kern rc = %d\n", rc)
    if rc != 0:
        return rc

    memset(&pynux_sa, 0, 16)
    pynux_sa.sin_family = AF_INET_VAL
    pynux_sa.sin_port = PORT_9999_BE
    # sin_addr stays 0 = INADDR_ANY

    bind_rc: int32 = kernel_bind(sock, &pynux_sa, 16)
    _printk("[SOCK] kernel_bind rc = %d\n", bind_rc)

    sock_release(sock)
    _printk("[SOCK] released\n", 0)
    return 0


def cleanup_module():
    _printk("[SOCK] unregistered\n", 0)
