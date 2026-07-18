# hambrowse — a USABLE browser: link navigation + form submission

This is the usability tier of the browser campaign: hambrowse stops being a
one-shot *renderer* and becomes a *browser* you can drive — a link click loads
the next page, and a form submit sends data to a server and renders the reply.
All of it goes over the same Plan 9 `/net` client (`user/http9.ad`) the rest of
the browser uses; **no sockets are introduced**.

## What already worked (verified, not rebuilt)

The engine (`lib/web/dom/canvas.ad`) and the front-end (`user/hambrowse.ad`)
already carried most of the machinery:

- **Link resolution + fetch.** `_resolve()` resolves an `<a href>` against the
  current URL — absolute (`http(s)://…`), root-relative (`/path`), and
  document-relative (`foo.html`) — into `nav_buf`; `_navigate()` then `_fetch`es
  it (http9 `http_get`, following 3xx redirects) and re-lays-out. A real pointer
  click already routes a hit-tested `<a>` through this path.
- **Form GET serialization + navigation.** A submit (Enter in a field, a submit
  button, or JS `form.submit()`) fires the engine's `_do_submit` → `_serialize_form`,
  which URL-encodes the named controls (`<input>`/`<select>`/`<textarea>`,
  checked checkbox/radio, selected option) into `he_nav_*`. The front-end's
  `_navigate_form()` resolves the target and `http_get`s `action?a=1&b=2`.
- **Constraint validation, submit event bubbling/preventDefault, input value
  get/set** — all pre-existing (see `test_hambrowse_formsubmit_host.sh`,
  `test_hambrowse_formvalid_host.sh`).
- **URL bar + Back/Forward history** (`lib/browserhistory.ad`) — every navigation
  syncs the address bar and pushes onto the session history stack.

## What this change added

The one genuine gap was **POST**: `_serialize_form` already produced the correct
`method=POST` split — a bare action in `he_nav_ptr()` plus the urlencoded body in
`he_nav_body_ptr()` (`he_nav_method()==1`) — but the front-end `_navigate_form()`
ignored the method and always `http_get`-ed. A `<form method=post>` therefore
went out as a GET with an empty body.

- `user/hambrowse.ad`:
  - imports `he_nav_method` / `he_nav_body_ptr` / `he_nav_body_len`.
  - `_navigate_form()` now captures the method + POST body **before**
    `he_nav_clear()` wipes them, and branches: GET → `_fetch` (unchanged);
    POST → new `_fetch_post()`, which sends the body via http9 `http_post` with
    `Content-Type: application/x-www-form-urlencoded` and renders the reply.
  - `_fetch_post()` mirrors `_fetch`'s status/redirect/diagnostic handling and
    emits a `[hambrowse] form-POST http status=… reqbytes=… bytes=…` serial line
    so a gate can prove a POST (not a GET) left the browser.
  - **On-load submit drain.** After the first layout, `main()` now drains a
    pending navigation (`_navigate_form()`), so a page whose script calls
    `form.submit()` during load actually navigates — the same drain the event
    loop runs after a user submit.
  - **`--click-link N` test entry.** After load, programmatically fires
    `_navigate(N)` — the *real* click-navigate path — so a gate can drive a link
    click over the wire without flaky pointer/keyboard injection.

## Tests

- `scripts/test_hambrowse_navigation_host.sh` — FAST, QEMU-free. Compiles both
  targets (regression guard on the new glue) and asserts the engine emits exactly
  what the front-end consumes: a captured `<a href>` is a clickable link-table
  entry; a GET form → `action?query`; a POST form → bare action + `NAV POST` +
  urlencoded `BODY`. Registered in `ci_battery_manifest.txt`.
- `scripts/test_hambrowse_navigation_ondevice.sh` — LIVE OVMF/KVM boot with a
  host HTTP server. (1) `hambrowse …/start.html --click-link 0` resolves
  `<a href="/page2.html">` and GETs it — asserts the host log shows
  `GET /page2.html` + a 2nd guest fetch line. (2) a page whose on-load
  `form.submit()` POSTs to `/login` — asserts the host log shows `POST /login`
  with the urlencoded body + `[hambrowse] form-POST http status=200`.

## Deferred (documented, not implemented)

- **Fragment-only navigation (`#id`)** — `_resolve` treats a `#`-only href as a
  no-op (no reload, which is correct) but does not yet *scroll* to the anchor;
  scroll-to-id needs an element-position lookup in the layout tree
  (`lib/web/layout/*`, out of this change's scope).
- **JS-driven / SPA navigation** — `location.assign()` / `location.href = …`
  update the headless `location` object but do not trigger a front-end
  navigation. Wiring a navigation intent onto location writes is the next rung.
- **`target=_blank` / new-window** — always navigates in place.
- **`multipart/form-data` (file upload)** — only
  `application/x-www-form-urlencoded` is serialized; `<input type=file>` bodies
  are not built.
- **POST across Back/Forward** — history re-fetches a POSTed URL as a GET (no
  body replay); matches the low-fidelity end of real-browser behavior.
