# Documentation Conventions

This file defines how Hamnix's documentation is structured and how it is
kept in sync with the source. It exists so that **a human can navigate
the docs** and **a bot can update one subsystem doc after a code change
without guessing where things live.**

Read this before editing any doc under `docs/`.

---

## What is source-of-truth and what is documentation

| Artifact | Owner | Rule |
|--|--|--|
| `STATUS.md` | orchestrator | **Append-only milestone history. Never rewrite.** |
| `CLAUDE.md` (root + subdirs) | agent harness | **Never edit.** |
| `.ad` / `.S` / `scripts/*` source | code agents | The ground truth. Docs describe it; they do not define it. |
| `README.md` | orchestrator | Project front page + doc index entry point. |
| `TODO.md` | orchestrator | Open work. |
| `docs/**` | docs maintainer | Everything described here. |

The single most important rule: **every statement in a subsystem doc
must be verifiable against current source.** If you cannot confirm a
claim by reading the cited file, delete the claim. Accuracy over volume.

---

## Directory layout

```
docs/
  README.md            Top-level navigation index (the map). Reachable from /README.md.
  CONVENTIONS.md       This file.
  subsystems/          One doc per subsystem (the bulk of the content).
    <subsystem>.md
  <topic>.md           Long-form design / spec docs that predate this rework
                       (9p.md, architecture.md, de_scene_file_arch.md, HAMSH_SPEC.md, ...).
```

Subsystem docs live in `docs/subsystems/`. Cross-cutting design specs
and reference material that is not a single code subsystem (the 9P wire
format, the layered architecture model, the hamUI protocol, the hamsh
language) keep their existing top-level `docs/*.md` names; the index
links to both.

---

## Per-subsystem doc template

Every file in `docs/subsystems/` MUST follow this section order. A bot
updating a doc edits the section that matches the change; the fixed
layout is what makes that mechanical.

```markdown
# <Subsystem Name>

> **Source of truth:** <bulleted list of the exact files/dirs this doc describes>
> **Last verified against source:** <YYYY-MM-DD or commit hash>

## Purpose
One or two paragraphs: what this subsystem does and why it exists in a
Plan-9-shape OS.

## Key files
Table: `path` → role. Only files that exist (verify with `ls`).

## Architecture & data structures
The main structs/classes (named, with `file:line` or `file:def name`),
how they relate, and how the subsystem fits the namespace/file-server
model.

## Entry points
The functions other subsystems call into, named, with a one-line
contract each. Cite `file` (and `:line` where stable).

## Invariants & gotchas
Things that will silently break if violated; non-obvious constraints;
known gaps. This is where hard-won knowledge lives.

## Related docs
Cross-links to other subsystem docs and to design specs.
```

The `Source of truth` header line is the bot's anchor: it lists exactly
which files, when changed, should trigger a re-read of this doc.

---

## Conventions for both humans and bots

- **File names are lowercase, hyphen-or-underscore, stable.** Don't
  rename a subsystem doc once linked; the index and cross-links depend
  on it. If a subsystem is renamed in source, update content in place.
- **Cite source locations.** Prefer `path/to/file.ad` and a function or
  struct name (`def foo`, `class Bar`) over line numbers, because line
  numbers drift. Use line numbers only as a hint, never as the sole
  reference.
- **Link relatively** between docs (`./networking.md`,
  `../architecture.md`) so links survive a moved tree.
- **No invented APIs.** If you describe a function, it must appear in
  source. Grep before you write.
- **Plan-9 framing, verified.** Hamnix has per-process namespaces, file
  servers, and `#x` device binding — NOT global POSIX paths. It has NO
  native `socket()` (net I/O is kernel ops or the `/net` file tree).
  State each such claim only where the cited code backs it.

---

## How a bot keeps a doc in sync after a code change

1. Identify which subsystem(s) the changed file belongs to by matching
   the path against each doc's **Source of truth** list (grep the docs
   for the changed path).
2. Open the matching `docs/subsystems/<name>.md`.
3. Re-read the changed source. Update only the sections whose facts
   changed (usually **Key files**, **Architecture & data structures**,
   **Entry points**, or **Invariants & gotchas**).
4. Update the `Last verified against source` line.
5. Do not touch `STATUS.md` / `CLAUDE.md`. Do not invent unverified
   claims. If a feature was removed, remove its doc text rather than
   marking it stale.

A new subsystem gets a new file in `docs/subsystems/` (copy the
template) and one row added to the table in `docs/README.md`.
