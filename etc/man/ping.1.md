# ping - send ICMP echo requests

## NAME

ping - probe a host with ICMP echo

## SYNOPSIS

    ping <host>

## DESCRIPTION

Sends ICMP echo-request packets to `<host>` via the `/net/icmp`
file tree (Plan 9 shape — no `socket()` API). Resolves `<host>`
through the kernel's DNS via `/net/dns` if it is not already a
dotted-quad address.

Hamnix's ping is the native Adder implementation in
`user/ping.ad`. It does not require root or any capability; the
kernel rate-limits.

## EXAMPLES

    ping 1.1.1.1
    ping 255.one

## SEE ALSO

ifconfig(1), dns(1), route(1)
