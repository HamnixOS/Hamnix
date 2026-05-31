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

# Autostub generator. Runs FIRST so any new bundled .ko's mechanical
# UND symbols (__SCK__*, __SCT__*, __tracepoint_*, retpoline thunks,
# ...) get a stub emitted into linux_abi/api_autostubs.ad BEFORE the
# kernel ELF compile step picks that file up. See
# scripts/gen_autostubs.py for the catalog. The generator is a no-op
# (writes nothing) when the file is already up to date, so this is
# cheap even on incremental builds. We tolerate failure (a corrupt
# .ko shouldn't sink the rest of the build), but a fresh checkout
# always has all the .ko's so the success path is the common one.
def _run_gen_autostubs() -> None:
    try:
        import subprocess
        here = Path(__file__).resolve().parent.parent
        gen = here / "scripts" / "gen_autostubs.py"
        if not gen.is_file():
            return
        # Inherit stdout so the build log shows the summary line.
        subprocess.run(
            ["python3", str(gen)],
            cwd=str(here),
            check=False,
        )
    except Exception as _exc:
        print(f"[build_initramfs] gen_autostubs.py failed: {_exc}")


_run_gen_autostubs()

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

# Native tar/gzip/gunzip fixture. scripts/test_tar_gzip.sh sets
# ENABLE_TAR_GZIP_FIXTURE=1 to bake a REAL host-gzip-produced .gz (with
# known plaintext) into the cpio at /tests/realgz/. The .gz is produced
# by Python's gzip module over highly compressible text, so zlib emits
# dynamic-Huffman DEFLATE blocks — proving our `gunzip` INFLATE handles
# real Huffman streams, not merely our own stored-block output. The
# matching plaintext is staged alongside so the test can diff against it.
if os.environ.get("ENABLE_TAR_GZIP_FIXTURE") == "1":
    import gzip as _gzip_mod
    # Repetitive, compressible plaintext: zlib chooses dynamic Huffman
    # (BTYPE=10) with LZ77 back-references for this, the exact path our
    # gunzip must decode (not the trivial stored path our gzip emits).
    _realgz_plain = (
        b"The quick brown fox jumps over the lazy dog.\n"
        b"Hamnix native gunzip decodes real-world gzip Huffman streams.\n"
    ) * 64
    _realgz_bytes = _gzip_mod.compress(_realgz_plain, compresslevel=9)
    FILES.append(("/tests/realgz/known.txt", _realgz_plain))
    FILES.append(("/tests/realgz/known.txt.gz", _realgz_bytes))

# M16.102 TCP three-way-handshake smoke (10.0.2.100:7 echo via
# SLIRP `guestfwd=tcp:10.0.2.100:7-cmd:cat`). Gated the same way as
# /etc/tcp-ring-test below: without the matching guestfwd the connect
# ARP-stalls and tcp_connect's jiffy deadline never expires (jiffies
# aren't ticking yet at net_smoke_test time — time_init runs later in
# start_kernel). Only scripts/test_net_tcp.sh sets this; the default
# vanilla boot does NOT include it, so production / demo boots skip
# the smoke and reach the interactive prompt cleanly.
if os.environ.get("ENABLE_TCP_SMOKE_TEST") == "1":
    FILES.append(("/etc/tcp-smoke-test", b"1\n"))

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

# TCP loopback smoke: in-kernel single-process loopback round-trip.
# scripts/test_tcp_loopback.sh sets ENABLE_TCP_LOOPBACK_SMOKE=1 to plant
# /etc/tcp-loopback-test; init/main.ad gates tcp_loopback_smoke_test() on
# this marker. No SLIRP guestfwd is needed — 127.0.0.1 is handled purely
# in ip_send's loopback shortcut. Default boots skip this so net tests that
# don't need loopback aren't affected.
if os.environ.get("ENABLE_TCP_LOOPBACK_SMOKE") == "1":
    FILES.append(("/etc/tcp-loopback-test", b"1\n"))

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

# xHCI LIVE keyboard round-trip. Set ENABLE_XHCI_KBD_LIVE=1 to plant
# /etc/xhci-kbd-live; init/main.ad gates xhci_kbd_live_watch() on it.
# Unlike ENABLE_XHCI_SELFTEST (which drives the SYNTHETIC forged-event
# selftests), this opts into a GENUINE wire round-trip: the kernel
# blocks after enumerating a real usb-kbd, prints a READY banner, and
# waits for the controller to post a real interrupt-IN Transfer Event
# for a keypress the harness injects over the QEMU monitor `sendkey`.
# Only scripts/test_xhci_kbd_live.sh sets this (alongside
# ENABLE_XHCI_KO=0 so the hand-rolled drivers/usb/xhci.ad actually
# owns the controller). Default boots ship no marker, so a PS/2-only
# real laptop never enters the watch loop.
if os.environ.get("ENABLE_XHCI_KBD_LIVE") == "1":
    FILES.append(("/etc/xhci-kbd-live", b"1\n"))

# USB mass-storage (BOT/SCSI) exercise. Set ENABLE_USBMS_TEST=1 to
# plant /etc/usbms-test; init/main.ad gates usbms_exercise() on it,
# which enumerates an attached USB stick (boot QEMU with
# `-device qemu-xhci -device usb-storage,drive=...`), registers
# /dev/blk/sd0, and reads sector 0 back. Default boots ship no marker
# so the storage probe is a no-op when no stick is present.
if os.environ.get("ENABLE_USBMS_TEST") == "1":
    FILES.append(("/etc/usbms-test", b"1\n"))

# SMP kthread-churn soak. scripts/test_smp_soak.sh sets ENABLE_SMP_SOAK=1
# to plant /etc/smp-soak in the initramfs. init/main.ad at boot:37 detects
# the marker and calls smp_kthread_soak_run() (kernel/sched/core.ad) which
# hammers kthread create/exit/reap cycles under -smp 2, stressing rq_lock
# contention, AP idle-loop dispatch, and per-CPU current_idx_pcpu mutations.
# Default boots omit the marker so the soak never fires unintentionally.
if os.environ.get("ENABLE_SMP_SOAK") == "1":
    FILES.append(("/etc/smp-soak", b"1\n"))

# Partition write-smoke fixtures (mkpart MBR on sd0, gpt on nvme0n1).
# These WRITE a partition table onto a freshly-registered disk that has
# no MBR, so they must NEVER run on production media. Set
# ENABLE_MKPART_SMOKE=1 to plant /etc/mkpart-smoke; init/main.ad calls
# partition_enable_mkpart_smoke() when it sees the marker, before any
# disk registers. Only scripts/test_mkpart.sh / test_gpt_mkpart.sh set
# it; default boots leave the scan path strictly read-only.
if os.environ.get("ENABLE_MKPART_SMOKE") == "1":
    FILES.append(("/etc/mkpart-smoke", b"1\n"))

# ext4 mkfs self-test arming. The lazy ext4_mkfs_self_test (fs/ext4.ad)
# FORMATS sd0p1/nvme0n1p1, so it is a developer fixture that must NEVER
# run on real media (a shipped .img's sd0p1 is the live ESP). Setting
# ENABLE_MKFS_SELFTEST=1 plants /etc/mkfs-selftest; init/main.ad calls
# ext4_enable_mkfs_selftest() when it sees the marker. Only
# scripts/test_mkfs.sh sets it; default boots never format a disk.
if os.environ.get("ENABLE_MKFS_SELFTEST") == "1":
    FILES.append(("/etc/mkfs-selftest", b"1\n"))

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

