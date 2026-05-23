#!/usr/bin/env python3
"""
scripts/build_initramfs.py — generates a cpio "newc" archive for the
bare-metal Hamnix initramfs and emits it as a .S file of .byte
directives that the kernel image .incbin-includes.

cpio newc layout (per cpio(5)):
  Each entry: 110-byte ASCII header + name + pad-to-4 + data + pad-to-4
  Header fields (each 8 chars of uppercase hex, except magic which is 6):
    magic    "070701"
    ino, mode, uid, gid, nlink, mtime, filesize,
    devmajor, devminor, rdevmajor, rdevminor, namesize, check
  Padding is from the START of the entry; both name and data end
  4-byte aligned.

Final entry: a special "TRAILER!!!" file with size 0 marks end-of-
archive. Linux's init/initramfs.c looks for exactly this string.

Re-run this script after touching the FILES list to regenerate
fs/initramfs_blob.S (which is committed; assembly happens at build
time without re-running this script).
"""

import os
from pathlib import Path

FILES = [
    ("/motd",       b"Welcome to Hamnix from a real cpio initramfs!\n"
                    b"This file came out of a newc-formatted blob.\n"),
    ("/version",    b"Hamnix bare-metal kernel, M16.30 - ELF /init loader\n"),
]

# Optional opt-in markers controlled by env vars. Used by per-test
# harness scripts to enable kernel-side smoke tests that would
# otherwise hang/regress unrelated test runs. See
# scripts/test_net_https.sh which sets ENABLE_TLS_SMOKE=1 to plant
# `/etc/tls-test`; init/main.ad gates `https_local_smoke_test()` on
# that file's presence.
if os.environ.get("ENABLE_TLS_SMOKE") == "1":
    FILES.append(("/etc/tls-test", b"1\n"))

# Chunked-transfer-encoding decoder smoke. See
# scripts/test_net_https_chunked.sh; the harness sets
# ENABLE_TLS_CHUNKED_SMOKE=1 to plant /etc/tls-chunked-test, and
# init/main.ad's https_chunked_smoke_test gates on that file.
if os.environ.get("ENABLE_TLS_CHUNKED_SMOKE") == "1":
    FILES.append(("/etc/tls-chunked-test", b"1\n"))

# Content-Encoding: gzip wireup smoke. See
# scripts/test_net_https_gzip.sh; the harness sets
# ENABLE_TLS_GZIP_SMOKE=1 to plant /etc/tls-gzip-test, and
# init/main.ad's https_gzip_smoke_test gates on that file. The
# fixture serves a chunked+gzip body and the kernel-side smoke
# verifies the inflated bytes match the expected plaintext.
# The same env var also plants /etc/skip-https-internet-smoke so
# the unconditional https://example.com leg in net_smoke_test
# doesn't fire (the current baseline traps mid-TLS-handshake on
# the AES-256-GCM record, a separate residual that would
# otherwise kill the kernel before reaching the gzip smoke).
if os.environ.get("ENABLE_TLS_GZIP_SMOKE") == "1":
    FILES.append(("/etc/tls-gzip-test", b"1\n"))
    FILES.append(("/etc/skip-https-internet-smoke", b"1\n"))

# V5.3 TCP RX-ring multi-segment smoke. Gated the same way as
# /etc/tls-test so the kernel doesn't try to ARP / SYN 10.0.2.201
# during boot when the test_tcp_ring.sh harness isn't running —
# without the marker, an unreachable peer would stall tcp_connect
# (jiffies aren't ticking yet at net_smoke_test time, so its
# polling-loop deadline never fires). See init/main.ad's
# tcp_ring_smoke_test gate.
if os.environ.get("ENABLE_TCP_RING_SMOKE") == "1":
    FILES.append(("/etc/tcp-ring-test", b"1\n"))

# /net 9P file-tree smoke (ARCH §10). scripts/test_net_devnet.sh sets
# ENABLE_DEVNET_SMOKE=1 to plant /etc/devnet-test; init/main.ad gates
# devnet_smoke_test() (the /net/tcp/clone open + ctl connect + data
# transfer round-trip) on it. Gated for the same reason as the TCP
# ring marker above: without a guestfwd echo target the `connect` ctl
# command stalls tcp_connect, so only that one harness plants it.
if os.environ.get("ENABLE_DEVNET_SMOKE") == "1":
    FILES.append(("/etc/devnet-test", b"1\n"))

# TCP FIN_WAIT_2 timeout smoke. Gated the same way as the TLS / TCP
# ring markers above. The fixture (scripts/test_tcp_fin_wait2.sh)
# stands up a Python server that ACKs our FIN but never sends its
# own — exercising the RFC 793 §3.5 / RFC 7414 §2.17 FIN_WAIT_2
# timeout path in drivers/net/tcp.ad. Only that one harness sets
# this; other tests run without the marker (and so without an
# ARP-stall on the unreachable 10.0.2.202).
# Same defence as the gzip smoke: also plant skip-https-internet-smoke
# so the unconditional https://example.com leg in net_smoke_test
# doesn't trap on the AES-256-GCM record (separate residual; would
# otherwise kill the kernel before reaching the FW2 gate).
if os.environ.get("ENABLE_TCP_FIN_WAIT2_SMOKE") == "1":
    FILES.append(("/etc/tcp-finwait2-test", b"1\n"))
    FILES.append(("/etc/skip-https-internet-smoke", b"1\n"))

