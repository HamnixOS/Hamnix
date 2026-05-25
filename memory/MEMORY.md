# Project Memory Index

## Project direction & state
- [Endgame: Linux ABI + Debian distro](project_endgame.md) — L-series (kernel ABI) → U-series (userspace ABI) → NVIDIA → ship as a real distro consuming Debian repos
- [Endgame cadence](project_endgame_cadence.md) — multi-day autonomous run: hourly cron + up to 2 parallel agents, until "everything debugged"
- [x86_64 backend decision](project_x86_backend_decision.md) — Adder's backend is a hand-written x86_64 encoder (codegen_x86.py), NOT LLVM
- [M16 boot path](project_m16_boot.md) — boot history; kernel is now elf64-x86-64, higher-half @0xffffffff80000000, tests boot via an ISO shim
- [Real-hardware boot](project_real_hw_boot.md) — boots on a real Asus laptop in both Legacy/BIOS and UEFI (2026-05-20); remaining gap: no keyboard input
- [fork() — RESOLVED](project_fork_broken.md) — fork() now gives the child a real private per-process address space (eager-copy, b8e0398); COW is the remaining optimization
- [VMA MAX_ORDER — RESOLVED](project_vma_maxorder_limit.md) — VMA allocator backs >4 MiB allocs with multiple buddy chunks (b8e0398); 8 MiB glibc pthread stacks work
- [Core stabilization](project_core_stabilization.md) — ongoing: hunt agent-introduced workarounds and patch them out of the core fundamentally
- [Plan 9 pivot](project_plan9_pivot.md) — per-process namespaces / 9P model; V4.1 (kernel↔userland 9P real-fd) and V4.2 (rio-shape server) still pending
- [Rio open questions](project_rio_open_questions.md) — design Qs from docs/rio.md pending user input before the rio GUI is built
- [hamsh rewrite](project_hamsh_rewrite.md) — clean-sheet shell rewrite (docs/HAMSH_SPEC.md): single Python-flavored language, no Adder; built by one sweeping agent
- [Next-agent queue](project_next_agent_queue.md) — ordered queue of single-agent tasks awaiting dispatch when the current slot opens (LANGUAGE.md audit, BSS-to-heap conversion, hamsh installer, marquee web demo)
- [e1000e.ko pivot](project_e1000e_ko.md) — load Linux's stock e1000e.ko via Hamnix's loader; 80/190 symbols missing, 8-15h focused work, payoff reusable for every Linux NIC driver

## Working with this codebase
- [Working agreements](feedback_working_agreements.md) — propose language extensions over user-code workarounds; fix bugs at the right layer; small commits that boot
- [Adder compiler quirks](feedback_compiler_quirks.md) — compiler bug log; U9 nested-Array & string-literal globals FIXED; adjacent string-concat still unsupported
- [Fix don't catalogue](feedback_fix_dont_catalogue.md) — fix root causes then and there; pay back tech debt found; don't accumulate "X is broken" reports
- [Fix the language layer](feedback_fix_the_language_layer.md) — recurring agent hiccups get fixed in the Adder compiler, not worked around; keep the language simple
- [Build hygiene](feedback_build_hygiene.md) — verify on clean builds; _build_lock.sh auto-wipes compiled outputs per test; don't kill -9 builds
- [Debug-print velocity](feedback_debug_print_velocity.md) — diagnostic-print-only commits ship after a build, not after the full test sweep; keep the hardware-bring-up cycle short
- [Install over SSH](feedback_install_over_ssh.md) — never pre-bake demo packages into the ISO; boot vanilla, SSH in, apt install live. One driver, no parallel agents on a shared guest.
- [Branch state hygiene](feedback_branch_state_hygiene.md) — when cherry-picking from a worktree branch, never `git update-ref` to fast-forward a checked-out branch; the working tree won't sync and the next commit reverts. Use `git pull --ff-only`.
- [Sweeping single-agent jobs](feedback_sweeping_agents.md) — for large architectural topics, dispatch one agent with whole-worktree authority; don't fragment
- [Agent git discipline](feedback_agent_git_discipline.md) — agents work in isolation:worktree; orchestrator is sole writer to main; agents never edit README/TODO/CLAUDE
- [Agent test scope](feedback_agent_test_scope.md) — agents run the test that targets their change; orchestrator runs broad verification at cherry-pick time
- [Agent worktree paths](feedback_agent_worktree_paths.md) — isolation:worktree agents edit their own worktree, never absolute /home/david/Hamnix paths
- [Grep before brief](feedback_grep_before_brief.md) — before briefing a "build X" agent, grep user/lib/drivers and recent commits for an existing X; sshd already existed
- [Plan 9 namespace framing](feedback_plan9_namespace_framing.md) — no global root; namespaces are per-process bindings to file servers, not sandboxed views
- [Distro namespace](feedback_distro_namespace.md) — Linux-binary shims run in a distro-shaped namespace served by a userland distrofs 9P daemon; no global paths
- [Loading vs working](feedback_loading_vs_working.md) — the product is shim genericity, not per-driver completeness. e1000e is the proof-of-concept; every other .ko is a coverage probe. One exercise test per subsystem class is enough.
- [No sockets — Plan 9](feedback_no_sockets.md) — Hamnix has NO native socket()/sendto()/recv(). Net I/O is kernel udp_send/icmp_send/dns_lookup OR userland /net Plan 9 ops via user/net9.ad. Don't brief agents with socket-shaped APIs.
- [Orchestrator is the architecture guardrail](feedback_orchestrator_architecture_guardrail.md) — agents trust the brief and don't push back. Verify architectural assumptions BEFORE writing the brief. Grep for actual function names, read the relevant subsystem files, name existing primitives explicitly.
- [No time budgets in briefs](feedback_no_time_budgets.md) — agents code as long as needed. Time budgets push toward stubs and shortcuts. Use scope/constraint/deliverable/escalation-rule language, never timers.
- [Let agents run wild](feedback_let_agents_run_wild.md) — broader than no-timers: stop file-scope micromanagement, single-commit mandates, "stop on architectural blockers." Empowerment language. Orchestrator handles merges so the agent shouldn't.