# xHCI live-init force-ENABLE opt-IN. The opposite of
# ENABLE_XHCI_NO_INIT: setting ENABLE_XHCI_FORCE_INIT=1 plants
# /etc/xhci-force-init so drivers/usb/xhci.ad's xhci_init() runs the
# live BAR-MMIO bringup path even on bare metal. Without this marker
# (and without /etc/xhci-no-init), bare-metal boots auto-skip the
# live path after CPUID leaf 0x40000000 returns EBX=0 (no hypervisor
# signature) — see drivers/usb/xhci.ad and docs/REAL_HARDWARE.md.
# Use this on real hardware where the user already knows the xHCI
# controller responds to the Hamnix bringup sequence; the user
# accepts the risk that an unresponsive controller will hang the
# halt+reset MMIO poll. QEMU CI never sets this — QEMU is detected
# as a hypervisor (TCG / KVM signature at CPUID 0x40000000) so the
# live xHCI path runs by default.
if os.environ.get("ENABLE_XHCI_FORCE_INIT") == "1":
    FILES.append(("/etc/xhci-force-init", b"1\n"))

# The /etc/e1000e-ko marker that used to gate the .ko-load path is
# gone — init/main.ad's boot:35.a now unconditionally kmod_linux_loads
# /lib/modules/e1000e.ko, which is the only path that drives Intel
# Gigabit silicon (the hand-rolled drivers/net/e1000e.ad has been
# retired). No env-var, no marker file, no conditional code path.

# Storage pivot (Agent D): ahci.ko (SATA AHCI controller — covers
# most stock desktop/laptop SATA silicon). scripts/test_ahci_ko.sh
# sets ENABLE_AHCI_KO=1 to plant /etc/ahci-ko in the initramfs. A
# kernel-side autoloader (Agent B's modprobe.ad / init/main.ad
# wiring) can gate on this marker. In the meantime the test
# exercises the load path via userspace `insmod /lib/modules/6.12/
# ahci.ko` (the L-track test pattern).
if os.environ.get("ENABLE_AHCI_KO") == "1":
    FILES.append(("/etc/ahci-ko", b"1\n"))

# libata.ko harvest (generic Linux ATA/SCSI layer). scripts/test_libata_ko.sh
# sets ENABLE_LIBATA_KO=1 to plant /etc/libata-ko. The kernel-side
# boot:35.LAT path (init/main.ad) gates on this marker and drives an
# explicit ordered load scsi_common -> scsi_mod -> libata so libata's
# scsi_* / sdev_* UND symbols resolve cross-module against scsi_mod's
# ksymtab. Load-only exercise: confirms the loader + linux_abi shims
# absorb the generic ATA/SCSI subsystem (links + init returns 0).
if os.environ.get("ENABLE_LIBATA_KO") == "1":
    FILES.append(("/etc/libata-ko", b"1\n"))

# Storage pivot (Agent D): nvme.ko (PCIe NVM Express SSD driver —
# every modern NVMe device).
# scripts/test_nvme_ko.sh sets ENABLE_NVME_KO=1 to plant /etc/nvme-ko.
# Same userspace-insmod fallback as the ahci block above until a
# kernel-side autoloader honours the marker.
if os.environ.get("ENABLE_NVME_KO") == "1":
    FILES.append(("/etc/nvme-ko", b"1\n"))

# WiFi pivot: cfg80211 + mac80211 are the foundational 802.11
# framework modules. Neither carries a MODULE_DEVICE_TABLE PCI alias
# of its own, so the modprobe auto-loader's PCI-class match never
# fires for them — they must be loaded BEFORE any wifi driver
# (ath*, iwl*, brcmsmac, ...) is brought up. ENABLE_FRAMEWORK_MODULES=1
# plants /etc/framework-modules; init/main.ad reads the marker and
# directly insmods /lib/modules/cfg80211.ko + /lib/modules/mac80211.ko
# during the L-shim init phase. scripts/test_cfg80211_ko.sh and
# scripts/test_mac80211_ko.sh both set this env var.
if os.environ.get("ENABLE_FRAMEWORK_MODULES") == "1":
    FILES.append(("/etc/framework-modules", b"1\n"))

# iwlwifi.ko harvest marker. scripts/test_iwlwifi_ko.sh sets both
# ENABLE_FRAMEWORK_MODULES=1 (to pre-load cfg80211.ko + mac80211.ko)
# and ENABLE_IWLWIFI_KO=1 (to trigger the explicit iwlwifi.ko load
# in init/main.ad's boot:35.W block). Without ENABLE_FRAMEWORK_MODULES
# the iwlwifi load will fail with unresolved cfg80211_* symbols.
if os.environ.get("ENABLE_IWLWIFI_KO") == "1":
    FILES.append(("/etc/iwlwifi-ko", b"1\n"))

# modules.dep regression test marker. scripts/test_loader_modulesdep.sh
# sets this to exercise the in-kernel modules_dep parser: boot without
# the framework-modules pre-load, dispatch mac80211 directly, and let
# the dep walker auto-load cfg80211 first. Mutually exclusive with
# ENABLE_FRAMEWORK_MODULES (which would pre-load both, bypassing the
# dep walker).
if os.environ.get("ENABLE_MODULESDEP_TEST") == "1":
    FILES.append(("/etc/modulesdep-test", b"1\n"))

# Cross-module EXPORT_SYMBOL regression test marker. Loads cfg80211.ko
# then mac80211.ko; the loader's ksymtab fallback path resolves
# mac80211's cfg80211_* UND set against cfg80211's __ksymtab and emits
# a [ksymtab_hit] diag for each resolved name. scripts/
# test_loader_cross_module_export.sh sets this env var.
if os.environ.get("ENABLE_CROSS_MODULE_EXPORT_TEST") == "1":
    FILES.append(("/etc/cross-module-export-test", b"1\n"))

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

# HAMNIX_DEB_FIXTURE: RETIRED. Was used by the now-deleted
# scripts/test_dpkg_*.sh battery (Adder dpkg_deb tests) to plant a host-
# generated tiny .deb at /tests/sample.deb in the cpio. Real apt/dpkg
# now run inside `enter linux { ... }` against debian-minbase/rootfs/;
# no synthetic fixtures needed.

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

# httpd concurrent/vhost/CGI staging: scripts/test_httpd_concurrent.sh
# sets HAMNIX_HTTPD_VHOSTS=1 to plant a full web-server fixture in the
# cpio:
#   /etc/httpd.conf            — listen + cgi_dir + two vhost blocks
#   /var/www/index.html        — default vhost (server_name localhost)
#   /var/www/hello.txt         — a text/plain static file
#   /var/www/style.css         — exercises Content-Type by extension
#   /var/www/cgi-bin/echo      — the cgi_echo ELF (CGI dispatch target)
#   /var/www2/index.html       — second vhost (server_name v2.test)
# The cgi-bin binary is the freshly built build/user/cgi_echo.elf, the
# same bytes that land at /bin/cgi_echo, copied to the docroot CGI path
# so a "/cgi-bin/echo" URL resolves to an executable.
if os.environ.get("HAMNIX_HTTPD_VHOSTS") == "1":
    FILES.append(("/etc/httpd.conf",
                  b"# Hamnix httpd test config\n"
                  b"listen 8080\n"
                  b"cgi_dir /cgi-bin\n"
                  b"vhost {\n"
                  b"    server_name localhost\n"
                  b"    root /var/www\n"
                  b"}\n"
                  b"vhost {\n"
                  b"    server_name v2.test\n"
                  b"    root /var/www2\n"
                  b"}\n"))
    FILES.append(("/var/www/index.html",
                  b"<html><body><h1>VHOST_DEFAULT</h1>"
                  b"<p>default vhost (localhost)</p></body></html>\n"))
    FILES.append(("/var/www/hello.txt",
                  b"hello from hamnix httpd\n"))
    FILES.append(("/var/www/style.css",
                  b"body { color: rebeccapurple; }\n"))
    FILES.append(("/var/www2/index.html",
                  b"<html><body><h1>VHOST_SECOND</h1>"
                  b"<p>second vhost (v2.test)</p></body></html>\n"))
    _cgi_elf = Path(__file__).resolve().parent.parent / "build" / "user" / "cgi_echo.elf"
    if _cgi_elf.is_file():
        FILES.append(("/var/www/cgi-bin/echo", _cgi_elf.read_bytes()))
    else:
        print(f"[build_initramfs] WARNING: {_cgi_elf} missing; "
              f"CGI route will 404")

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