# TCP back-to-back-connect regression. Gated the same way as the TCP
# ring / FIN_WAIT_2 markers above. The fixture (scripts/test_tcp_
# reconnect.sh) boots with a guestfwd to host `cat` at 10.0.2.100:7
# and the kernel's tcp_reconnect_smoke_test fires 6 back-to-back
# connect/echo/close cycles with NO delay between them — the
# regression for the ephemeral-source-port-rotation fix in
# drivers/net/tcp.ad. Only that one harness sets this; default boot
# and other tests run without the marker.
if os.environ.get("ENABLE_TCP_RECONNECT_SMOKE") == "1":
    FILES.append(("/etc/tcp-reconnect-test", b"1\n"))

# TCP bulk-download throughput smoke. Gated the same way as the TCP
# ring / reconnect markers above. The fixture (scripts/test_net_tcp_
# throughput.sh) boots with a guestfwd to a Python blob server at
# 10.0.2.203:9200; the kernel's tcp_throughput_smoke_test drains a
# 1 MiB blob and asserts the sustained rate clears a sane floor — a
# regression guard for the TCP receive path. Only that one harness
# sets this; default boot and other tests run without it.
if os.environ.get("ENABLE_TCP_THROUGHPUT_SMOKE") == "1":
    FILES.append(("/etc/tcp-throughput-test", b"1\n"))

# DHCP renew/rebind/expiry smoke. Gated the same way as the TLS / TCP
# ring markers above. The renew smoke leaves DHCP state at IDLE on
# exit, which breaks any downstream test that requires state == BOUND
# (test_dns.sh checks `dhcp_state_get() == 3` before resolving). Only
# scripts/test_dhcp_renew.sh sets this; default boot keeps the BOUND
# lease intact. See init/main.ad's dhcp_renew_smoke_test gate.
if os.environ.get("ENABLE_DHCP_RENEW_SMOKE") == "1":
    FILES.append(("/etc/dhcp-renew-test", b"1\n"))

# SYS_NETCFG (`ifconfig`) network info + static-config smoke. Gated the
# same way as the markers above — see init/main.ad's nc_marker_found
# gate. The smoke pins a static IPv4 address / gateway / DNS, which
# stops DHCP from installing a lease, so it would break any downstream
# test that needs the DHCP-assigned 10.0.2.15. Only
# scripts/test_net_cfg.sh sets this; default boot keeps DHCP in charge.
if os.environ.get("ENABLE_NETCFG_SMOKE") == "1":
    FILES.append(("/etc/netcfg-test", b"1\n"))

# xHCI V1/V2 synthetic transfer-engine selftests. Gated the same way as
# the markers above — see init/main.ad's xhci_marker_found gate. The
# selftests forge Event-Ring state that real silicon won't agree with
# when no USB keyboard is enumerated, so default boots skip them (which
# is what real Asus / ThinkPad laptops without a USB keyboard attached
# now do — pre-marker boots were hanging in xhci_poll's MMIO-poll path).
# scripts/test_usb_hid_v1.sh and scripts/test_usb_hid_v2.sh set this to
# force the synthetic selftests to run under QEMU.
if os.environ.get("ENABLE_XHCI_SELFTEST") == "1":
    FILES.append(("/etc/xhci-selftest", b"1\n"))

# xHCI live-keyboard attach OPT-OUT. Mirrors ENABLE_XHCI_SELFTEST but
# in the opposite direction: setting ENABLE_XHCI_NO_ATTACH=1 plants
# /etc/xhci-no-attach so drivers/usb/xhci.ad's xhci_init() skips
# _xhci_v1_attach_keyboard() entirely — the controller is still
# brought up + reset + scanned, just no live SETUP / Address Device
# / GET_DESCRIPTOR / Configure Endpoint walk on the connected port.
# This is the real-hardware escape hatch for laptops where the live
# attach wedges inside an MMIO/command-ring poll (Intel Nook boot
# 2026-05 hung at [boot:01.f] xhci v1 transfer-engine bringup + attach).
# Boot then continues normally; the box just has no USB keyboard but
# the serial console / PS/2 keyboard / framebuffer prompt still work.
if os.environ.get("ENABLE_XHCI_NO_ATTACH") == "1":
    FILES.append(("/etc/xhci-no-attach", b"1\n"))

# xHCI full-skip OPT-OUT. The bigger sibling of ENABLE_XHCI_NO_ATTACH:
# setting ENABLE_XHCI_NO_INIT=1 plants /etc/xhci-no-init so
# drivers/usb/xhci.ad's xhci_init() returns immediately AFTER the
# safe PCI find/cap-read prints and BEFORE the first MMIO BAR access
# (halt/reset poll). Use this on real silicon where the MMIO load
# itself stalls the CPU — no software timeout helps because the load
# instruction never retires. Intel Nook boot 2026-05 wedged at
# [boot:01.c] xhci halt + reset; this marker lets the box boot past
# the xHCI block entirely and continue into ehci_init / start_kernel.
# Default boots do NOT ship the marker, so behavior is unchanged
# unless the user explicitly sets ENABLE_XHCI_NO_INIT=1.
if os.environ.get("ENABLE_XHCI_NO_INIT") == "1":
    FILES.append(("/etc/xhci-no-init", b"1\n"))

# Native `ping` smoke. scripts/test_ping.sh sets ENABLE_PING_SMOKE=1 to
# plant /etc/ping-smoke-test in the initramfs. The marker is consumed
# only by the test harness today (a future kernel-side autorun could
# gate on it the way ENABLE_NETCFG_SMOKE does for /etc/netcfg-test).
# Default boot omits the marker so unrelated test runs don't change
# shape.
if os.environ.get("ENABLE_PING_SMOKE") == "1":
    FILES.append(("/etc/ping-smoke-test", b"1\n"))

