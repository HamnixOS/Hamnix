---
name: feedback-grep-before-brief
description: "Before dispatching a \"build X from scratch\" agent, grep the tree for an existing X. The sshd-build agent dispatch on 2026-05-23 hit a fully-implemented user/sshd.ad that I'd forgotten about."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

When briefing an agent to build a substantial new component (daemon, library, driver, subsystem), grep the tree FIRST. Specifically: look for `user/<name>.ad`, `lib/<name>/`, `drivers/<area>/<name>.ad`, and the matching test scripts (`scripts/test_<name>*.sh`). If the component already exists, the brief shifts from "build it" to "finish/debug it" — completely different scope.

**Why:** On 2026-05-23 I dispatched a "native-Adder sshd" agent with a build-from-scratch brief. Hamnix already had `user/sshd.ad` (2078 lines), `lib/ssh/sshcrypto.ad` (30 KiB), `lib/ssh/sshsign.ad` (14 KiB), and three test fixtures, all landed via commits `03a3a18`, `5cd02bb`, `f800cce`, `8e70852`, `0f30263` between 2026-05-21 and 2026-05-23. The agent recovered gracefully (did a useful test-regex fix and identified the actual blocker), but I wasted half a slot pretending the daemon needed to be created.

**How to apply:**

1. Before writing an agent brief that says "implement X," run two greps:
   - `ls user/<x>.ad lib/<x>/ drivers/*/${x}*.ad 2>/dev/null`
   - `git log --oneline -20 -- user/<x>* lib/${x}* drivers/*/${x}*` for recency.
2. If anything exists: shift the brief to "finish X" or "debug specific failure mode in X." Tell the agent up front what's already there so it doesn't waste a slot re-discovering it.
3. Project memory should track what's been built. `project_endgame.md` lists big-arc work; add a "Built and shipped" subsection there as components become real. (Linked: [[project-endgame]].)
4. This is also a counter-bias to my own memory: STATUS.md updates and recent commit messages are the ground truth, not what I "feel" exists in the tree.

Related: [[feedback-sweeping-agents]] (briefing scope), [[project-endgame]] (component inventory).
