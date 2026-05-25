---
name: feedback-debug-print-velocity
description: "Debug-print-only changes ship after a build, not after a full test sweep — keep the hardware-bring-up loop fast."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

For commits that only add diagnostic prints (boot checkpoints, hamsh markers, heartbeat ticks, sub-step breadcrumbs, etc.), do NOT run the usual `test_uefi_boot.sh` / `test_bios_boot.sh` / `test_hamsh_lineedit.sh` / regression sweep before pushing. Cherry-pick → `bash scripts/build_iso.sh` → push → hand the user the fresh `build/hamnix.iso`. That's the cycle they want.

**Why:** During a real-hardware bring-up, the bottleneck is photo-back-to-orchestrator loop time — minutes vs the user's available testing window. Debug prints are by construction low-risk (no behavior change, no path change). A successful build is sufficient proof.

**How to apply:**
- Use this for commits whose diff is exclusively `printk0("...\n")` lines, `sys_write(2, "...", N)` markers, or similar pure-additive diagnostic output (including hand-rolled syscall markers in `.S` files).
- Still do the full sweep for substantive code (kernel logic, syscalls, fs layer, namespace shape, IP/networking, mm/COW, anything in a poll loop, anything that changes a return value).
- When in doubt, ask the user.
- The verb-shape: "cherry-pick → build → push → ping user with ISO path." Not "cherry-pick → test → test → test → push → maybe build."

Related: [[feedback-working-agreements]], [[project-real-hw-boot]].