# HTTP 3xx redirect-follow smoke. Gated the same way as the markers
# above. scripts/test_net_http_redirect.sh stands up a Python HTTP
# server that 302s to a same-host /final endpoint serving "hello";
# init/main.ad's http_redirect_smoke_test exercises the kernel's
# redirect-follow loop end-to-end. Default boot omits the marker so
# unrelated test runs don't try to reach 10.0.2.200:80.
if os.environ.get("ENABLE_HTTP_REDIRECT_SMOKE") == "1":
    FILES.append(("/etc/http-redirect-test", b"1\n"))
    # The unconditional https://example.com leg in net_smoke_test
    # traps mid-handshake on the AES-256-GCM record (separate
    # residual; same defence the gzip/finwait2 markers apply); skip
    # it so the kernel reaches the redirect smoke below.
    FILES.append(("/etc/skip-https-internet-smoke", b"1\n"))

# apt-path V0: scripts/test_dpkg_deb_x.sh generates a tiny .deb
# fixture on the host, points HAMNIX_DEB_FIXTURE at it, and this
# block plants the bytes at /tests/sample.deb inside the cpio
# initramfs so the userland `/bin/dpkg_deb` binary can extract it
# under QEMU. Off-default: an unset env var leaves the initramfs
# alone, exactly like every other gated marker above.
_DEB_FIXTURE_PATH = os.environ.get("HAMNIX_DEB_FIXTURE", "")
if _DEB_FIXTURE_PATH:
    try:
        with open(_DEB_FIXTURE_PATH, "rb") as _fdeb:
            FILES.append(("/tests/sample.deb", _fdeb.read()))
    except OSError as _e:
        raise SystemExit(
            f"HAMNIX_DEB_FIXTURE={_DEB_FIXTURE_PATH}: unreadable ({_e})")

# httpd docroot staging: scripts/test_httpd.sh sets HAMNIX_HTTPD_DOCROOT=1
# to plant a tiny static-file tree at /var/www inside the cpio initramfs
# so the userland /bin/httpd daemon has something to serve under QEMU.
# The httpd test boots with httpd as /init, binds guest port 8080, and a
# host curl drives real HTTP GETs through the in-kernel TCP stack. The
# files land at fixed cpio paths (subdirs are flattened into the path
# string — fs/cpio.ad resolves "/var/www/index.html" by exact match).
# Off-default: an unset env var leaves the initramfs alone, exactly like
# every other gated marker above.
if os.environ.get("HAMNIX_HTTPD_DOCROOT") == "1":
    FILES.append(("/var/www/index.html",
                  b"<html><body><h1>Hamnix httpd</h1>"
                  b"<p>static-file HTTP/1.0 server</p></body></html>\n"))
    FILES.append(("/var/www/hello.txt",
                  b"hello from hamnix httpd\n"))

# sshd publickey auth: scripts/test_sshd_pubkey.sh generates a
# throwaway ECDSA-P256 keypair on the host, points HAMNIX_SSH_AUTHKEYS
# at the public-key file, and this block bakes it into the cpio
# initramfs at /var/lib/ssh/authorized_keys. user/sshd.ad reads that
# path (the daemon's /var/lib/ssh namespace dir) at startup and
# authenticates a client offering the matching private key. A /var
# path tmpfs does not itself hold falls through to this cpio-baked
# entry (see the fs/vfs.ad /var dispatch note). Off-default: an unset
# env var leaves the initramfs alone, like every other gated marker.
_SSH_AUTHKEYS = os.environ.get("HAMNIX_SSH_AUTHKEYS", "")
if _SSH_AUTHKEYS:
    try:
        with open(_SSH_AUTHKEYS, "rb") as _f:
            FILES.append(("/var/lib/ssh/authorized_keys", _f.read()))
    except OSError as _e:
        raise SystemExit(
            f"HAMNIX_SSH_AUTHKEYS={_SSH_AUTHKEYS}: unreadable ({_e})")

# V5 cert validation: bake the production ISRG Root X1 anchor into the
# initramfs at /etc/tls-ca-isrg-x1.der whenever the host has it
# installed. drivers/net/tls.ad's _tls_validation_init() walks the cpio
# table for this exact path and castore_add_root's the bytes. Without
# this, no anchor is loaded and every chain fails closed.
_ISRG_HOST_PEM = "/etc/ssl/certs/ISRG_Root_X1.pem"
if os.path.exists(_ISRG_HOST_PEM):
    import subprocess
    try:
        _isrg_der = subprocess.run(
            ["openssl", "x509", "-in", _ISRG_HOST_PEM, "-outform", "DER"],
            check=True, capture_output=True,
        ).stdout
        FILES.append(("/etc/tls-ca-isrg-x1.der", _isrg_der))
    except (FileNotFoundError, subprocess.CalledProcessError):
        # openssl absent or PEM unreadable — kernel will log
        # "CA anchor absent" and refuse every real chain, which is the
        # correct fail-closed behaviour.
        pass

# Test-fixture anchor: scripts/test_net_https.sh writes a path to its
# generated Hamnix Test CA DER into TLS_CA_DER, and we plant it here.
# The kernel adds it to the CA store in addition to ISRG Root X1 so the
# fixture's server cert (signed by the test CA) validates without
# breaking real-world ISRG-signed chains.
_TLS_CA_DER_PATH = os.environ.get("TLS_CA_DER", "")
if _TLS_CA_DER_PATH:
    try:
        with open(_TLS_CA_DER_PATH, "rb") as _f:
            FILES.append(("/etc/tls-ca.der", _f.read()))
    except OSError as _e:
        raise SystemExit(
            f"TLS_CA_DER={_TLS_CA_DER_PATH}: unreadable ({_e})")

