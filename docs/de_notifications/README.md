# Scene-native DE notifications

MATE-parity desktop notifications for the production runlevel-5 scene DE,
where the kernel scene compositor owns `/dev/fb` and the legacy hamUId-blit
notification clients (`hamnotif`/`hamtray`) paint nothing.

## Architecture (Plan 9-shaped)

```
publisher (welcome svc / rc / hamnotify CLI)
    │  writes "<title>\t<body>\t<icon>\n"
    ▼
/dev/wsys/post           kernel inbox ring (8 slots) — the notification BUS
    │  drained each tick by the panel BROKER
    ▼
user/hampanelscene.ad  (the panel is a long-lived scene client)
    ├─ spawns /bin/hamtoast "<title>" "<body>"   transient top-right toast
    ├─ appends to /tmp/hamnix-notif.log          inbox history (capped ring)
    ├─ bumps the tray bell unread-count badge
    └─ writes "ack <slot_serial>\n" back to /dev/wsys/post (head advances)

tray bell click ──▶ spawns /bin/haminbox  (reads the history log) + marks read
```

The kernel `/dev/wsys/post` ring already persists records without a draining
daemon, so the panel — the one always-running scene client — is the natural
broker. No new kernel code; no global-path bypass.

## Components

- `user/hamtoast.ad` — scene toast popup (top-right, auto-dismiss ~4s or on
  click). Title/body via argv. `decorate 0` so it stays out of the taskbar.
- `user/haminbox.ad` — scene notification inbox listing recent notifications
  newest-first from `/tmp/hamnix-notif.log`; Escape / Close / click-outside
  dismisses.
- `user/hampanelscene.ad` — the broker + tray bell badge (`notif_unread`),
  `_drain_notifications()` / `_read_post_head()` / `_nlog_append()` /
  `_spawn_toast()` / `_ack_slot()`.
- `user/hamsh.ad` — `_svc_argv_tokenize` made quote-aware so the welcome
  service's `exec: /bin/hamnotify "Welcome to Hamnix" "DE up"` passes the
  multi-word title/body as single args.
- `scripts/test_de_notifications.sh` — structural regression guard.

## Visual proof (booted installer image under OVMF/KVM)

- `welcome_toast.png` — the login welcome toast (top-right, "Welcome to
  Hamnix" / "DE up") + the tray bell with a red unread "1" badge.
- `inbox_open.png` — the inbox window opened from the tray bell, listing
  three notifications newest-first, badge cleared.
