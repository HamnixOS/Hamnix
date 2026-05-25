---
name: feedback-build-hygiene
description: "Verify on clean builds. `scripts/_build_lock.sh` auto-wipes compiled outputs per test. Don't `kill -9` builds — leaves truncated artifacts."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

`scripts/_build_lock.sh` auto-wipes `build/user`, `build/mod`, `build/iso`, `build/*.elf`, `build/*.iso`, `fs/initramfs_blob.S` once per test after acquiring the lock. Disk images (`build/*.img`) are spared.

**Don't `kill -9` builds.** Hard kill mid-compile leaves truncated `.elf` files; per-test build is incremental enough to keep them. Subsequent runs produce false FAILures (hamsh not found, all-timeout, zero serial). Burned a whole agent's bisect once.

When verification FAILs on infrastructure-shaped symptoms ("not found", all-timeout, zero serial) — suspect build state before suspecting code. Clean rebuild first.

## Related
[[feedback-agent-test-scope]], [[feedback-sweeping-agents]]