# apt chain-of-trust anchor: the userland `apt` (user/apt.ad) verifies
# the OpenPGP signature on a repository's `InRelease` against a baked
# archive signing key at /etc/apt-trusted.gpg. The blob is the raw
# bytes of `gpg --export <archive-key>` — one v4 RSA Public-Key packet,
# parsed by lib/pgp/pgp.ad. scripts/test_apt_inrelease.sh generates a
# throwaway test key, signs its fixture `Release`, and points
# APT_TRUSTED_GPG at the exported public key so apt can authenticate
# the fixture without trusting any real-world Debian key. Off-default:
# an unset env var leaves the initramfs alone, exactly like the other
# gated markers above.
_APT_TRUSTED_GPG = os.environ.get("APT_TRUSTED_GPG", "")
if _APT_TRUSTED_GPG:
    try:
        with open(_APT_TRUSTED_GPG, "rb") as _f:
            FILES.append(("/etc/apt-trusted.gpg", _f.read()))
    except OSError as _e:
        raise SystemExit(
            f"APT_TRUSTED_GPG={_APT_TRUSTED_GPG}: unreadable ({_e})")
else:
    # No test/override key supplied: bake the production Debian
    # archive keyring if the host has the `debian-archive-keyring`
    # package installed. apt then authenticates a real Debian mirror
    # out of the box. Absent it, apt simply has no anchor and reports
    # the repository as UNAUTHENTICATED (fail-loud, never fail-open).
    for _dak in (
        "/usr/share/keyrings/debian-archive-keyring.gpg",
        "/etc/apt/trusted.gpg.d/debian-archive-keyring.gpg",
    ):
        if os.path.exists(_dak):
            try:
                with open(_dak, "rb") as _f:
                    FILES.append(("/etc/apt-trusted.gpg", _f.read()))
            except OSError:
                pass
            break

# cpio capacity stress fixture: scripts/test_cpio_capacity.sh sets
# HAMNIX_CPIO_STRESS_FILES=<N> to plant N tiny synthetic files at
# /cpio-stress/file<i> inside the initramfs. This exercises fs/cpio.ad's
# NR_FILES table past the historical 192-slot cap (the table is now
# 8192 entries). The last planted file carries a recognisable payload
# so the kernel-side check can assert a file PAST index 192 was
# registered and is readable. Off-default: an unset env var leaves the
# initramfs alone, exactly like every other gated marker above.
_CPIO_STRESS_RAW = os.environ.get("HAMNIX_CPIO_STRESS_FILES", "")
if _CPIO_STRESS_RAW:
    try:
        _cpio_stress_n = int(_CPIO_STRESS_RAW)
    except ValueError:
        raise SystemExit(
            f"HAMNIX_CPIO_STRESS_FILES={_CPIO_STRESS_RAW!r}: expected an "
            f"integer file count")
    if _cpio_stress_n < 1:
        raise SystemExit(
            f"HAMNIX_CPIO_STRESS_FILES={_cpio_stress_n}: must be >= 1")
    for _i in range(_cpio_stress_n):
        # All but the last file carry a trivial payload. The last one
        # carries a distinctive marker the kernel-side test greps for,
        # proving an entry beyond the old 192 cap was indexed.
        if _i == _cpio_stress_n - 1:
            _payload = b"CPIO_STRESS_LAST_FILE_OK\n"
        else:
            _payload = b"x\n"
        FILES.append((f"/cpio-stress/file{_i}", _payload))

# See INIT_ELF handling inside build_archive(): set INIT_ELF=path to
# override which on-disk file becomes /init in the cpio archive, e.g.
# to swap in a Hamnix-compiled user binary without touching user/init.S.


def cpio_entry(name: str, data: bytes, mode: int = 0o100644) -> bytes:
    name_bytes = name.encode() + b"\0"
    header = (
        "070701"
        f"{1:08X}"                      # ino (any non-zero is fine)
        f"{mode:08X}"                   # mode (S_IFREG | 0644 by default)
        f"{0:08X}"                      # uid
        f"{0:08X}"                      # gid
        f"{1:08X}"                      # nlink
        f"{0:08X}"                      # mtime
        f"{len(data):08X}"              # filesize
        f"{0:08X}"                      # devmajor
        f"{0:08X}"                      # devminor
        f"{0:08X}"                      # rdevmajor
        f"{0:08X}"                      # rdevminor
        f"{len(name_bytes):08X}"        # namesize (incl NUL)
        f"{0:08X}"                      # check
    ).encode()
    # Pad after name so data starts 4-aligned from entry start.
    name_field_len = len(header) + len(name_bytes)
    name_pad = (-name_field_len) % 4
    # Pad after data so next entry starts 4-aligned.
    data_pad = (-len(data)) % 4
    return header + name_bytes + (b"\0" * name_pad) \
                  + data + (b"\0" * data_pad)


def cpio_symlink(name: str, target: str) -> bytes:
    # Emit a cpio entry with mode = S_IFLNK | 0777 whose data is the
    # NUL-terminated link target path. The trailing NUL is INCLUDED in
    # the entry's filesize so the in-kernel reader (fs/cpio.ad +
    # fs/vfs.ad's _lookup_name) can treat the bytes as a C-string and
    # resolve them with the same exact-match path lookup it uses for
    # regular files.
    #
    # The standard Linux cpio writer does NOT NUL-terminate symlink
    # data — it writes only the link-target bytes. Adding the NUL is
    # safe for any reader that consults `filesize` (we own the only
    # reader on the Hamnix side) and keeps the in-kernel string
    # comparator simple. It costs 1 byte per applet entry.
    payload = target.encode() + b"\0"
    return cpio_entry(name, payload, mode=0o120777)


def cpio_trailer() -> bytes:
    return cpio_entry("TRAILER!!!", b"")