# APT_TRUSTED_GPG: RETIRED with the Adder apt. The real Debian apt-get
# (staged inside /var/lib/distros/default/ via HAMNIX_DEFAULT_REAL_DEBIAN)
# reads /etc/apt/trusted.gpg.d/debian-archive-keyring.gpg from its own
# tree — that file is part of the curated-real-debian stage list.

# cpio capacity stress fixture: scripts/test_cpio_capacity.sh sets
# HAMNIX_CPIO_STRESS_FILES=<N> to plant N tiny synthetic files at
# /cpio-stress/file<i> inside the initramfs. This exercises fs/cpio.ad's
# NR_FILES table past the historical 192-slot cap (the table is now
# 8192 entries). The last planted file carries a recognisable payload
# so the kernel-side check can assert a file PAST index 192 was
# registered and is readable. Off-default: an unset env var leaves the
# initramfs alone, exactly like every other gated marker above.
# hpm repo fixture: scripts/test_hpm.sh sets HAMNIX_HPM_TEST_REPO=<path>
# to plant the contents of <path> at /test-hpm-repo/ inside the cpio
# initramfs. The test boots vanilla Hamnix and runs
# `hpm --repo=file:///test-hpm-repo/ <cmd>` against the planted fixture
# (a tiny index.json + one packages/<name>-<ver>.tar.gz). A second var
# HAMNIX_HPM_TEST_REPO_CONFLICT=<path> plants a parallel
# /test-hpm-repo-conflict/ used for the negative conflict test.
_HPM_TEST_REPO = os.environ.get("HAMNIX_HPM_TEST_REPO", "")
if _HPM_TEST_REPO:
    _repo_root = Path(_HPM_TEST_REPO)
    if not _repo_root.is_dir():
        raise SystemExit(
            f"HAMNIX_HPM_TEST_REPO={_HPM_TEST_REPO!r}: not a directory")
    for _f in sorted(_repo_root.rglob("*")):
        if not _f.is_file():
            continue
        _rel = _f.relative_to(_repo_root)
        with _f.open("rb") as _fh:
            FILES.append((f"/test-hpm-repo/{_rel.as_posix()}",
                          _fh.read()))

_HPM_TEST_REPO_C = os.environ.get("HAMNIX_HPM_TEST_REPO_CONFLICT", "")
if _HPM_TEST_REPO_C:
    _repo_root_c = Path(_HPM_TEST_REPO_C)
    if not _repo_root_c.is_dir():
        raise SystemExit(
            f"HAMNIX_HPM_TEST_REPO_CONFLICT={_HPM_TEST_REPO_C!r}: not a directory")
    for _f in sorted(_repo_root_c.rglob("*")):
        if not _f.is_file():
            continue
        _rel = _f.relative_to(_repo_root_c)
        with _f.open("rb") as _fh:
            FILES.append((f"/test-hpm-repo-conflict/{_rel.as_posix()}",
                          _fh.read()))

# ISO mini-repo for the hpm-driven installer. scripts/build_iso.sh
# builds the v1 packages via scripts/build_packages.py (kernel ELF +
# userland are by then already current) and stages the resulting
# build/packages/ tree into the cpio at /mnt/iso-packages/. The
# installer then runs
#
#   hpm --repo=file:///mnt/iso-packages --target-prefix=/mnt/newroot \
#       install hamnix-base hamnix-installer-tools linux-debian-12
#
# to populate a freshly-formatted target rootfs WITHOUT a network
# round-trip and WITHOUT dd_blk'ing whole partitions. The mirror is
# the Debian-installer pattern.
#
# Off by default: every test that doesn't drive the installer skips
# the (~30 MB) staging cost. scripts/build_iso.sh sets the env var.
_HPM_ISO_PACKAGES = os.environ.get("HAMNIX_ISO_PACKAGES", "")
if _HPM_ISO_PACKAGES:
    _iso_pkgs_root = Path(_HPM_ISO_PACKAGES)
    if not _iso_pkgs_root.is_dir():
        raise SystemExit(
            f"HAMNIX_ISO_PACKAGES={_HPM_ISO_PACKAGES!r}: not a directory")
    _n_iso_pkg_files = 0
    _n_iso_pkg_bytes = 0
    for _f in sorted(_iso_pkgs_root.rglob("*")):
        if not _f.is_file():
            continue
        _rel = _f.relative_to(_iso_pkgs_root)
        with _f.open("rb") as _fh:
            _bytes = _fh.read()
        # NOTE: the brief specified /mnt/iso-packages/, but the kernel
        # auto-mounts vda's FAT volume at /mnt (init/main.ad:313 area)
        # which shadows cpio entries under /mnt/. Stage at
        # /iso-packages/ instead — install.hamsh + the
        # docs/packages.md "Bootstrap" example match this path.
        FILES.append((f"/iso-packages/{_rel.as_posix()}", _bytes))
        _n_iso_pkg_files += 1
        _n_iso_pkg_bytes += len(_bytes)
    print(f"  [iso-packages] staged {_n_iso_pkg_files} files "
          f"({_n_iso_pkg_bytes} bytes) at /iso-packages/ from "
          f"{_iso_pkgs_root}")

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

# Multi-NIC L-shim scale-out: r8169.ko (Realtek consumer GbE) and
# igb.ko (Intel server/workstation). scripts/test_r8169_ko.sh sets
# ENABLE_R8169_KO=1 to plant /etc/r8169-ko; scripts/test_igb_ko.sh
# sets ENABLE_IGB_KO=1 to plant /etc/igb-ko. init/main.ad reads each
# marker to (a) skip any hand-rolled driver that would conflict and
# (b) kmod_linux_load the matching /lib/modules/<name>.ko at boot.
# Default boot omits both markers so unrelated tests run against
# existing drivers.
#
# These env-var markers live at the BOTTOM of this gated-marker
# section by design: Agent B's auto-modules logic (when it lands) is
# expected to slot in higher up, keeping the rebase area conflict-
# free. The order in FILES doesn't affect cpio lookup semantics
# (fs/vfs.ad's _lookup_name returns the first exact-match path; each
# marker has a unique path).
if os.environ.get("ENABLE_R8169_KO") == "1":
    FILES.append(("/etc/r8169-ko", b"1\n"))

if os.environ.get("ENABLE_IGB_KO") == "1":
    FILES.append(("/etc/igb-ko", b"1\n"))

# Multi-NIC L-shim scale-out (round 2): atlantic (Aquantia 10G), alx
# (Qualcomm Atheros), sky2 (Marvell Yukon 2), tg3 (Broadcom NetXtreme).
# Same marker shape as the round-1 trio above. The per-NIC test
# scripts (scripts/test_<name>_ko.sh) flip the matching env var to
# plant the /etc/<name>-ko marker the init/main.ad framework-modules
# reader will eventually honor.
if os.environ.get("ENABLE_ATLANTIC_KO") == "1":
    FILES.append(("/etc/atlantic-ko", b"1\n"))

if os.environ.get("ENABLE_ALX_KO") == "1":
    FILES.append(("/etc/alx-ko", b"1\n"))

if os.environ.get("ENABLE_SKY2_KO") == "1":
    FILES.append(("/etc/sky2-ko", b"1\n"))

if os.environ.get("ENABLE_TG3_KO") == "1":
    FILES.append(("/etc/tg3-ko", b"1\n"))

