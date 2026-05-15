# Pynux M5.3: a netfilter hook that sees every IPv4 packet entering the
# host (NF_INET_PRE_ROUTING).
#
# A Pynux hook function with the strict (void *priv, struct sk_buff *skb,
# const struct nf_hook_state *state) -> unsigned int contract is
# registered against init_net. The hook just counts packets and returns
# NF_ACCEPT. /init brings eth0 up via DHCP-via-SLIRP traffic and pings
# the gateway so PRE_ROUTING fires.
#
# Pure-Pynux participation in the kernel's networking pipeline.

extern def nf_register_net_hook(net: Ptr[uint8], ops: Ptr[uint8]) -> int32
extern def nf_unregister_net_hook(net: Ptr[uint8], ops: Ptr[uint8])
extern def init_net() -> int32          # global struct net (symbol address)
extern def _printk(fmt: str, val: int32) -> int32


# struct nf_hook_ops (40 bytes, probed for 6.12.48)
class NfHookOps:
    hook:      Ptr[uint8]          # 0
    dev:       Ptr[uint8]          # 8
    priv:      Ptr[uint8]          # 16
    pf:        int32               # 24 (u8 with 3-byte alignment hole)
    hooknum:   uint32              # 28
    priority:  int32               # 32
    pad_end:   int32               # 36..40


NFPROTO_IPV4_VAL:        int32 = 2
NF_INET_PRE_ROUTING_VAL: uint32 = 0
NF_ACCEPT_VAL:           uint32 = 1

pynux_nf_ops:    NfHookOps
pynux_nf_count:  int32


def pynux_nf_hook(priv: Ptr[uint8], skb: Ptr[uint8],
                  state: Ptr[uint8]) -> uint32:
    pynux_nf_count = pynux_nf_count + 1
    return NF_ACCEPT_VAL


def init_module() -> int32:
    pynux_nf_ops.hook = pynux_nf_hook
    pynux_nf_ops.pf = NFPROTO_IPV4_VAL
    pynux_nf_ops.hooknum = NF_INET_PRE_ROUTING_VAL
    pynux_nf_ops.priority = 0
    rc: int32 = nf_register_net_hook(init_net, &pynux_nf_ops)
    _printk("[NF] register rc = %d\n", rc)
    return rc


def cleanup_module():
    nf_unregister_net_hook(init_net, &pynux_nf_ops)
    _printk("[NF] packet count = %d\n", pynux_nf_count)
    _printk("[NF] unregistered\n", 0)
