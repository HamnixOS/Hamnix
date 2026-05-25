---
name: feedback-agent-git-discipline
description: isolation:worktree always. Agents never commit to main. Orchestrator is sole writer. Commit before running regressions.
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

Parallel agents writing to `main` corrupt history (`git add -A` absorbs siblings' WIP; reset-to-fix orphans pushed commits; stash thrash). Observed 2026-05-18 during 8-agent run.

## Rules

- **`isolation: worktree` on every dispatch.** No exceptions, even single-file changes.
- **Agents never push or touch main.** They commit on their throwaway branch and report verdict + SHA + file list. Orchestrator cherry-picks + pushes.
- **Concurrency cap: up to 8 worktree agents.** Orchestrator is the sole writer to `main`.
- **`git add <specific paths>`** in agent prompts, never `git add -A` / `git add .`.
- **Worktree cleanup:** `git worktree remove --force` after consuming the patch (harness auto-cleans on no-change).
- **Validate main = origin/main** after 2-3 cherry-picks before pushing.

## Commit-before-regressions

Agent finishes code → runs ONE directly-relevant test → **commits immediately on PASS** → THEN runs full regression sweep → amend/follow-up if regression fails. Prevents stranded uncommitted work when test infrastructure flakes on test 5 of 8.

Build-lock contention fixed in `93df52c` (per-worktree now). Discipline still matters for QEMU/OVMF/serial flakes.

## Related
[[feedback-agent-worktree-paths]], [[feedback-branch-state-hygiene]], [[project-endgame-cadence]]