# e1000e.ko traffic exercise (NIC subsystem proof-of-concept).
# scripts/test_e1000e_traffic.sh sets ENABLE_E1000E_TRAFFIC_TEST=1 to
# plant /etc/e1000e-traffic-test, which gates init/main.ad's boot:35.c
# call to e1000e_traffic_smoke_test (drivers/net/e1000e_traffic.ad).
# After the existing boot:35.b DHCP exchange establishes a lease via
# the .ko, the smoke runs three phases — ICMP ping, DNS UDP lookup,
# 320-packet UDP burst to force >256-entry TX-ring wraparound — to
# prove regular packet flow works, not just DHCP's ~4-packet happy
# path. Default boots omit the marker; only the dedicated test sets
# the env var.
if os.environ.get("ENABLE_E1000E_TRAFFIC_TEST") == "1":
    FILES.append(("/etc/e1000e-traffic-test", b"1\n"))


# Storage L-shim NVMe exercise: scripts/test_nvme_io.sh sets
# ENABLE_NVME_IO_TEST=1 to plant /etc/nvme-io-ko in the initramfs. This
# marker is consumed by init/main.ad in TWO places:
#   * Early (block_smoke_test sibling): SKIP the hand-rolled
#     drivers/nvme/nvme.ad smoke test so the NVMe controller is left
#     for Linux's stock nvme.ko to claim.
#   * Late (boot:35.N): kmod_linux_load /lib/modules/6.12/nvme.ko and
#     run nvme_io_exercise() — try to mount ext4 off the block device
#     the shim-driven path produces and read+write a known file.
# Distinct from ENABLE_NVME_KO (loader-only test): that one keeps the
# hand-rolled driver active and runs `insmod` from hamsh; this one
# forces the .ko shim to own the device end to end. Placed at the END
# of the FILES-append section (last gated marker before the helpers)
# to minimise merge cost with the in-flight SCSI mid-layer agent
# (a48f) which is touching the AHCI gating block above.
if os.environ.get("ENABLE_NVME_IO_TEST") == "1":
    FILES.append(("/etc/nvme-io-ko", b"1\n"))