def build_archive() -> bytes:
    blob = b""
    here = Path(__file__).resolve().parent.parent

    # If INIT_ELF=<path> is set, embed that file as /init (overriding
    # whatever ELF in build/user/ would otherwise have grabbed the
    # /init slot). Lets us point /init at e.g. a Hamnix-compiled
    # user/hello.elf for one run without touching user/init.S or the
    # glob below. We track which on-disk path is acting as /init so
    # the directory glob doesn't re-embed it under its native name.
    init_override = os.environ.get("INIT_ELF")
    init_override_real: Path | None = None
    if init_override:
        p = Path(init_override)
        if not p.is_absolute():
            p = here / p
        if not p.exists():
            raise SystemExit(f"INIT_ELF={init_override}: file not found")
        data = p.read_bytes()
        blob += cpio_entry("/init", data)
        init_override_real = p.resolve()
        print(f"  embedded /init ({len(data)} bytes from "
              f"{p.relative_to(here) if p.is_relative_to(here) else p}) "
              f"[INIT_ELF override]")

    # U37: busybox multi-call applet staging. The kernel's _lookup_name
    # (fs/vfs.ad) returns the FIRST cpio entry matching a path — so we
    # plant busybox-bytes at common applet paths BEFORE the build/user
    # glob lands its Adder-built shadows. Without this, busybox sh's
    # PATH walk for `echo a | grep a` finds Adder grep at /bin/grep but
    # passes Linux-ABI argv to it (mismatched), and the pipe stalls.
    # With this, busybox sh finds busybox at every PATH entry it
    # probes; busybox's own argv[0] dispatcher selects the applet.
    # The cost is ~2 MiB per applet path in the initramfs; at the
    # 256 MiB qemu budget every U-track test uses, that's affordable.
    #
    # Source: tests/u-binary/busybox (a copy of u_busybox staged by
    # the test harness). When that file isn't present (CI without
    # host busybox), this block is a no-op.
    ubin_dir_pre = here / "tests" / "u-binary"
    busybox_bytes: bytes | None = None
    bb_src = ubin_dir_pre / "busybox"
    if bb_src.is_file():
        busybox_bytes = bb_src.read_bytes()
        # Curated minimal set. The goal is to cover the names busybox
        # sh actually walks during a `echo a | grep a`-style PATH search
        # without bloating /bin so much that downstream busybox ls /bin
        # output overflows the 4 KiB user stack glibc starts with.
        # /sbin and /usr/sbin paths are first in busybox's default PATH;
        # /bin/sh + /bin/grep are the names sh's exec-fallback touches.
        # When U38 grows the execve ustack we can widen this list back
        # to a full applet roster without breaking ls /bin regressions.
        bb_applets = [
            "/bin/sh",
            "/bin/grep",
            "/sbin/grep",
            "/usr/bin/grep",
            "/usr/sbin/grep",
        ]
        for applet in bb_applets:
            blob += cpio_entry(applet, busybox_bytes)
        print(f"  staged busybox at {len(bb_applets)} applet paths "
              f"({len(bb_applets) * len(busybox_bytes)} bytes total)")

    # Userland ELFs: anything in build/user/ lands at /bin/<name>.
    # Exception: init.elf is the kernel's boot entrypoint and
    # always goes to /init (unless overridden via INIT_ELF above).
    # Everything else is found by hamsh's PATH walker.
    user_dir = here / "build" / "user"
    if user_dir.is_dir():
        for elf in sorted(user_dir.glob("*.elf")):
            if init_override_real is not None:
                if elf.resolve() == init_override_real:
                    continue          # already embedded above as /init
                if elf.name == "init.elf":
                    continue          # /init slot is taken by override
            data = elf.read_bytes()
            if elf.name == "init.elf" and init_override_real is None:
                # Default /init = the asm-built init.elf — kernel
                # reads this at boot.
                blob += cpio_entry("/init", data)
                print(f"  embedded /init ({len(data)} bytes from "
                      f"build/user/{elf.name})")
                continue
            bin_name = "/bin/" + elf.stem
            blob += cpio_entry(bin_name, data)
            print(f"  embedded {bin_name} ({len(data)} bytes from "
                  f"build/user/{elf.name})")

    # Baseline /etc files: anything in etc/ gets embedded as /etc/<name>
    # so userland (motd, hostname, future login/init scripts) can read
    # config from a Linux-conventional path without baking strings into
    # binaries. Edit etc/* and re-run this script to refresh.
    etc_dir = here / "etc"
    if etc_dir.is_dir():
        for ef in sorted(etc_dir.iterdir()):
            if ef.is_file():
                data = ef.read_bytes()
                name = "/etc/" + ef.name
                blob += cpio_entry(name, data)
                print(f"  embedded {name} ({len(data)} bytes from "
                      f"etc/{ef.name})")

    # Linux runtime shell: plant a busybox-static binary + applet
    # symlinks into the default distro tree so `enter linux { /bin/sh }`
    # finds a working shell out of the box. Without this, the default
    # `linux` namespace recipe (etc/rc.boot: bind / /var/lib/distros/
    # default) resolves /bin/sh into the distro tree at
    # /var/lib/distros/default/bin/sh — which doesn't exist, so the
    # exec returns -ENOENT before anything runs. End-game goal #3
    # ("Run non-graphical Linux binaries") starts with: the user can
    # type `enter linux { /bin/sh }` and get a shell.
    #
    # SOURCE (preference order, picked the first that works):
    #   (a) Pre-built host fixture tests/u-binary/u_busybox_musl —
    #       built once by `make -C tests/u-binary/src/musl_busybox
    #       install` and gitignored (~1 MB musl-static-PIE ET_DYN
    #       busybox, no PT_INTERP, OSABI stamped ELFOSABI_LINUX,
    #       same fixture the U29/U36/U40 tests already use). The
    #       Hamnix ELF loader knows how to run this shape.
    #   (b) (Future) build it on the fly from
    #       tests/u-binary/src/musl_busybox/ if absent — requires
    #       musl-gcc + a network round-trip to fetch the busybox
    #       upstream tarball. Skipped for now to keep the default
    #       ISO build offline-deterministic; if the host hasn't built
    #       u_busybox_musl yet, the default ISO ships WITHOUT a
    #       Linux runtime shell (back to the pre-fix behaviour),
    #       and the build prints a one-line note.
    #   (c) Host's /usr/bin/busybox (apt-installed busybox-static)
    #       — REJECTED: on Debian today this is dynamically linked
    #       (BuildID + interpreter /lib64/ld-linux-x86-64.so.2), so
    #       running it inside the hermetic distro namespace would
    #       require a full glibc tree as well. The musl-static-PIE
    #       fixture is self-contained.
    #
    # APPLETS: each applet name is planted as an S_IFLNK cpio entry
    # pointing at /var/lib/distros/default/bin/busybox. cpio_symlink()
    # below emits a mode=0o120777 entry with NUL-terminated target
    # data; fs/vfs.ad's _lookup_name follows the link to the real
    # busybox bytes. One header per applet vs ~1 MB of duplicate
    # data per applet — ~15 KB total overhead instead of ~15 MB.
    bb_src = here / "tests" / "u-binary" / "u_busybox_musl"
    if bb_src.is_file():
        bb_bytes = bb_src.read_bytes()
        bb_target = "/var/lib/distros/default/bin/busybox"
        blob += cpio_entry(bb_target, bb_bytes, mode=0o100755)
        # Curated applet list — enough for "this feels like a shell":
        # sh / ls / cat / echo / cp / mv / rm / mkdir / pwd / grep /
        # head / tail / wc / true / false / env / printf / date /
        # sleep / basename / dirname. (cd is a shell builtin and does
        # not need its own executable.) busybox itself dispatches by
        # argv[0], so a symlink at /bin/sh -> busybox runs the sh
        # applet automatically.
        bb_applets = [
            "sh", "ash",
            "ls", "cat", "echo", "cp", "mv", "rm", "mkdir",
            "pwd", "grep", "head", "tail", "wc",
            "true", "false", "env", "printf", "date",
            "sleep", "basename", "dirname",
        ]
        for applet in bb_applets:
            link = f"/var/lib/distros/default/bin/{applet}"
            blob += cpio_symlink(link, bb_target)
        print(f"  staged Linux runtime shell: busybox ({len(bb_bytes)} "
              f"bytes from {bb_src.relative_to(here)}) + "
              f"{len(bb_applets)} applet symlinks under "
              f"/var/lib/distros/default/bin/")
    else:
        print(f"  WARN: {bb_src.relative_to(here)} absent — `enter linux"
              f" {{ /bin/sh }}` will not work on this build. Run "
              f"`make -C tests/u-binary/src/musl_busybox install` to "
              f"stage the fixture.")

    # Distro-shape backing trees. Walk every subdirectory under
    # tests/distros/ and embed each file at
    # /var/lib/distros/<distro>/<rel-path>. Mirrors the etc/ glob's
    # shape but recurses, so a tiny test fixture like
    #   tests/distros/testdistro/etc/debian_version
    # lands at
    #   /var/lib/distros/testdistro/etc/debian_version
    # in the cpio archive, ready for `bind` to splice it under a
    # privatised namespace's /etc. The `default` fixture is the
    # backing /etc/rc.boot's `linux` namespace recipe grafts —
    # running a Linux binary is `enter linux { ... }` (or the
    # `debian` alias), no bespoke launcher. Real debootstrap-style
    # trees are too large to commit here — these are the smoke-test
    # fixtures for scripts/test_distro_namespace.sh.
    #
    # SIZE GATE for real debootstrap'd backings:
    # `tests/distros/debian-minbase/rootfs/` is ~80-150 MB of real
    # Debian binaries (see tests/distros/debian-minbase/HOWTO.md).
    # Embedding it by default would inflate fs/initramfs_blob.S past
    # GitHub's 100 MB push limit, AND blow past fs/cpio.ad's NR_FILES
    # cap (currently 192, well under debootstrap's ~5000 files). Mirror
    # the HAMNIX_EMBED_UBIN opt-in pattern: only embed
    # `debian-minbase/rootfs/` (and any sibling distro whose root is a
    # `rootfs/` subdir) when HAMNIX_EMBED_DEBIAN is set, and gate the
    # embed scope by the env var's value:
    #
    #     HAMNIX_EMBED_DEBIAN=minimal   (default if set)
    #         Curated subset that fits under NR_FILES + initramfs_blob.S
    #         size sanity: /etc/debian_version, /etc/os-release,
    #         /etc/passwd, /etc/group. Enough to prove the namespace
    #         bind grafts the REAL debootstrap'd /etc/ over Hamnix's,
    #         which is what test_distro_debian.sh asserts.
    #     HAMNIX_EMBED_DEBIAN=full
    #         Walk every file in rootfs/. Currently exceeds NR_FILES;
    #         lands when fs/cpio.ad bumps the cap and the kernel
    #         build path can ingest a ~250 MB cpio archive without
    #         turning fs/initramfs_blob.S into a multi-GB .S file.
    #     HAMNIX_EMBED_DEBIAN=1
    #         Backward-compatible alias for `minimal`.
    #
    # Tiny synthetic fixtures (e.g. tests/distros/testdistro/) without
    # a `rootfs/` layer are always embedded.
    embed_debian_raw = os.environ.get("HAMNIX_EMBED_DEBIAN", "0")
    if embed_debian_raw in ("0", "", "off", "no"):
        embed_debian_mode: str | None = None
    elif embed_debian_raw in ("1", "minimal", "min"):
        embed_debian_mode = "minimal"
    elif embed_debian_raw in ("full", "all"):
        embed_debian_mode = "full"
    else:
        raise SystemExit(
            f"HAMNIX_EMBED_DEBIAN={embed_debian_raw!r}: "
            f"expected one of {{0, 1, minimal, full}}")

    # Curated minimal embed set: relative paths under rootfs/ that
    # the test_distro_debian.sh assertions actually touch. Keep this
    # short — every entry consumes one of NR_FILES slots in
    # fs/cpio.ad and adds ~6x its byte size to fs/initramfs_blob.S.
    DEBIAN_MINIMAL_PATHS = [
        "etc/debian_version",
        "etc/os-release",
        "etc/passwd",
        "etc/group",
        "etc/hostname",
        "usr/lib/os-release",  # /etc/os-release symlink target
    ]

    distros_dir = here / "tests" / "distros"
    if distros_dir.is_dir():
        for distro_root in sorted(distros_dir.iterdir()):
            if not distro_root.is_dir():
                continue
            # If the distro stages its tree under a `rootfs/` subdir
            # (debootstrap convention: BUILD.sh emits ./rootfs/), use
            # that subdir as the embed source and gate it behind
            # HAMNIX_EMBED_DEBIAN. Tiny fixtures without rootfs/
            # (testdistro) embed unconditionally as before.
            rootfs_sub = distro_root / "rootfs"
            if rootfs_sub.is_dir():
                if embed_debian_mode is None:
                    print(f"  skipped tests/distros/{distro_root.name}/rootfs/ "
                          f"(set HAMNIX_EMBED_DEBIAN=1 to embed)")
                    continue
                embed_root = rootfs_sub
                if embed_debian_mode == "minimal":
                    src_iter = []
                    for rel in DEBIAN_MINIMAL_PATHS:
                        p = embed_root / rel
                        if p.is_file():
                            src_iter.append(p)
                else:  # full
                    src_iter = [p for p in sorted(embed_root.rglob("*"))
                                if p.is_file()]
            else:
                embed_root = distro_root
                src_iter = [p for p in sorted(embed_root.rglob("*"))
                            if p.is_file()]
            n_embedded = 0
            n_bytes = 0
            for src in src_iter:
                rel = src.relative_to(embed_root)
                name = ("/var/lib/distros/" + distro_root.name
                        + "/" + str(rel))
                try:
                    data = src.read_bytes()
                except (OSError, PermissionError):
                    # Some debootstrap'd files (e.g. /etc/shadow, mode
                    # 0640 root:shadow) are unreadable by the calling
                    # user. Skip with a note rather than fail the build.
                    print(f"  skipped {name} (unreadable)")
                    continue
                blob += cpio_entry(name, data)
                n_embedded += 1
                n_bytes += len(data)
            if rootfs_sub.is_dir():
                print(f"  embedded {n_embedded} files ({n_bytes} bytes) "
                      f"from tests/distros/{distro_root.name}/rootfs/ "
                      f"[HAMNIX_EMBED_DEBIAN={embed_debian_mode}]")
            else:
                print(f"  embedded {n_embedded} files ({n_bytes} bytes) "
                      f"from tests/distros/{distro_root.name}/")

    # Kernel modules: anything in build/mod/ gets embedded as /<stem>
    # so module_load() can fetch by path. Convention is to start the
    # binary names with "kmod_" so the cpio entries read /kmod_X.
    mod_dir = here / "build" / "mod"
    if mod_dir.is_dir():
        for elf in sorted(mod_dir.glob("*.elf")):
            data = elf.read_bytes()
            name = "/" + elf.stem
            blob += cpio_entry(name, data)
            print(f"  embedded {name} ({len(data)} bytes from "
                  f"build/mod/{elf.name})")

    # Stock Linux 6.12 .ko fixtures: anything checked in at
    # tests/linux-modules/*.ko gets embedded as
    # /lib/modules/6.12/<basename>.ko so the L-track regression
    # (scripts/test_l_track.sh) can `insmod /lib/modules/6.12/<X>.ko`
    # without copying files into the initramfs at boot. Mirrors the
    # etc/ + build/mod/ globs above. Source is tests/linux-modules/
    # Makefile (built against pinned linux-6.12.48).
    lkm_dir = here / "tests" / "linux-modules"
    if lkm_dir.is_dir():
        for ko in sorted(lkm_dir.glob("*.ko")):
            data = ko.read_bytes()
            name = "/lib/modules/6.12/" + ko.name
            blob += cpio_entry(name, data)
            print(f"  embedded {name} ({len(data)} bytes from "
                  f"tests/linux-modules/{ko.name})")

    # U5: host-built Linux ELF test binaries. Anything staged under
    # tests/u-binary/ (built by tests/u-binary/src/*/Makefile via
    # `make install`) lands at /bin/<name>. These are real Linux ABI
    # ELFs — OSABI=ELFOSABI_LINUX, Linux syscall numbers — used to
    # smoke-test the U1..U4 syscall-translation chain end to end.
    # Optional: if the host-side build hasn't been run, this whole
    # block is skipped and the rest of the initramfs is unaffected
    # (so CI without the host fixture still builds a kernel).
    #
    # SIZE NOTE: u_* test binaries (glibc-static-pie ~800 KB each,
    # busybox ~2 MB, C++ demo ~2.4 MB) inflate the cpio archive past
    # GitHub's 100 MB push limit on fs/initramfs_blob.S. To keep the
    # committed default initramfs small, only embed u_* binaries when
    # HAMNIX_EMBED_UBIN=1 is set. Test scripts that need a specific
    # u_* binary set the env var themselves (most don't — they boot
    # against init.elf, not these test fixtures).
    embed_ubin = os.environ.get("HAMNIX_EMBED_UBIN", "0") == "1"
    ubin_dir = here / "tests" / "u-binary"
    if embed_ubin and ubin_dir.is_dir():
        for f in sorted(ubin_dir.iterdir()):
            if f.is_file() and f.name != ".gitignore":
                data = f.read_bytes()
                name = "/bin/" + f.name
                blob += cpio_entry(name, data)
                print(f"  embedded {name} ({len(data)} bytes)")

    # U41: CPython stdlib-on-disk embedding hook (DEPRECATED).
    #
    # The default U41 test no longer uses this path. CPython is now
    # built with the bootstrap stdlib frozen INTO the binary's data
    # segment via Tools/scripts/freeze_modules.py (see
    # tests/u-binary/src/cpython/HOWTO.md "Frozen-modules build"),
    # so init_fs_encoding doesn't need /usr/lib/python3.11/ in the
    # initramfs anymore.
    #
    # The hook is kept here (default-OFF) for flexibility: if a
    # future Python distribution scenario wants to ship the on-disk
    # stdlib (e.g. for pip-installed packages, or because a future
    # CPython rebuild trims the frozen set), set HAMNIX_EMBED_PYLIB
    # to the Lib/ path. The walker mirrors every .py file to
    # /usr/lib/python3.11/<relpath> in the cpio archive.
    #
    # CAVEATS (historic):
    #   - The full upstream Lib/ tree is ~1800 .py files. fs/cpio.ad's
    #     NR_FILES cap (192 at the time of the M16.115 attempt) would
    #     need bumping to 4096+ to accept that many entries.
    #   - The generated fs/initramfs_blob.S grows ~6x larger than the
    #     binary archive due to ASCII expansion; with the full stdlib
    #     embedded the blob exceeds GitHub's 100 MiB push cap.
    #   - SKIPs: __pycache__/ (platform-specific bytecode), lib-dynload/
    #     (compiled C extensions — needs a dynamic loader we don't have).
    pylib_path = os.environ.get("HAMNIX_EMBED_PYLIB", "")
    if pylib_path:
        lib_root = Path(pylib_path)
        if not lib_root.is_absolute():
            lib_root = here / lib_root
        if not lib_root.is_dir():
            raise SystemExit(
                f"HAMNIX_EMBED_PYLIB={pylib_path}: not a directory")
        py_target_prefix = "/usr/lib/python3.11"
        # Walk every .py file under lib_root, mirroring the relative
        # path under /usr/lib/python3.11/. Skip __pycache__ + lib-
        # dynload. The minimum set CPython's -c "print('x')" actually
        # touches at init_fs_encoding time is:
        #   encodings/__init__.py, encodings/aliases.py,
        #   encodings/utf_8.py, encodings/latin_1.py,
        #   encodings/ascii.py, importlib/* (frozen but still
        #   exposed), os.py, io.py, codecs.py, abc.py, posixpath.py,
        #   genericpath.py, _collections_abc.py, _weakrefset.py,
        #   types.py, enum.py, stat.py, _sitebuiltins.py, site.py
        # We embed the whole tree (minus the SKIPs) because hand-
        # curating the include list trades a tiny cpio shave for the
        # next time a CPython module pulls in a new dep.
        n_embedded = 0
        n_bytes = 0
        for src in sorted(lib_root.rglob("*.py")):
            rel = src.relative_to(lib_root)
            parts = rel.parts
            if any(p == "__pycache__" for p in parts):
                continue
            if any(p == "lib-dynload" for p in parts):
                continue
            data = src.read_bytes()
            name = py_target_prefix + "/" + "/".join(parts)
            blob += cpio_entry(name, data)
            n_embedded += 1
            n_bytes += len(data)
        print(f"  embedded {n_embedded} Python stdlib files "
              f"({n_bytes} bytes) under {py_target_prefix}/ "
              f"from {lib_root}")

    for name, data in FILES:
        blob += cpio_entry(name, data)
    blob += cpio_trailer()
    return blob


