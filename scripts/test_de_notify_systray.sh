#!/usr/bin/env bash
# scripts/test_de_notify_systray.sh — structural guard for the two new
# DE primitives:
#
#   1. /dev/wsys/notify  — external notification ring buffer.
#                          Write "<glyph>\t<title>\t<body>\n";
#                          snapshot read drains pending; WaitQueue
#                          on the reader for block-read.
#
#   2. /dev/wsys/tray/ctl — system-tray client registration.
#                           Verbs: add/remove/update <client-id> [<glyph>].
#                           Snapshot read renders "<cid>\t<glyph>\n" lines.
#
# Grep-only (no QEMU boot) — same shape as scripts/test_de_snarf_wctl.sh.
# Verifies the kernel surface is wired through devwsys.ad + namec.ad
# (helpers, verb literals, per-entry storage, DEV_ constants, path
# resolvers, read/write dispatches). The compositor adoption (in
# user/hamUId.ad) is the explicit follow-up; this guard does NOT touch
# hamUId.ad.
#
# Pass marker:  PASS: DE notify + systray primitives intact
# Fail marker:  FAIL: <which link broke>

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

WSYS_SRC="sys/src/9/port/devwsys.ad"
NAMEC_SRC="sys/src/9/port/namec.ad"

fail=0

fail_link() {
    echo "FAIL: $1" >&2
    fail=1
}

require_file() {
    if [ ! -f "$1" ]; then
        fail_link "source file missing: $1"
        return 1
    fi
    return 0
}

require_file "$WSYS_SRC"  || true
require_file "$NAMEC_SRC" || true
if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE notify/systray guard — required source file(s) missing" >&2
    exit 1
fi

# --- /dev/wsys/notify ring ---------------------------------------------------
if ! grep -Eq "^def[[:space:]]+devwsys_notify_write" "$WSYS_SRC"; then
    fail_link "notify: devwsys_notify_write() definition gone"
fi
if ! grep -Eq "^def[[:space:]]+devwsys_notify_read" "$WSYS_SRC"; then
    fail_link "notify: devwsys_notify_read() definition gone"
fi
# Ring sizing must stay at the spec'd 16 entries.
if ! grep -Eq "NOTIFY_RING_SIZE[[:space:]]*:[[:space:]]*uint64[[:space:]]*=[[:space:]]*16" "$WSYS_SRC"; then
    fail_link "notify: NOTIFY_RING_SIZE 16-entry ring gone or changed"
fi
if ! grep -Eq "NOTIFY_ENTRY_MAX[[:space:]]*:[[:space:]]*uint64[[:space:]]*=[[:space:]]*256" "$WSYS_SRC"; then
    fail_link "notify: NOTIFY_ENTRY_MAX 256-byte per-entry cap gone or changed"
fi
# Backing storage + ring bookkeeping.
if ! grep -Eq "wsys_notify_buf:[[:space:]]*Array\[4096" "$WSYS_SRC"; then
    fail_link "notify: wsys_notify_buf[4096] backing array gone"
fi
for v in wsys_notify_lens wsys_notify_head wsys_notify_count; do
    if ! grep -Eq "${v}[[:space:]]*:" "$WSYS_SRC"; then
        fail_link "notify: ring-bookkeeping ${v} gone"
    fi
done
# WaitQueue for block-read.
if ! grep -Eq "wsys_notify_wq[[:space:]]*:" "$WSYS_SRC"; then
    fail_link "notify: wsys_notify_wq WaitQueue gone (block-read can't park)"
fi
if ! grep -q "wq_wake_one(&wsys_notify_wq)" "$WSYS_SRC"; then
    fail_link "notify: writer never wakes wsys_notify_wq"
fi
# Public predicate the compositor's block-read recheck uses.
if ! grep -Eq "^def[[:space:]]+wsys_notify_pending" "$WSYS_SRC"; then
    fail_link "notify: wsys_notify_pending() predicate gone"
fi

