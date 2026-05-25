---
name: feedback-agent-worktree-paths
description: "isolation:worktree agents must edit files in their OWN worktree, never absolute /home/david/Hamnix paths. One agent leaked changes into main."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

Agents dispatched with `isolation: worktree` get their own dir under `.claude/worktrees/agent-<id>/`. They must edit THERE, not the shared `/home/david/Hamnix`.

**Brief language:** never say "Repo root: /home/david/Hamnix". Say: "You are in your own isolated git worktree — work with files relative to your current working directory; never use absolute /home/david/Hamnix paths, those belong to the orchestrator."

**If a leak happens:** changes are uncommitted in main. Don't commit while agent is still running (would capture partial state). Once agent finishes, evaluate+commit from main as that agent's deliverable; empty worktree branch is ignored. If a different agent needs cherry-picking while main is dirty: `git stash` → cherry-pick → `git stash pop`.

## Related
[[feedback-agent-git-discipline]], [[feedback-branch-state-hygiene]]