# USB host-controller class L-shim exercise marker. scripts/test_xhci_io.sh
# sets ENABLE_XHCI_KO=1 to plant /etc/xhci-ko in the initramfs. This
# is the USB equivalent of the ahci-io / nvme-io markers: with the marker
# present init/main.ad SKIPs the hand-rolled drivers/usb/xhci.ad +
# drivers/usb/ehci.ad init paths and instead drives the controller via
# Linux's stock usbcore + xhci_pci + xhci_hcd .ko dep chain through
# kmod_linux_load + modules_dep_load_with_deps. The chain owns the
# controller end to end; the in-kernel xhci_io_exercise() then asserts
# we got at least to usb_add_hcd (root hub registration) before the
# follow-up URB-submission milestone takes over the actual key-event
# injection.
# ENABLE_XHCI_KO defaults to 1 (Linux USB stack ON, hand-rolled
# drivers/usb/{xhci,usb,hid}.ad SKIPPED at boot:01/02). User direction:
# the hand-rolled USB stack never fully worked; the whole point of the
# L-shim pivot is to use Linux's drivers. Set ENABLE_XHCI_KO=0 to opt
# back into the hand-rolled path (legacy only).
if os.environ.get("ENABLE_XHCI_KO", "1") == "1":
    FILES.append(("/etc/xhci-ko", b"1\n"))


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

    # HAMNIX_CPIO_EMPTY=1 — emit a cpio that contains NO files, only the
    # TRAILER. Used by scripts/build_img.sh for the installed-system raw
    # disk image (build/hamnix.img): that image boots ENTIRELY off the
    # ext4 root (the kernel binds '#sysroot' / and ELF-loads /init off
    # the partition — see init/main.ad + docs/rootfs_partition.md), so
    # the kernel needs NO embedded userland at all. The cpio symbol
    # (initramfs_cpio_base/size, fs/cpio.ad) still exists so the kernel
    # links and the `-kernel` developer/test path keeps a real cpio, but
    # the SHIPPED kernel image carries zero cpio userland bytes. This is
    # the "no cpio in the live install path" end state, achieved without
    # the wholesale `-kernel` test-harness rewrite that physically
    # deleting fs/cpio.ad would require (~380 test scripts boot via
    # run_x86_bare.sh's regenerated blob).
    if os.environ.get("HAMNIX_CPIO_EMPTY", "0") == "1":
        print("[build_initramfs] HAMNIX_CPIO_EMPTY=1: emitting a "
              "trailer-only cpio (installed disk boots off ext4).")
        return cpio_trailer()

    # HAMNIX_CPIO_LEAN=1 — strip everything from the cpio that the
    # rootfs partition (build/hamnix-rootfs.img, see
    # scripts/build_rootfs_img.py + docs/rootfs_partition.md) carries
    # instead. Used by scripts/build_iso.sh on the live-USB-style ISO
    # path: the kernel ELF embeds only what's load-bearing BEFORE the
    # block layer brings the rootfs partition online. Everything else
    # (the real Debian apt/dpkg slice, the busybox runtime shell, the
    # ~90 userland Adder binaries) lives on the ext4 partition.
    #
    # When unset (the default), every test that drives `-kernel ELF`
    # directly without attaching the rootfs.img keeps working: the
    # fat-cpio behaviour is preserved, including the in-cpio real
    # Debian apt/dpkg closure that test_linux_apt_install.sh asserts
    # against. Set HAMNIX_CPIO_LEAN=1 ONLY when the rootfs.img will
    # be reachable through the block layer at boot.
    cpio_lean = os.environ.get("HAMNIX_CPIO_LEAN", "0") == "1"

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
    #
    # The full native Adder toolset (~110 ELFs, ~2.2 MiB total) ALWAYS
    # lives in the cpio, even on the lean ISO path. The cpio is baked
    # into the kernel ELF and is the ONLY filesystem guaranteed
    # readable on every boot medium (CD/ATAPI, USB, virtio, AHCI) —
    # the ext4 rootfs partition is unreachable off a GNOME Boxes CD or
    # a real-HW USB stick, so anything stripped to the partition simply
    # disappears there ("no commands found"). At ~2.2 MiB the toolset
    # is negligible against the 32 MB ESP budget (kernel ELF 26→28 MB).
    # HAMNIX_CPIO_LEAN therefore strips ONLY the heavy distro closure
    # (busybox runtime + the real Debian apt/dpkg slice, tens of MB);
    # the native tools are never lean-stripped. This restores 70a6715
    # ("keep native Adder userland tools in the lean cpio"), which
    # 4c8c10b had wrongly undone.
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

    # HAMNIX_HAMSH_RC=<path>: when set, replace etc/hamsh.rc (or plant
    # one if absent) with the file at <path>. Used by tests that drive
    # hamsh as /init (INIT_ELF=hamsh.elf) and want their own startup
    # script — the default boot path uses /etc/rc.boot (argv[1]) instead,
    # so /etc/hamsh.rc is normally empty/absent. Override applies before
    # the etc/ glob so the test's rc isn't shadowed by a committed file.
    hamsh_rc_override = os.environ.get("HAMNIX_HAMSH_RC")
    hamsh_rc_override_real: Path | None = None
    if hamsh_rc_override:
        p = Path(hamsh_rc_override)
        if not p.is_absolute():
            p = here / p
        if not p.exists():
            raise SystemExit(f"HAMNIX_HAMSH_RC={hamsh_rc_override}: "
                             f"file not found")
        hamsh_rc_override_real = p.resolve()
        data = p.read_bytes()
        blob += cpio_entry("/etc/hamsh.rc", data)
        print(f"  embedded /etc/hamsh.rc ({len(data)} bytes from "
              f"{p.relative_to(here) if p.is_relative_to(here) else p}) "
              f"[HAMNIX_HAMSH_RC override]")

    # Baseline /etc files: anything in etc/ gets embedded as /etc/<name>
    # so userland (motd, hostname, future login/init scripts) can read
    # config from a Linux-conventional path without baking strings into
    # binaries. Edit etc/* and re-run this script to refresh.
    #
    # Sub-directories under etc/ are walked one level deep and their
    # files land at /etc/<subdir>/<file>. This is how /etc/svc/<name>.hamsh
    # (init-side service-supervisor definition files) reach userland:
    # hamsh's `svc start <name>` builtin opens /etc/svc/<name>.hamsh and
    # parses the key:value lines. Symlinks and nested sub-dirs are
    # intentionally not followed — the cpio layout is one shallow level.
    etc_dir = here / "etc"
    if etc_dir.is_dir():
        for ef in sorted(etc_dir.iterdir()):
            if ef.is_file():
                # Skip etc/hamsh.rc if a HAMNIX_HAMSH_RC override already
                # planted one — the first cpio entry wins in _lookup_name,
                # but listing both is wasteful and confusing.
                if hamsh_rc_override_real is not None \
                        and ef.name == "hamsh.rc":
                    continue
                data = ef.read_bytes()
                name = "/etc/" + ef.name
                blob += cpio_entry(name, data)
                print(f"  embedded {name} ({len(data)} bytes from "
                      f"etc/{ef.name})")
            elif ef.is_dir():
                # etc/man/ is staged at the conventional Unix manpage
                # path /usr/share/man/<topic>.<N>.md. Source-of-truth
                # for the page bytes lives at etc/man/ in the tree (so
                # gen_install_manifest.py and rc.boot can find it
                # without a separate copy step), but every consumer
                # looks under /usr/share/man/ at runtime — that's
                # where `man <topic>` reads from.
                if ef.name == "man":
                    for sub in sorted(ef.iterdir()):
                        if sub.is_file():
                            data = sub.read_bytes()
                            name = "/usr/share/man/" + sub.name
                            blob += cpio_entry(name, data)
                            print(f"  embedded {name} ({len(data)} bytes "
                                  f"from etc/man/{sub.name})")
                    continue
                for sub in sorted(ef.iterdir()):
                    if sub.is_file():
                        data = sub.read_bytes()
                        name = "/etc/" + ef.name + "/" + sub.name
                        blob += cpio_entry(name, data)
                        print(f"  embedded {name} ({len(data)} bytes "
                              f"from etc/{ef.name}/{sub.name})")

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
    if cpio_lean:
        print(f"  [LEAN] skipping in-cpio busybox staging — Linux "
              f"runtime shell lives at /var/lib/distros/default/bin/"
              f"busybox on rootfs.img")
    elif bb_src.is_file():
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

    # HAMNIX_DEFAULT_REAL_DEBIAN=1 — stage REAL Debian apt/dpkg into the
    # `default` distro tree. The orchestrator's V0 of "real package
    # management" runs `enter linux { /usr/bin/apt-get install hello }`,
    # which needs the genuine Debian apt + dpkg binaries (and their
    # dynamic-link closure) at /var/lib/distros/default/usr/bin/apt-get
    # etc. — the linux/debian namespaces in etc/rc.boot bind / to
    # /var/lib/distros/default, so /usr/bin/apt-get inside an
    # `enter linux { }` block resolves to that cpio path.
    #
    # Source: tests/distros/debian-minbase/rootfs/ (debootstrap'd by
    # tests/distros/debian-minbase/BUILD.sh; gitignored). When that
    # tree is absent the env var is a no-op + warning, exactly like
    # u_busybox_musl: tests that need real apt skip themselves.
    #
    # CURATED file list (not full rootfs) — the goal is to ship
    # `apt-get --version`, `dpkg --version`, and a fork-exec'd
    # `apt-get install hello` end-to-end. Walking the full ~4500-file
    # rootfs would inflate fs/initramfs_blob.S past GitHub's 100 MB
    # push limit and burn most of fs/cpio.ad's NR_FILES (8192) on
    # files apt/dpkg never touch. The list below is the closure of
    # `ldd /usr/bin/{apt-get,dpkg,dpkg-deb}` plus the /etc files apt
    # reads at startup, plus the ld.so + libc pair every dynamic
    # binary needs.
    # HAMNIX_DEFAULT_REAL_DEBIAN defaults to "1" (real Debian apt/dpkg
    # staged). Set "0"/"off"/"no" to fall back to the busybox-only fixture
    # (smaller ISO, no real-apt). Per user direction 2026-05-26: Hamnix
    # is meant to ship as a real distro — real Debian is the default.
    real_debian_raw = os.environ.get("HAMNIX_DEFAULT_REAL_DEBIAN", "1")
    if cpio_lean:
        # LEAN mode: real Debian closure is staged into rootfs.img by
        # scripts/build_rootfs_img.py (which honours
        # HAMNIX_DEFAULT_REAL_DEBIAN with the same default-on semantics).
        # Skip the in-cpio embed entirely to keep the kernel ELF small.
        print(f"  [LEAN] real Debian apt/dpkg slice: skipped from cpio "
              f"(staged into rootfs.img instead, "
              f"HAMNIX_DEFAULT_REAL_DEBIAN={real_debian_raw})")
    elif real_debian_raw not in ("0", "", "off", "no"):
        minbase_rootfs = (here / "tests" / "distros" / "debian-minbase"
                          / "rootfs")
        if not minbase_rootfs.is_dir():
            print(f"  WARN: HAMNIX_DEFAULT_REAL_DEBIAN={real_debian_raw}"
                  f" but {minbase_rootfs.relative_to(here)} absent — "
                  f"run tests/distros/debian-minbase/BUILD.sh first")
        else:
            # Curated closure for `apt-get install hello` end-to-end.
            # All paths are RELATIVE to minbase_rootfs/.
            REAL_DEBIAN_FILES = [
                # Package managers proper.
                "usr/bin/apt",
                "usr/bin/apt-get",
                "usr/bin/apt-cache",
                "usr/bin/apt-config",
                "usr/bin/apt-mark",
                "usr/bin/dpkg",
                "usr/bin/dpkg-deb",
                "usr/bin/dpkg-query",
                "usr/bin/dpkg-split",
                # Dynamic linker + libc (every dynamic binary needs them).
                "usr/lib64/ld-linux-x86-64.so.2",
                "usr/lib/x86_64-linux-gnu/libc.so.6",
                "usr/lib/x86_64-linux-gnu/libm.so.6",
                "usr/lib/x86_64-linux-gnu/libpthread.so.0",
                "usr/lib/x86_64-linux-gnu/libdl.so.2",
                "usr/lib/x86_64-linux-gnu/libresolv.so.2",
                "usr/lib/x86_64-linux-gnu/librt.so.1",
                # apt's .so closure.
                "usr/lib/x86_64-linux-gnu/libapt-pkg.so.7.0",
                "usr/lib/x86_64-linux-gnu/libapt-pkg.so.7.0.0",
                "usr/lib/x86_64-linux-gnu/libapt-private.so.0.0",
                "usr/lib/x86_64-linux-gnu/libapt-private.so.0.0.0",
                "usr/lib/x86_64-linux-gnu/libstdc++.so.6",
                "usr/lib/x86_64-linux-gnu/libstdc++.so.6.0.33",
                "usr/lib/x86_64-linux-gnu/libgcc_s.so.1",
                "usr/lib/x86_64-linux-gnu/libz.so.1",
                "usr/lib/x86_64-linux-gnu/libz.so.1.3.1",
                "usr/lib/x86_64-linux-gnu/libbz2.so.1.0",
                "usr/lib/x86_64-linux-gnu/libbz2.so.1.0.4",
                "usr/lib/x86_64-linux-gnu/liblzma.so.5",
                "usr/lib/x86_64-linux-gnu/liblzma.so.5.8.1",
                "usr/lib/x86_64-linux-gnu/liblz4.so.1",
                "usr/lib/x86_64-linux-gnu/liblz4.so.1.10.0",
                "usr/lib/x86_64-linux-gnu/libzstd.so.1",
                "usr/lib/x86_64-linux-gnu/libzstd.so.1.5.7",
                "usr/lib/x86_64-linux-gnu/libudev.so.1",
                "usr/lib/x86_64-linux-gnu/libudev.so.1.7.10",
                "usr/lib/x86_64-linux-gnu/libsystemd.so.0",
                "usr/lib/x86_64-linux-gnu/libsystemd.so.0.40.0",
                "usr/lib/x86_64-linux-gnu/libcrypto.so.3",
                "usr/lib/x86_64-linux-gnu/libxxhash.so.0",
                "usr/lib/x86_64-linux-gnu/libxxhash.so.0.8.3",
                "usr/lib/x86_64-linux-gnu/libcap.so.2",
                "usr/lib/x86_64-linux-gnu/libcap.so.2.75",
                # dpkg's .so closure.
                "usr/lib/x86_64-linux-gnu/libmd.so.0",
                "usr/lib/x86_64-linux-gnu/libmd.so.0.1.0",
                "usr/lib/x86_64-linux-gnu/libselinux.so.1",
                "usr/lib/x86_64-linux-gnu/libpcre2-8.so.0",
                "usr/lib/x86_64-linux-gnu/libpcre2-8.so.0.14.0",
                # /etc essentials — apt reads these at startup, dpkg
                # reads admindir status / available.
                "etc/debian_version",
                "etc/os-release",
                "etc/passwd",
                "etc/group",
                "etc/hostname",
                "etc/apt/sources.list",
                "etc/apt/apt.conf",
                # dpkg's admindir scaffolding (status starts empty;
                # available may be absent — both files are looked up
                # by dpkg but missing-is-OK after a fresh debootstrap).
                "var/lib/dpkg/status",
                "var/lib/dpkg/available",
                "var/lib/dpkg/diversions",
                "var/lib/dpkg/statoverride",
                # Trusted GPG keyring (apt needs an anchor; the
                # Debian-shipped one is the canonical source).
                "usr/share/keyrings/debian-archive-keyring.gpg",
                "etc/apt/trusted.gpg.d/debian-archive-keyring.gpg",
            ]
            # Usrmerge expansion: Debian binaries internally reference
            # `/lib64/ld-linux-x86-64.so.2`, `/lib/x86_64-linux-gnu/
            # libc.so.6`, `/bin/sh`, etc. — paths under the four
            # usrmerge symlinks (/bin /sbin /lib /lib64 -> usr/*).
            # Hamnix's fs/vfs.ad `_lookup_name` follows whole-path
            # symlink entries but does NOT walk symlinks that sit in
            # the MIDDLE of a path (no path-component traversal — the
            # cpio is a flat name table). So a directory-symlink at
            # /var/lib/distros/default/lib64 -> usr/lib64 cannot route
            # a lookup of /var/lib/distros/default/lib64/ld-linux-
            # x86-64.so.2 into the staged usr/lib64 entry.
            #
            # Fix: when a file lands under `usr/<x>`, ALSO plant it at
            # the corresponding non-usrmerge alias `<x>`. So
            #   usr/lib64/ld-linux-x86-64.so.2 -> ALSO at lib64/...
            #   usr/lib/x86_64-linux-gnu/libc.so.6 -> ALSO at lib/...
            #   usr/bin/dpkg -> ALSO at bin/dpkg
            # Both PT_INTERP and DT_NEEDED resolution see the file
            # without depending on directory-component symlink walking.
            # The duplicate cpio entries are HEADER-only overhead — the
            # actual data bytes are emitted once (the second header
            # points into the cpio's contiguous bytes? no — newc cpio
            # is one header+data block per entry, so we DO duplicate
            # the data bytes too. ~20 MB raw -> ~40 MB raw with the
            # alias). Acceptable: still well under the GitHub push
            # limit on fs/initramfs_blob.S, and still smaller than a
            # full debootstrap rootfs at 214 MB.
            USRMERGE_ALIASES = {
                "usr/bin/":  "bin/",
                "usr/sbin/": "sbin/",
                "usr/lib/":  "lib/",
                "usr/lib64/": "lib64/",
            }
            staged_files = 0
            staged_bytes = 0
            missing: list[str] = []
            for rel in REAL_DEBIAN_FILES:
                src = minbase_rootfs / rel
                if not src.is_file():
                    # Some paths (apt.conf, available, ...) are
                    # genuinely optional in a minbase debootstrap;
                    # skip them silently.
                    missing.append(rel)
                    continue
                try:
                    data = src.read_bytes()
                except (OSError, PermissionError):
                    missing.append(f"{rel} (unreadable)")
                    continue
                mode = (0o100755
                        if src.stat().st_mode & 0o111
                        else 0o100644)
                # Primary: the canonical /var/lib/distros/default/<rel>
                # path (matches the source tree layout 1:1).
                primary_name = "/var/lib/distros/default/" + rel
                blob += cpio_entry(primary_name, data, mode=mode)
                staged_files += 1
                staged_bytes += len(data)
                # Usrmerge alias: also plant at the non-usr equivalent
                # so /bin/X and /lib/X paths resolve directly.
                for prefix, alias_prefix in USRMERGE_ALIASES.items():
                    if rel.startswith(prefix):
                        alias_rel = alias_prefix + rel[len(prefix):]
                        alias_name = ("/var/lib/distros/default/"
                                      + alias_rel)
                        blob += cpio_entry(alias_name, data, mode=mode)
                        staged_files += 1
                        staged_bytes += len(data)
                        break
            print(f"  staged real Debian apt/dpkg slice: {staged_files} "
                  f"entries ({staged_bytes} bytes) under "
                  f"/var/lib/distros/default/ "
                  f"[HAMNIX_DEFAULT_REAL_DEBIAN={real_debian_raw}]")
            if missing:
                print(f"  (skipped {len(missing)} optional files: "
                      f"{', '.join(missing[:5])}"
                      f"{'…' if len(missing) > 5 else ''})")

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

    # Linux's stock e1000e.ko (Debian 6.1.0-32 build, ~668 KiB), checked
    # in at kernel-modules/e1000e/e1000e.ko. Always planted at
    # /lib/modules/e1000e.ko — init/main.ad's boot:35.a path
    # unconditionally kmod_linux_loads it (the hand-rolled
    # drivers/net/e1000e.ad has been retired). On boards without an
    # Intel NIC the .ko loads but its probe doesn't bind, so this is
    # cheap (no-op-on-mismatch). The ENABLE_AUTO_MODULES=1 block below
    # additionally bakes every kernel-modules/<X>/*.ko at
    # /lib/modules/auto/<X>.ko + a modules.alias table so the in-kernel
    # modprobe_auto_load() walks the live PCI bus and picks the right
    # driver per device — Linux's exact modprobe-by-PCI-ID model.
    e1000e_ko = here / "kernel-modules" / "e1000e" / "e1000e.ko"
    if e1000e_ko.is_file():
        data = e1000e_ko.read_bytes()
        name = "/lib/modules/e1000e.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/e1000e/e1000e.ko)")

    # ENABLE_AUTO_MODULES=1 — Linux-shape modprobe auto-discovery.
    #
    # Walks kernel-modules/<name>/*.ko, plants each at
    # /lib/modules/auto/<basename> in the cpio, and bakes a
    # `modules.alias` table (one alias-pattern -> module-name line per
    # MODULE_DEVICE_TABLE entry, generated by
    # scripts/build_modules_alias.py from `modinfo -F alias`) at
    # /lib/modules/modules.alias. The in-kernel modprobe_auto_load()
    # (kernel/modprobe.ad) reads the table at boot, walks Hamnix's
    # PCI bus, and kmod_linux_load()s the matching .ko for each
    # device — Linux's exact modprobe-by-PCI-ID model.
    #
    # Also plants /etc/auto-modules as the runtime gate: init/main.ad
    # only invokes modprobe_auto_load() when this marker is present,
    # so the default CI boot stays single-purpose and tests that
    # depend on the existing hand-rolled drivers (virtio-net,
    # r8169) keep working. Set ENABLE_AUTO_MODULES=1 to opt in; CI
    # sets it in scripts/test_auto_modules.sh.
    if os.environ.get("ENABLE_AUTO_MODULES") == "1":
        kmods_root = here / "kernel-modules"
        n_ko = 0
        n_ko_bytes = 0
        if kmods_root.is_dir():
            for sub in sorted(kmods_root.iterdir()):
                if not sub.is_dir():
                    continue
                for ko in sorted(sub.glob("*.ko")):
                    data = ko.read_bytes()
                    name = f"/lib/modules/auto/{ko.name}"
                    blob += cpio_entry(name, data)
                    n_ko += 1
                    n_ko_bytes += len(data)
                    print(f"  embedded {name} ({len(data)} bytes "
                          f"from kernel-modules/{sub.name}/{ko.name})")
        # Generate the alias table by delegating to the dedicated
        # script, then bake its bytes at /lib/modules/modules.alias.
        # We import the helper rather than shelling out so a single
        # process build_initramfs.py call doesn't fork twice.
        import importlib.util as _ilu
        _mod_alias_path = here / "scripts" / "build_modules_alias.py"
        _spec = _ilu.spec_from_file_location(
            "build_modules_alias", _mod_alias_path)
        if _spec is None or _spec.loader is None:
            raise SystemExit(
                f"build_initramfs: cannot import {_mod_alias_path}")
        _mod_alias = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(_mod_alias)
        alias_text = _mod_alias.build_alias_table(kmods_root)
        alias_bytes = alias_text.encode()
        blob += cpio_entry("/lib/modules/modules.alias", alias_bytes)
        print(f"  embedded /lib/modules/modules.alias "
              f"({len(alias_bytes)} bytes, "
              f"{alias_text.count(chr(10)) - 3 if alias_text else 0} "
              f"alias lines, from {n_ko} .ko files / "
              f"{n_ko_bytes} bytes)")
        # Runtime gate marker. init/main.ad's modprobe_auto_load()
        # block only fires when this file is present in the initramfs.
        FILES.append(("/etc/auto-modules", b"1\n"))

    # modules.dep — Linux-shape dependency table for the in-kernel
    # modules_dep parser (kernel/modules_dep.ad). Planted unconditionally
    # whenever kernel-modules/ has any .ko files, because both the
    # framework-modules path (cfg80211 + mac80211) and the auto-modules
    # PCI walk use it to topologically load deps before a target module.
    # The cost is small (a few hundred bytes — one short line per .ko).
    # When the table is absent the in-kernel parser just falls back to
    # the legacy "load only the requested module, no deps" behavior.
    _kmods_root_for_dep = here / "kernel-modules"
    if _kmods_root_for_dep.is_dir() and any(
            _kmods_root_for_dep.glob("*/*.ko")):
        import importlib.util as _ilu_dep
        _mod_dep_path = here / "scripts" / "build_modules_dep.py"
        _spec_dep = _ilu_dep.spec_from_file_location(
            "build_modules_dep", _mod_dep_path)
        if _spec_dep is None or _spec_dep.loader is None:
            raise SystemExit(
                f"build_initramfs: cannot import {_mod_dep_path}")
        _mod_dep = _ilu_dep.module_from_spec(_spec_dep)
        _spec_dep.loader.exec_module(_mod_dep)
        dep_text = _mod_dep.build_dep_table(_kmods_root_for_dep)
        dep_bytes = dep_text.encode()
        blob += cpio_entry("/lib/modules/modules.dep", dep_bytes)
        # Count the data lines (those not starting with '#') for the log.
        _dep_lines_n = sum(
            1 for ln in dep_text.splitlines()
            if ln and not ln.startswith("#"))
        print(f"  embedded /lib/modules/modules.dep "
              f"({len(dep_bytes)} bytes, {_dep_lines_n} module rows)")

    # Userland modprobe test fixture. scripts/test_modprobe.sh sets
    # ENABLE_MODPROBE_USERLAND_TEST=1 to plant a synthetic Linux-shape
    # modules.dep at /lib/modules/6.12/modprobe-test.dep. libcrc32c's
    # line lists crc32c_generic as its (flattened, transitive)
    # dependency, so the native user/modprobe.ad must load
    # crc32c_generic BEFORE libcrc32c. The .ko paths are relative to
    # the dep file's own directory (/lib/modules/6.12/), where the test
    # stages crc32c_generic.ko + libcrc32c.ko into tests/linux-modules/
    # (embedded by the *.ko glob above at /lib/modules/6.12/<name>.ko).
    # Emitted here via blob += cpio_entry() (alongside the real
    # modules.dep) so it lands in the same cpio region the userland VFS
    # root sees — the FILES[] list is laid down separately and was not
    # openable from userland sys_open(). These two .ko's are tiny
    # (~10 KiB), so the userland read-whole-file path stays cheap.
    if os.environ.get("ENABLE_MODPROBE_USERLAND_TEST") == "1":
        _modprobe_dep_bytes = (
            b"# synthetic modules.dep for scripts/test_modprobe.sh\n"
            b"crc32c_generic.ko:\n"
            b"libcrc32c.ko: crc32c_generic.ko\n")
        blob += cpio_entry(
            "/lib/modules/6.12/modprobe-test.dep", _modprobe_dep_bytes)
        print(f"  embedded /lib/modules/6.12/modprobe-test.dep "
              f"({len(_modprobe_dep_bytes)} bytes, synthetic fixture)")

    # Multi-NIC scale-out: r8169.ko (Realtek consumer GbE) and igb.ko
    # (Intel server/workstation). Same plant-unconditional shape as
    # e1000e.ko above — marker files at /etc/r8169-ko and /etc/igb-ko
    # gate which .ko init/main.ad actually loads at boot.
    r8169_ko = here / "kernel-modules" / "r8169" / "r8169.ko"
    if r8169_ko.is_file():
        data = r8169_ko.read_bytes()
        name = "/lib/modules/r8169.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/r8169/r8169.ko)")

    igb_ko = here / "kernel-modules" / "igb" / "igb.ko"
    if igb_ko.is_file():
        data = igb_ko.read_bytes()
        name = "/lib/modules/igb.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/igb/igb.ko)")

    # Multi-NIC L-shim scale-out (round 2): atlantic.ko (Aquantia 10G),
    # alx.ko (Qualcomm Atheros AR816x), sky2.ko (Marvell Yukon 2),
    # tg3.ko (Broadcom NetXtreme). Each is a coverage-probe load —
    # success criterion is `init returned 0` with zero skipped
    # relocations. Same unconditional-bake shape as the round-1 trio
    # above; the gating /etc/<name>-ko marker controls whether
    # init/main.ad's framework-modules path actually insmods the
    # binary at boot.
    atlantic_ko = here / "kernel-modules" / "atlantic" / "atlantic.ko"
    if atlantic_ko.is_file():
        data = atlantic_ko.read_bytes()
        name = "/lib/modules/atlantic.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/atlantic/atlantic.ko)")

    alx_ko = here / "kernel-modules" / "alx" / "alx.ko"
    if alx_ko.is_file():
        data = alx_ko.read_bytes()
        name = "/lib/modules/alx.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/alx/alx.ko)")

    sky2_ko = here / "kernel-modules" / "sky2" / "sky2.ko"
    if sky2_ko.is_file():
        data = sky2_ko.read_bytes()
        name = "/lib/modules/sky2.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/sky2/sky2.ko)")

    tg3_ko = here / "kernel-modules" / "tg3" / "tg3.ko"
    if tg3_ko.is_file():
        data = tg3_ko.read_bytes()
        name = "/lib/modules/tg3.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/tg3/tg3.ko)")

    # Storage pivot (Agent D): ahci.ko (SATA AHCI controller —
    # Debian 6.1.0-32 build, ~117 KiB). Planted at /lib/modules/ahci.ko
    # AND at /lib/modules/6.12/ahci.ko so the userspace `insmod` path
    # the L-track tests use can find it.
    ahci_ko = here / "kernel-modules" / "ahci" / "ahci.ko"
    if ahci_ko.is_file():
        data = ahci_ko.read_bytes()
        for name in ("/lib/modules/ahci.ko",
                     "/lib/modules/6.12/ahci.ko"):
            blob += cpio_entry(name, data)
            print(f"  embedded {name} ({len(data)} bytes from "
                  f"kernel-modules/ahci/ahci.ko)")

    # Storage pivot (Agent D): nvme.ko (PCIe NVM Express SSD driver —
    # Debian 6.1.0-32 build, ~128 KiB). Same dual-path planting.
    nvme_ko = here / "kernel-modules" / "nvme" / "nvme.ko"
    if nvme_ko.is_file():
        data = nvme_ko.read_bytes()
        for name in ("/lib/modules/nvme.ko",
                     "/lib/modules/6.12/nvme.ko"):
            blob += cpio_entry(name, data)
            print(f"  embedded {name} ({len(data)} bytes from "
                  f"kernel-modules/nvme/nvme.ko)")

    # Storage maximalism: SCSI mid-layer chain ahci.ko depends on,
    # plus nvme-core.ko that nvme.ko depends on. Both go through the
    # in-kernel modules_dep walker + cross-module ksymtab so each
    # upstream module's EXPORT_SYMBOL satisfies the next module's UND.
    for ko_dir, ko_name in (
            ("scsi_common", "scsi_common.ko"),
            ("scsi_mod",    "scsi_mod.ko"),
            ("libata",      "libata.ko"),
            ("libahci",     "libahci.ko"),
    ):
        ko_path = here / "kernel-modules" / ko_dir / ko_name
        if ko_path.is_file():
            data = ko_path.read_bytes()
            for name in (f"/lib/modules/{ko_name}",
                         f"/lib/modules/6.12/{ko_name}"):
                blob += cpio_entry(name, data)
                print(f"  embedded {name} ({len(data)} bytes from "
                      f"kernel-modules/{ko_dir}/{ko_name})")

    nvme_core_ko = here / "kernel-modules" / "nvme_core" / "nvme-core.ko"
    if nvme_core_ko.is_file():
        data = nvme_core_ko.read_bytes()
        # nvme.ko's modules.dep entry says `depends: nvme-core` (with a
        # dash). The in-kernel modules_dep walker (kernel/modules_dep.ad)
        # normalizes '-' to '_' when composing the cpio lookup path, so
        # it actually searches for `/lib/modules/nvme_core.ko` (underscore).
        # Plant BOTH forms so a userspace `insmod /lib/modules/nvme-core.ko`
        # (dash, what `modinfo -F name` prints) and the in-kernel dep
        # walker's lookup (underscore-normalized) both resolve. Same
        # dual-form trick used for xhci-hcd vs xhci_hcd.ko below.
        for name in ("/lib/modules/nvme-core.ko",
                     "/lib/modules/6.12/nvme-core.ko",
                     "/lib/modules/nvme_core.ko",
                     "/lib/modules/6.12/nvme_core.ko"):
            blob += cpio_entry(name, data)
            print(f"  embedded {name} ({len(data)} bytes from "
                  f"kernel-modules/nvme_core/nvme-core.ko)")

    # USB host-controller class L-shim chain: usbcore (the USB stack
    # core library) + xhci_pci (PCI attachment shim for xHCI) +
    # xhci_hcd (xHCI host-controller driver proper) + ehci_pci +
    # ehci_hcd. Planted at the framework path so the in-kernel
    # modules_dep parser finds each module via _md_find_ko() — the
    # walker dispatches xhci_pci's declared deps (xhci-hcd, usbcore)
    # and recursively loads them before xhci_pci's init_module fires.
    # Same dual-path planting (/lib/modules + /lib/modules/6.12) as
    # the storage class above so userspace `insmod` tests can find
    # the .kos at the conventional Debian path too.
    #
    # IMPORTANT: `modinfo -F depends xhci_pci.ko` returns `xhci-hcd,
    # usbcore` — with a DASH in xhci-hcd. The in-kernel modules_dep
    # parser walks dep tokens VERBATIM to build the cpio lookup path,
    # so /lib/modules/xhci-hcd.ko is what the dep walker tries first.
    # Therefore plant the cpio entries using the dash-form filename
    # (mirroring nvme-core.ko which has the same dash-vs-underscore
    # split). Name normalization in _md_name_eq only handles the
    # already-loaded fingerprint table.
    for ko_dir, ko_name, dep_filename in (
            ("usbcore",  "usbcore.ko",  "usbcore.ko"),
            ("xhci_pci", "xhci_pci.ko", "xhci_pci.ko"),
            ("xhci_hcd", "xhci_hcd.ko", "xhci-hcd.ko"),
            ("ehci_pci", "ehci_pci.ko", "ehci_pci.ko"),
            ("ehci_hcd", "ehci_hcd.ko", "ehci-hcd.ko"),
    ):
        ko_path = here / "kernel-modules" / ko_dir / ko_name
        if ko_path.is_file():
            data = ko_path.read_bytes()
            paths = [
                f"/lib/modules/{dep_filename}",
                f"/lib/modules/6.12/{dep_filename}",
            ]
            # Also plant the underscore-form filename if it differs from
            # the dep-form — userspace `insmod` users habitually type
            # xhci_hcd.ko (with underscore) since that's the modinfo
            # -F name output.
            if dep_filename != ko_name:
                paths += [
                    f"/lib/modules/{ko_name}",
                    f"/lib/modules/6.12/{ko_name}",
                ]
            for name in paths:
                blob += cpio_entry(name, data)
                print(f"  embedded {name} ({len(data)} bytes from "
                      f"kernel-modules/{ko_dir}/{ko_name})")

    # WiFi pivot: cfg80211.ko (configuration/admin layer, ~2.3 MiB)
    # and mac80211.ko (soft-MAC stack, ~2.4 MiB) — Debian 6.1.0-32
    # build. Foundational framework modules; every wifi driver
    # (ath*, iwl*, brcmsmac, ...) depends on these two. Neither has
    # a MODULE_DEVICE_TABLE PCI alias so the modprobe auto-loader
    # won't pick them up — init/main.ad's framework-modules block
    # (gated on /etc/framework-modules, planted via
    # ENABLE_FRAMEWORK_MODULES=1) loads them explicitly via
    # kmod_linux_load from these well-known paths.
    cfg80211_ko = here / "kernel-modules" / "cfg80211" / "cfg80211.ko"
    if cfg80211_ko.is_file():
        data = cfg80211_ko.read_bytes()
        name = "/lib/modules/cfg80211.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/cfg80211/cfg80211.ko)")

    mac80211_ko = here / "kernel-modules" / "mac80211" / "mac80211.ko"
    if mac80211_ko.is_file():
        data = mac80211_ko.read_bytes()
        name = "/lib/modules/mac80211.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/mac80211/mac80211.ko)")

    # iwlwifi.ko — Intel wireless PCI driver (Debian 6.1.0-32 build).
    # Bundled unconditionally alongside cfg80211 + mac80211 so the dep
    # chain (cfg80211 -> mac80211 -> iwlwifi) is available in the cpio
    # whenever ENABLE_FRAMEWORK_MODULES=1. The /etc/iwlwifi-ko marker
    # (planted via ENABLE_IWLWIFI_KO=1) gates the actual kmod_linux_load
    # in init/main.ad; the .ko bytes are always present so the modules.dep
    # walker can find the file path without a separate condition.
    iwlwifi_ko = here / "kernel-modules" / "iwlwifi" / "iwlwifi.ko"
    if iwlwifi_ko.is_file():
        data = iwlwifi_ko.read_bytes()
        name = "/lib/modules/iwlwifi.ko"
        blob += cpio_entry(name, data)
        print(f"  embedded {name} ({len(data)} bytes from "
              f"kernel-modules/iwlwifi/iwlwifi.ko)")

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
