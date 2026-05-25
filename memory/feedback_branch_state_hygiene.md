---
name: feedback-branch-state-hygiene
description: "Don't `git update-ref` to fast-forward a checked-out branch. cd to /home/david/Hamnix and pwd-defense before any git op — background scripts drift cwd."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

## The trap

`git update-ref refs/heads/main <agent-branch>` moves the branch pointer but does NOT update the working tree. The next `git commit` lands on top of the OLD STATE — reverts the cherry-picked work. Bit me 2026-05-23 (`6fef517` reverted by `aa26f86`) and again 2026-05-25 (cwd-drift variant).

## Standard pattern that works

```
cd /home/david/Hamnix  # always absolute
git fetch /home/david/Hamnix/.claude/worktrees/agent-<id> worktree-agent-<id>
git cherry-pick <sha>
```

## Defenses

1. **`cd /home/david/Hamnix`** before any git op. Always absolute. Background scripts drift cwd into agent worktrees.
2. **`pwd` + `git branch --show-current`** if anything feels off. If branch name is `worktree-agent-*`, you're not on main.
3. **Recovery** if cherry-pick lands on a stray branch: `cd /home/david/Hamnix; git checkout main; git cherry-pick <good-sha>` to re-apply on real main.
4. **Use `git pull --ff-only`** or `git merge --ff-only <ref>` — never `git update-ref` on a checked-out branch.

## Related
[[feedback-agent-git-discipline]], [[feedback-build-hygiene]]
