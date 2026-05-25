---
name: feedback-fix-dont-catalogue
description: "Fix bugs and pay back tech debt then-and-there. Don't accumulate 'X is broken' hand-offs. Solidifying the base is continuous."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

User (2026-05-20): *"Let's make sure the base works and we can close those gaps. We don't want a bunch of agent nodes saying which things are broken; we want to fix them as they are found."*

**Default to FIXING, not cataloguing.** Give agents scope to fix the ROOT CAUSE, not just a narrow patch. If a fix plausibly needs a neighbouring file, grant it up front.

**STOP-and-report is for genuine architecture-decision forks** (two legitimate designs, user should pick) — NOT for "the fix needs a file I wasn't given." If an agent keeps stopping for scope, re-dispatch wider.

**Pay back tech debt continuously.** When tripping over pre-existing debt while doing other work — a workaround, stale comment, dead branch, ergonomic trap — pay it down in the same cycle. Standing posture, not a phase.

**Caveats:** don't balloon scope past what can be verified; large debt-paybacks (e.g. name-resolution redesigns) get their own job. "Fix it" never means "fix it sloppily" — broad verification before merge.

**Fenced files** (e.g. `syscall_64.S`) mean "ask before touching," not "never fix bugs there." Surface to user for one-time grant rather than leaving broken.

## Related
[[feedback-working-agreements]], [[feedback-fix-the-language-layer]], [[feedback-let-agents-run-wild]], [[project-core-stabilization]]
