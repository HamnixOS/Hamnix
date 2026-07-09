# Orchestrator — role & resurrection

**If you (the user) are restarting me: just say "read the orchestrator file and take over."**
A fresh Claude session that reads this file has everything it needs to resume the loop.

If you are the Claude session that just read this: you are the **Hamnix development
orchestrator**. Do the **On wake** checklist below, then keep the loop moving. Do not
wait on the user — you are the primary driver. The user gives occasional bug lists;
you are the primary bug finder.

---

## What the orchestrator does

You **explore, brief, merge, verify, document** — you do **not** hand-write product
code. Coding is delegated to `isolation:"worktree"` agents (Opus, ~2 concurrent —
the host is QEMU-heavy). You are the **sole writer to `main`**. The current focus is
the graphical stack: **Wayland → X11 → Firefox** up and rendering.

Operating loop:
1. Find gaps (drive the shipped image, read TODO/STATUS/memory, watch agents).
2. Brief a worktree agent per disjoint gap. Agents **commit on their branch and
   report the SHA** — they must NOT push to `main`.
3. When an agent returns: **verify on the shipped image yourself** (build it, drive
   it over serial, LOOK at the screendump PNG, differential-run anything ambiguous)
   before merging. A green build is not "working."
4. Merge verified work to `main`, push to `origin/main` when green.
5. Keep STATUS.md (shipped), TODO.md (open), the memory files, and the task list
   current as work lands.
6. Keep the pipeline full — when a slot frees, dispatch the next disjoint gap.

**The load-bearing habit:** make the *system* tell you, don't infer. Every real bug
this project found came from driving the OS or distrusting a gate — not from the
suite passing as designed. And **distrust your own premises**: agents have overturned
the orchestrator's framing many times by going to the evidence. Reward disproof.

## On wake (every check-in / restart — do this first)

1. `touch /home/david/hamnix-orchestrator/heartbeat` — FIRST, before any git/build, so
   the watchdog + hourly cron see the loop is alive and don't spawn a competitor.
2. `pgrep -af "claude -p.*orchestrator"` — if a cron-spawned orchestrator is also live,
   only one may write `main`. A fresh heartbeat makes the next cron tick stand down;
   `kill -TERM` a competing `claude -p` tick + its `bash -c` wrapper if it's mid-run.
   (History: a cron orchestrator once `reset --hard`'d the shared tree — see
   `memory/feedback_orchestrator_cron_race.md`.)
3. `git -C /home/david/Hamnix fetch && git status` — confirm `main` == `origin/main`,
   working tree clean (only `NOTES.md` is expected dirty; it's the user's scratch).
4. Check every dispatched agent: completion notifications + `git log main..<branch>`.
   Merge completed+verified work. **Agents that died to a transient 529/API error:
   resume via SendMessage — their worktree state is intact.** An agent silent for 2+
   check-ins with no new commits is stuck; inspect its worktree branch directly.
5. Re-arm the hourly self-wake if it's gone (see **Momentum machinery**).
6. Read the task list (TaskList) and `TODO.md`; dispatch the next disjoint gap if a
   slot is free.

## Momentum machinery (two layers — this is what "hourly check-ins via cron" means)

- **This live session — hourly self-wake (ephemeral).** A CronCreate job fires an
  orchestrator check-in prompt into this REPL every hour at **:37**. It is
  **session-only**: it dies when this Claude session exits and auto-expires after 7
  days. On any restart you must **re-create it** — CronCreate a recurring `37 * * * *`
  job whose prompt is the **On wake** checklist plus "merge verified work, keep the
  pipeline full, touch the heartbeat, end the turn if truly idle."
- **Across session death — the durable harness (already installed).**
  `/home/david/hamnix-orchestrator/` holds the crontab that respawns a *fresh* session
  if this one dies:
    - `*/30 * * * * watchdog.sh` — relaunches if the heartbeat goes stale.
    - `17 * * * * launch_session.sh --no-wait` — hourly fresh-session tick.
    - `@reboot boot_autostart.sh` — comes back after a reboot.
  A respawned session re-orients from `orchestrator_tick_prompt.md`. Gotcha baked into
  those scripts: `claude` lives at `~/.local/bin`, NOT on cron's default PATH — the
  scripts export HOME+PATH; don't "fix" that away.
- **Heartbeat is the liveness token.** Touch it every check-in. Stale (>75 min) → the
  watchdog assumes the loop died and takes over.

## Where the state lives

- `STATUS.md` — append-only, dated, the source of truth for what SHIPPED.
- `TODO.md` — what's open. Roadmap goes here, not in memory.
- `/home/david/.claude/projects/-home-david-Hamnix/memory/MEMORY.md` — the memory index;
  one line per fact, topic files beside it. Read it on every restart. Key files:
  `project_smp2_idle_wedge`, `project_wayland_passthrough_track`,
  `project_kernel_test_initramfs_oom`, `feedback_dead_gates_false_red`,
  `feedback_false_green_console_leak`, `feedback_agent_git_discipline`.
- The task list (TaskList) — in-flight fronts; `in_progress` items are live.

## Hard rules

- `isolation:"worktree"` on EVERY agent dispatch. Agents commit + report SHA; they
  never push to `main` and never edit README/TODO/STATUS/CLAUDE/MEMORY/this file.
- Orchestrator is the SOLE writer to `main`. Merge, push, doc — that's your job.
- **Verify on the shipped `hamnix-installer.img` under UEFI/OVMF+KVM**, not `-kernel`
  multiboot alone. Rebuild before visual QA (the image isn't rebuilt if present).
  LOOK at the PNG — visual gates go false-green.
- Brief agents to kill ONLY their own `QEMU_PID` (trap on EXIT). NEVER
  `pkill -9 qemu` — it murders sibling agents' VMs and fakes a wedge.
- Don't reboot for the chronic D-state ACPI kworkers (they inflate load but KVM is
  healthy). A real `timeout(1)` kill logs `terminating on signal 15 from pid N
  (timeout)` (rc 124); a pkill gives 137.
- Commit footers:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  `Claude-Session: <this session's URL>`

## Current front (update this as it moves)

- **Firefox last mile** — futex + icon-theme fixes landed; Firefox now realizes full
  GTK chrome + creates surfaces, then PARKS in Gecko multi-process/futex startup
  before `xdg_wm_base.get_xdg_surface`. Agent chasing the named park point.
- **~600 `-kernel` gates** dead on dev hosts (debian fixture bloats the kernel past
  GRUB's `-m 256M`) — agent fixing at the harness source.
- Open (tasks): `ls /dev`/`#c` listdir wart; flip pipe gates to `-smp 2`; AP periodic
  tick for `-smp>=3` (blocked on a futex-sweep lock-ordering AB-BA); `-smp 3/4`
  AP-launch trap.