def emit_asm(archive: bytes, dest: Path) -> None:
    lines = [
        "/* AUTOGENERATED by scripts/build_initramfs.py — do not edit. */",
        "    .section .rodata",
        "    .align 4",
        "    .globl initramfs_cpio_start",
        "initramfs_cpio_start:",
    ]
    for i in range(0, len(archive), 16):
        chunk = archive[i:i + 16]
        bytes_csv = ", ".join(f"0x{b:02x}" for b in chunk)
        lines.append(f"    .byte {bytes_csv}")
    lines += [
        "    .globl initramfs_cpio_end",
        "initramfs_cpio_end:",
        "",
        "    .code64",
        "    .section .text, \"ax\"",
        "    .globl initramfs_cpio_size",
        "initramfs_cpio_size:",
        "    leaq initramfs_cpio_end(%rip), %rax",
        "    leaq initramfs_cpio_start(%rip), %rcx",
        "    subq %rcx, %rax",
        "    ret",
        "",
        "    .globl initramfs_cpio_base",
        "initramfs_cpio_base:",
        "    leaq initramfs_cpio_start(%rip), %rax",
        "    ret",
    ]
    dest.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    here = Path(__file__).resolve().parent.parent
    archive = build_archive()
    dest = here / "fs" / "initramfs_blob.S"
    emit_asm(archive, dest)
    print(f"Wrote {dest} ({len(archive)} bytes archive, "
          f"{len(FILES)} files)")
