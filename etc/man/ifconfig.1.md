# ifconfig - inspect or configure network interfaces

## NAME

ifconfig - print the live network config (and override it)

## SYNOPSIS

    ifconfig
    ifconfig <iface> <ip> netmask <mask>
    ifconfig gw  <gateway-ip>
    ifconfig dns <resolver-ip>

## DESCRIPTION

With no argument, `ifconfig` dumps the current network state:
interface, IP/netmask, gateway, DNS, and whether the config was
DHCP-assigned or statically pinned.

With arguments, `ifconfig` writes a static override to the
kernel's network state. Hamnix runs DHCP at boot by default; the
static path is for the corner case where DHCP doesn't work
(certain real-hardware PHY/MAC chips).

There is no `socket()` API on Hamnix; network I/O is mediated
through the `/net` file tree (Plan 9 shape).

## EXAMPLES

    ifconfig
    ifconfig eth0 10.250.10.99 netmask 255.255.255.0
    ifconfig gw  10.250.10.1
    ifconfig dns 1.1.1.1

## SEE ALSO

ping(1), route(1), dns(1)
