---
name: project-next-agent-queue
description: Ordered queue of single-agent tasks. Dispatch earliest unblocked when a slot opens.
metadata: 
  node_type: memory
  type: project
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

## Queue

### 1. LANGUAGE.md scrutiny audit (queued 2026-05-23)

User: *"Scrutinize the living shit out of the language file and make sure what we've documented is actually correct."*

For each section: verify against `compiler/lexer.py` + `parser.py` + `codegen_x86.py` AND grep for production usage. Delete fiction. Suspect sections: Dynamic list/Dict/Tuple/Optional, Lambda, `match`/`case`, `try`/`except`, `with`, decorators, default args, tuple unpacking in for-loop, list comprehensions, f-strings, string slicing, dict ops. Output: cleaned LANGUAGE.md trustworthy 100%.

### 2. Convert user-binary fixed BSS arenas → heap-backed (queued 2026-05-23)

User: *"Why is memory constrained so much?"*

Inventory `Array[NNNN, ...]` in `user/*.ad` (distrofs, dpkg, apt). Convert to `kmalloc`-at-init OR grow-on-demand realloc. The "no heap allocator" belief is a myth ([[feedback-compiler-quirks]]). Land after #1 so the doc reflects heap prominently. Verify: distrofs holds MBs not 40 MiB-each; `apt install` works on 256 MiB guest.

### 3. Hamsh installer + boot-from-disk

User: *"It'd be really cool to see you boot up an image, install it, reboot, SSH in, install packages, set up a web server."* + *"I'm leaning towards making that installer written in hamsh."*

`/etc/install.hamsh` plain-hamsh installer using namespace verbs. Needs `partition` (GPT/MBR), `mkfs.ext4`, `mkfs.fat`, `distrofs-init`. End-to-end demo: ISO → install → reboot → SSH → apt install → curl from host.

### 4. Marquee web-server demo (gated on #3)

`spawn detached linux { /usr/sbin/nginx }` in `/etc/rc.boot`. Host `curl http://127.0.0.1:18080/`. Victory-lap demo.

## Discipline
Each cron tick: dispatch top unblocked item when slot opens. Remove as items complete.
