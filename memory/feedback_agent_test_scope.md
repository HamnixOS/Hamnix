---
name: feedback-agent-test-scope
description: Agents run only the test that targets their change. Orchestrator runs broad verification at cherry-pick time.
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

Don't make agents run the full QEMU regression suite. 15-minute agent waits became the norm — most was QEMU-boot acceptance gates run serially. The V7 TLS agent burned 100+ min monitoring its own suite before conversation budget ran out (work functional but never committed).

## Apply

**Agent's acceptance gate:**
- The narrow test that targets THIS change
- Lexer fixtures (`python3 compiler/lexer_test.py`, `scripts/test_lex_*.sh`) — sub-second
- That's it. Skip full `run_compiler_tests.sh`, both boot tests, unrelated tests.

**Orchestrator's verification (at cherry-pick on main):**
- `run_compiler_tests.sh` + the two boot tests + test families touching the same subsystem
- If broken: revert + re-task

**Exceptions:**
- Compiler changes: agent DOES run `run_compiler_tests.sh` (codegen bugs regress silently elsewhere)
- Pure userland (new `user/foo.ad`): skip boot tests entirely

Prompts should explicitly say "DO NOT run the full regression suite; run only <X>."

## Related
[[feedback-agent-git-discipline]], [[feedback-let-agents-run-wild]]