# --- /dev/wsys/tray/ctl ------------------------------------------------------
if ! grep -Eq "^def[[:space:]]+devwsys_tray_ctl_write" "$WSYS_SRC"; then
    fail_link "tray: devwsys_tray_ctl_write() definition gone"
fi
if ! grep -Eq "^def[[:space:]]+devwsys_tray_ctl_read" "$WSYS_SRC"; then
    fail_link "tray: devwsys_tray_ctl_read() definition gone"
fi
# Three verbs must all parse.
if ! grep -q '"add"' "$WSYS_SRC"; then
    fail_link "tray: add verb literal gone"
fi
if ! grep -q '"remove"' "$WSYS_SRC"; then
    fail_link "tray: remove verb literal gone"
fi
if ! grep -q '"update"' "$WSYS_SRC"; then
    fail_link "tray: update verb literal gone"
fi
# 16-slot cap is the spec.
if ! grep -Eq "TRAY_MAX_ENTRIES[[:space:]]*:[[:space:]]*uint64[[:space:]]*=[[:space:]]*16" "$WSYS_SRC"; then
    fail_link "tray: TRAY_MAX_ENTRIES 16-slot cap gone or changed"
fi
# Per-client storage.
for arr in wsys_tray_id wsys_tray_glyph wsys_tray_glyph_len wsys_tray_used; do
    if ! grep -Eq "${arr}[[:space:]]*:[[:space:]]*Array" "$WSYS_SRC"; then
        fail_link "tray: per-client storage ${arr}[] gone"
    fi
done
# Lookup helpers — without these the verb arms can't dedupe by cid.
if ! grep -Eq "^def[[:space:]]+_tray_find_id" "$WSYS_SRC"; then
    fail_link "tray: _tray_find_id() helper gone"
fi
if ! grep -Eq "^def[[:space:]]+_tray_find_free" "$WSYS_SRC"; then
    fail_link "tray: _tray_find_free() helper gone"
fi

# --- namec.ad wiring ---------------------------------------------------------
# DEV_ constants.
if ! grep -Eq "^DEV_WSYS_NOTIFY:[[:space:]]*int32" "$NAMEC_SRC"; then
    fail_link "namec: DEV_WSYS_NOTIFY constant gone"
fi
if ! grep -Eq "^DEV_WSYS_TRAY_CTL:[[:space:]]*int32" "$NAMEC_SRC"; then
    fail_link "namec: DEV_WSYS_TRAY_CTL constant gone"
fi
# Imports.
if ! grep -q "devwsys_notify_read" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_notify_read not imported"
fi
if ! grep -q "devwsys_notify_write" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_notify_write not imported"
fi
if ! grep -q "devwsys_tray_ctl_read" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_tray_ctl_read not imported"
fi
if ! grep -q "devwsys_tray_ctl_write" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_tray_ctl_write not imported"
fi
# Path resolvers (wsys-level, wid-less).
if ! grep -q '"notify"' "$NAMEC_SRC"; then
    fail_link "namec: #c/wsys/notify path lookup gone"
fi
if ! grep -q '"tray/ctl"' "$NAMEC_SRC"; then
    fail_link "namec: #c/wsys/tray/ctl path lookup gone"
fi
# Read + write dispatches.
if ! grep -q "devwsys_notify_read(off, buf, count)" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_notify_read dispatch gone"
fi
if ! grep -q "devwsys_notify_write(buf, count)" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_notify_write dispatch gone"
fi
if ! grep -q "devwsys_tray_ctl_read(off, buf, count)" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_tray_ctl_read dispatch gone"
fi
if ! grep -q "devwsys_tray_ctl_write(buf, count)" "$NAMEC_SRC"; then
    fail_link "namec: devwsys_tray_ctl_write dispatch gone"
fi

if [ "$fail" -ne 0 ]; then
    echo "FAIL: DE notify/systray primitives BROKEN (see link(s) above)" >&2
    exit 1
fi

echo "PASS: DE notify + systray primitives intact"
exit 0
