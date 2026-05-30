# host - DNS lookup utility

## NAME

host - resolve a hostname to an address, or an address to a name

## SYNOPSIS

    host <name>
    host <a.b.c.d>

## DESCRIPTION

`host` queries the kernel's DNS resolver (`drivers/net/dns.ad`) over
UDP/53 against the DHCP-supplied DNS server. There is no `socket()`
API — the resolver runs in the kernel and `host` reaches it through
two narrow native syscalls.

With a name argument it performs a forward A-record lookup
(`SYS_RESOLVE`) and prints the resolved IPv4 address:

    <name> has address <a.b.c.d>

With a dotted-quad argument it performs a reverse PTR lookup
(`SYS_RESOLVE_PTR`) and prints the hostname:

    <a.b.c.d> domain name pointer <name>

It is the native Adder implementation in `user/host.ad`. The same
forward path backs name resolution in ping(1), curl(1) and wget(1).

## EXAMPLES

    host example.com
    host 10.0.2.3

## SEE ALSO

ping(1), ifconfig(1), route(1)
