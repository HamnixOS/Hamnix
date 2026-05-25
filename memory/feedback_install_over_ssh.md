---
name: feedback-install-over-ssh
description: "Don't pre-bake Debian packages into the default ISO; install them live over SSH against the running OS — that's the actual end-user shape."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

When demonstrating "Hamnix runs Apache" / "Hamnix runs Postgres" / any Linux-userland workload, the workflow MUST be:

1. Boot a vanilla Hamnix ISO (no special package staging at build time).
2. SSH into the running guest.
3. Run `apt update && apt install <pkg>` inside the guest.
4. Configure / start the service.
5. Hit the service from the host (curl, psql, etc.).

**Why:** that's the real-world flow for a server OS. Pre-baking packages into the ISO is a build-system shortcut that hides whether the live OS actually works. "Boot an image → ssh in → apt install" is the demo that proves the OS is real.

**Why a single agent for this kind of demo:** orchestrating multiple SSH sessions or parallel apt installs against the same guest creates lock contention on /var/lib/dpkg, port collisions, and namespace race conditions. One driver, one sequence, the way an actual sysadmin would do it. Multi-step demos are driven from the orchestrator directly (Bash tool against a backgrounded QEMU) rather than dispatched to an Agent.

**How to apply:**
- Don't add `HAMNIX_EMBED_DEBIAN=apache` or similar build-time staging for demo packages. Plumb things like authorized_keys (`HAMNIX_SSH_AUTHKEYS`) — credentials, not packages.
- The cpio-baked busybox in `/var/lib/distros/default/bin/` is fine — it's the bootstrap, not the demo content.
- For multi-cron-tick demos, hold a single backgrounded QEMU across ticks; SSH into it from each tick to advance one step. Don't spin up a second agent in parallel.

Related: [[project-endgame]], [[feedback-debug-print-velocity]], [[feedback-sweeping-agents]].
