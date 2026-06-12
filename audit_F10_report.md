# Audit F10 — second-pass architecture audit (post P9-shape hammer wave)

Read-only. Base: `52812182`. Worktree: `/home/david/Hamnix/.claude/worktrees/agent-a9492a2e3b7ce4716`.

The wave that landed today closed eight of nine #444 findings on paper, but a fresh-eyes pass shows two of them held *structurally*, three held *only in the headline*, and three new structural divergences are now visible. Detail below.

---

## 1. F1-F6/F8/F9 hold check

| Finding | Status | Grep / evidence |
|---|---|---|
| **F1** namespace substrate rewrite | **HELD** at the kernel level; **REGRESSED IN INTENT** at the dispatch level (see Goal 2 axis 4). The veneer functions are gone — `grep -rn 'chan_resolve_prefix\|_union_head_slot\|_union_best_len\|_union_member_priority\|_union_band_match\|_synth_ns_seg\|_is_synth_dev_path' --include="*.ad"` returns only docs and one F1-substrate **comment** at `sys/src/9/port/chan.ad:1853`. `ns_walk` is live in `sys/src/9/port/chan.ad:1975`. BUT `vfs_open` calls `_vfs_open_post_perm` directly with the user-supplied path — it never runs `resolve_path`. The "unbound = ENOENT" gate is therefore **only enforced for paths that hit the cpio/ext4/tmpfs disk routing**. Paths matched by namec's `_devtab_lookup` (38 literal `/dev/<leaf>` strcmps at `sys/src/9/port/namec.ad:837-927`) or by `_path_owning_server`'s fallthrough-to-cpio (line 1542) bypass the namespace walk entirely. `test_ns_enoent` proves only the on-disk leg. |
| **F2** drift syscalls → ctl-files | **PARTIAL.** The new ctl files exist (`/proc/<pid>/ctl pri`, `/proc/svc/ctl`, `/net/dns/lookup`, `/dev/wsys/ctl`) and userland callers can use them. BUT every retired syscall arm is **still wired and still fully implemented** in `arch/x86/kernel/syscall.ad` (SYS_NICE @ 3008, SYS_SVC_CTL @ 3644, SYS_NETCFG @ 3839, SYS_RESOLVE @ 4079, SYS_RESOLVE_PTR @ 4121, SYS_WSYS_* @ 3729/3770) with full bodies, not thin pass-throughs to the ctl-file logic. Comments admit "deprecated thin shim around the same kernel helper" but they are not shims — they re-implement the work. Userland still calls the syscalls (`SYS_NICE` is used by `user/nice_hi.ad`, the others by their pre-F2 callers). |
| **F3** server-boundary perm enforcement | **PARTIAL — closer to NAME ONLY.** `_vfs_check_perm` and the `vfs_auth_mediator_active` flag are gone (`grep -rn '_vfs_check_perm\|vfs_auth_mediator_active'` is comments only). `chan_permission_check` (`fs/vfs.ad:1546`) dispatches to per-server `_perm_check_<X>` (`fs/vfs.ad:1297-1453`). BUT — except for cpio (mode-bit lookup), ext4 (delegated to `ext4_perm_check`), and devblk (`uid==1` only) — every other `_perm_check_<X>` is a no-op stub that returns 0 with the rationale "let the backend decide". The promise is that the server enforces; the truth is the docs/security.md table over-claims. tmpfs, devcons, devproc, devsrv, devnet, devauth, FAT, rootslot all grant unconditionally. Plus the dispatcher's `uid==1` blanket bypass on cpio reads + all ext4 ops (lines 1571-1586) means hostowner skips even the cpio mode bits. Since every newly-spawned task starts uid=1 (see `kernel/sched/core.ad:2532`), this is effectively "no perm gate" until login downgrades. |
| **F4** linux_abi/ is a leaf | **HELD.** `grep -rn '^from linux_abi\|^import linux_abi' arch/ fs/ sys/ kernel/ drivers/ mm/ --include="*.ad"` returns ZERO real imports — only F4-substrate comments. All linux_abi → native references are hook-pointer registrations from `linux_abi/init.ad` (and matching `register_*_hook` plants in fs/vfs.ad / arch/x86/kernel/syscall.ad). `init/main.ad` retains its import block explicitly out-of-scope per F4 brief. The path-handler hook is wired (`linux_abi/init.ad:120`). |
| **F6** Phase G retirements | **HELD.** `grep -rn 'sys_spawn\|sys_listdir\|sys_kill' user/ lib/ --include="*.ad"` is empty. `lib/p9.ad` provides `spawn`/`p9_note`/`p9_listdir`; 10 user programs import it. SYS_KILL kernel arm still exists (negative-pid only, per docs). |
| **F8** 9P depth + distrofs | **HELD** (verified by STATUS.md row + `DEV_P9MAX` exists in namec). Not deeply probed in this audit. |
| **F9** literal-path sweep | **HELD.** `kernel/boot_flags.ad` exists; `cpio_distro_prefix()` exists at `sys/src/9/port/chan.ad:251`; `/dev/auth` arrives through namec's `NAMEC_NEEDS_AUTH` (`sys/src/9/port/namec.ad:2027`); /tmp/core routes via resolve_path (`kernel/core/coredump.ad:557`). One stale doc-only mention of `chan_resolve_prefix` at `docs/rootfs_partition.md:259-265` survives. |

---

## 2. New axis: scheduler / mm

Findings:

- **scheduler IS pgrp-aware via nscap CPU cap.** `kernel/sched/core.ad:3513` calls `nscap_cpu_factor_current()` and inflates `vruntime` by the per-Pgrp ceiling. This is correct integration of #174 with the per-CPU runqueue lift (#397).
- **Per-CPU runqueues respect locality, not Pgrp.** `kernel/sched/core.ad:947` declares `rq_locks[16]`; placement helpers pick a CPU by load + first-touch, not by Pgrp affinity. That's the correct decision — Pgrps are namespaces, not scheduler domains — but flag it as an *intentional* design choice the codebase doesn't document anywhere. A future reader expecting "namespace-isolated CPU sets" will not find them.
- **oom_score_adj is per-task, not per-Pgrp.** `kernel/sched/core.ad:1585` `g_oom_score_adj: Array[16, int32]` is indexed by task slot. Comment cites Linux semantics. This is a *Linux ABI* concept living in the native kernel. Per the Plan 9 ethos, the OOM score-adjust input belongs in the namespace, not the task — a task is just a runnable handle inside its Pgrp's memory budget. This is a layering smell: the kernel mixes a per-Pgrp memory model (nscap) with a per-task OOM bias.
- **mm has zero Pgrp awareness** (`grep -rn 'pgrp' mm/` returns nothing outside the nscap test). This is *correct* — VMA is per-process — but means a process inside a Pgrp can be killed by the OOM heuristic without consideration of its Pgrp's nscap residency. nscap throttles CPU but does not (yet) protect against the OOM killer. The advertised "namespace-native resource cap" of #174 only covers CPU + accounting; the kill-victim arm is still Linux-shape.
- **`current_task_uid()` is the auth identity, but is global per task** — there is no per-server-channel identity. `fs/vfs.ad:1566` reads `cu = current_task_uid()` and passes that into every server's perm check. The Plan-9 model would carry the auth-name on the **mount channel** (the `Tauth/Tattach` uname) — which is exactly what `do_mount`'s `afd` parameter is supposed to do, and which `sys/src/9/port/syschan.ad:218` openly admits is silently ignored. So Hamnix's "namespace-as-authority" is single-uname per task; there is no way for two mounts in the same Pgrp to disagree about who you are.

---

## 3. New axis: driver layer

Findings:

- **`drivers/net/devnet.ad` is a correct file server.** Header comment is a Plan-9 spec; `/net/<proto>/<conn>/ctl` etc. arrive as `#I/...` post-ns_walk and dispatch is letter-keyed.
- **Block drivers register cleanly through `kernel/block/blk.ad::register_blockdev`.** `drivers/block/virtio_blk.ad:594`, `drivers/block/loop.ad`, NVMe / AHCI through linux_abi shim — all register their ops, the `#b` server (`sys/src/9/port/devblk.ad`) accesses them through the table.
- **`drivers/usb/xhci.ad` is the right shape but has a literal `boot_flag_get('xhci-ko-real')` skew.** `xhci.ad:74` imports `boot_flag_get`; `xhci.ad:4131-4152` reads `xhci-no-attach` / `xhci-no-init`. F9 substrate is honored. The L-shim `linux_abi/api_xhci_real.ad:71` ALSO reads the same flag — both native and L-shim agree on the same ctl surface. Good.
- **Audio capture/selftest still uses literal `namec("/dev/audio*")`.** `drivers/audio/audio_capture_selftest.ad:66`, `drivers/audio/audio_selftest.ad:155,285,290`. These are kernel selftests, so they bypass the namespace. Same class of issue as the `sysfile.ad` fstat selftest — kernel-context use of literal paths.
- **`drivers/net/socket.ad` exists.** Inspect: header says "DIFFERENT from linux_abi/api_socket.ad", but the very name "socket" violates the [feedback_no_sockets.md] mandate that Hamnix has **no native socket()**. Worth confirming this isn't a native socket API leaking back in — it's likely a placeholder/dispatcher, but the filename is misleading.

---

## 4. New axis: userland conventions

Findings:

- **`lib/p9.ad` doesn't propagate errstr.** `lib/p9.ad` has no `sys_errstr` import. Every helper returns `-1` on failure without setting or surfacing the kernel's errstr. Plan 9 idiom is `if (sys_call() < 0) sysfatal("%r", ...)` where `%r` is errstr.
- **Plan 9 `Dir` records are not a first-class struct.** `grep -rn '^struct Dir\|^class Dir'` returns nothing. `p9_listdir` returns `NAME\n`-packed text and `lib/p9.ad:48` openly admits "Migrating to native-api.md's 9P Dir-record stream is a separate kernel-side track." So the universal-listing format is still bytes-as-strings, not the qid+mode+length+mtime+uid+name record. `user/ls.ad` cannot do `ls -l` because no stat metadata accompanies the names.
- **Only 8 of 185 userland programs call `sys_errstr`.** `grep -rln sys_errstr user/*.ad | wc -l` = 8. The other 177 silently swallow errors. Hamsh is the most thorough (`user/hamsh.ad:54+`); cp, mv, hpm, ls, du, lsblk don't.
- **userland still leans on Linux-shape return codes.** `sys_open` returns int32; `< 0` is treated as `-errno`. Plan 9 returns `-1` and parks the reason in errstr. `lib/p9.ad`'s wrappers preserve the Linux shape, so userland never learns the Plan 9 idiom.
- **`user/init.ad` and `user/hamsh.ad` are big.** `wc -l user/hamsh.ad` = 8500+. hamsh has accumulated job control, redirection, parser, builtins, history, ${} expansion — and `errstr_set/errstr_clear/errstr_buf` (`user/hamsh.ad:2186`). It's the wrong place to maintain Plan 9 idiom; should be in `lib/`.

---

## 5. New axis: security end-to-end

Findings:

- **`vfs_open` skips `resolve_path`.** Repeating Goal 1's F1 caveat for emphasis here because it is the load-bearing security claim. `fs/vfs.ad:1651-1662` enters `_vfs_open_post_perm(name)` with the user's name; `chan_permission_check` and `_namec_open` both consume the un-namespace-walked input. A task whose Pgrp does NOT bind `/dev` (e.g. RFCNAMEG child) can still `open("/dev/null")` because `_devtab_lookup` matches the literal `"/dev/null"` regardless of bindings. The F1 substrate "unbound = ENOENT" is enforced only at the disk routing.
- **`_path_owning_server` defaults to cpio (1).** `fs/vfs.ad:1542` returns 1 on no-match. An unrecognized path like `/foo/bar` reaches `_perm_check_cpio` → `_lookup_name` → idx<0 → **returns 0 (grant)**. The "Unknown server letter — conservative deny" branch (line 1606) is only reached for `#X` paths with unknown letters; raw paths fall through to a permissive default.
- **Most `_perm_check_<X>` are stubs that return 0.** tmpfs, devcons, devproc, devsrv, devnet, devauth, fat, rootslot all grant unconditionally (`fs/vfs.ad:1347-1453`). Comments justify each as "the backend enforces" — but `_perm_check_devproc` for example claims write authority is enforced "at devproc"; reading `sys/src/9/port/devproc.ad`'s ctl-write handler, the gating that exists is `oomadj` (-1000 hostowner-only) and `policy` (rtsched hostowner-only). The `pri` verb has *no* uid gate — any user can renice any pid. Linux's setpriority requires CAP_SYS_NICE or matching real uid; Hamnix's ctl-file gives it to everyone.
- **Pre-login = hostowner.** `kernel/sched/core.ad:2532` defaults `task_table[s].uid = 1`. New tasks start hostowner. The setuid downgrade only happens through `SYS_SETUID_AUTH` in `user/login.ad`. So /init runs hostowner, and any task spawned before login is hostowner — this is the F3 dispatcher's bypass branch in *every* fresh boot.
- **9P mount auth (`afd`) is silently ignored.** `sys/src/9/port/syschan.ad:218` says `_ignored: int32 = afd`. Plan 9's authority model rests on the mount-channel Tauth/Tattach exchange. Hamnix takes the parameter, throws it away, and binds with empty uname. So a userland file server cannot trust who its caller is.
- **`uid == 1` checks scattered across syscall arms.** `arch/x86/kernel/syscall.ad` has 12+ raw `if current_task_uid() != 1: return -1` gates in SYS_SVC_CTL, SYS_WSYS_*, SYS_SET_REALTIME, SYS_VK_*. None of them route through the F3 dispatcher. Plan 9 shape would push these to the ctl-file's write handler.
- **seccomp-lite is Layer-2-only.** `kernel/sched/core.ad:545`'s seccomp-lite comment says "LAYER-2-ONLY per-task syscall filter". Native syscalls bypass seccomp entirely. So a process can't restrict its own native syscall surface. The /dev/nscap memory/cpu cap is the closest analog, but it covers resources not syscalls.

---

## 6. New axis: boot/init shape

Findings:

- **`init/main.ad` is 13,893 lines and 69 top-level functions.** It is openly a kitchen sink: every subsystem smoke/selftest lives in it (block_smoke_test, blkwrite_smoke_test, iso9660_e2e_selftest, btrfs_e2e_selftest, ntfs_e2e_selftest, loop_e2e_selftest, v9p_e2e_selftest, packet_count_hook, ahci_io_exercise, nvme_io_exercise, xhci_io_exercise, cpio_capacity_smoke_test, net_smoke_test, msix_smoke_test, tcp_*_smoke_test ×6, http*_smoke_test ×5, mmap_*_selftest ×2, usbms_exercise, memblock_smoke_test, page_alloc_smoke_test, slab_smoke_test, string_ops_smoke_test, list_smoke_test, vga_smoke_test, tsc_test_run, diag_smoke_test, backtrace_selftest, fb_init_early). These should live in `tests/` and be wired by name into a kernel-side selftest dispatcher invoked by a boot-flag. Mixing test bodies into the boot orchestrator hides where boot policy actually lives.
- **rc.boot bootstrap is honest.** `etc/rc.boot` is 149 lines, declarative, well-commented. The handoff to `etc/rc.boot.full` (179 lines) on the sysroot partition is the right shape.
- **Kernel-planted binds in `pgrp_init`** (`sys/src/9/port/chan.ad:897-913`) are the right shape. 11 default binds.
- **`init/main.ad`'s linux_abi imports are correct per F4 scope-out, but the linux_abi initialization at boot is scattered.** `init/main.ad` lines 59-260+ import dozens of linux_abi entry points. F4 funneled most through `linux_abi_init()` but several still arrive directly. The "single linux_abi_init plant point" intent isn't quite respected in init/main.ad's import list.

---

## 7. New axis: docs honesty

Findings:

- **`docs/security.md`'s perm-table over-claims.** Lines 133-145 list a per-server policy table; in code, most rows are no-ops (see Goal 2 axis 5). Reword the table OR push real policies into the bodies.
- **`docs/security.md`'s "userland NEVER opens /etc/shadow directly"** is true by mode bit (0600 hostowner) but NOT enforced through the F3 server boundary — the ext4 mode bit gate is the actual enforcement. The chain is: F3 dispatcher does `uid==1 ? grant : ext4_perm_check` for ext4 (line 1585-1587). Non-hostowner reaches ext4_perm_check which honors mode bits. Hostowner reads it unconditionally without consulting mode bits — and every fresh task is uid=1.
- **`docs/architecture.md` has no F1 substrate section.** It still describes the namespace model in pre-substrate terms (line 195 "kernel become file servers that namespaces bind"). Not wrong, but incomplete.
- **`docs/rootfs_partition.md:259-265`** describes a `chan_resolve_prefix` rule. `chan_resolve_prefix` is gone. Update to ns_walk semantics.
- **`docs/native-api.md`** is honest about F2's "deprecated thin shims" (line 491). It is the most up-to-date doc in this wave.
- **STATUS.md row for F1 (line 913)** claims "RFCNAMEG children must re-bind console fds via SYS_FDBIND because /fd console bindings live in the Pgrp" — which is true and a real consequence of the substrate. But it doesn't note the asymmetric F1 enforcement (disk = ENOENT, devtab = bypass). Worth a follow-up paragraph.

---

## 8. Ranked NEXT-wave findings

Deepest first. Each is a candidate for a future single-agent sweep on the lines of F1-F9.

### F10-1. `vfs_open` skips `resolve_path` → the F1 namespace gate is bypassed for namec-served paths

**Cite:** `fs/vfs.ad:1651-1662` `vfs_open` → `_vfs_open_post_perm(name)` directly; never calls `resolve_path(name, ...)`. `sys/src/9/port/namec.ad:837-927` `_devtab_lookup` matches `/dev/<leaf>` LITERALS unconditionally.

**Symptom:** an RFCNAMEG child with no `bind '#c' /dev` can still `open("/dev/null")` and succeed. The F1 acceptance test `test_ns_enoent` only probes the on-disk leg and so missed this.

**Fix direction:** run `resolve_path` at the top of `_vfs_open_post_perm` (and the write counterpart). The resolved name (`#c/null` or ENOENT) is then dispatched through `_open_hash_alias`. Delete the literal `/dev/<leaf>` strcmp table in `_devtab_lookup` and serve only the `#c/<leaf>` form. Extend `test_ns_enoent` to probe `open("/dev/null")` in an empty namespace.

### F10-2. `_path_owning_server` defaults to cpio (server 1) on miss + most `_perm_check_<X>` return 0

**Cite:** `fs/vfs.ad:1542` default-cpio; lines 1347-1453 stub policies. `docs/security.md:133-145` table claims real per-server policy.

**Symptom:** unknown paths get cpio's perm check which grants on lookup miss. "Server boundary enforcement" exists structurally but not behaviorally for 8 of 11 servers.

**Fix direction:** (a) the default branch in `_path_owning_server` returns "unknown" → `chan_permission_check` returns `EPERM_PERM` on unknown server, mirroring the line-1606 `#X` unknown-letter branch. (b) Move each `_perm_check_<X>` body INTO its server's file (`_perm_check_devproc` → `sys/src/9/port/devproc.ad`, etc.) and have the dispatcher call the moved function. This is the "policy lives in the server" claim made real. (c) Write `test_perm_unknown_path` asserting a fabricated path returns EPERM.

### F10-3. Userland is uid=1 by default → blanket hostowner bypass at every fresh task

**Cite:** `kernel/sched/core.ad:2532` `task_table[s].uid = 1` in `_init_task_slot`; `fs/vfs.ad:1571-1586` `cu == 1` bypasses in dispatcher.

**Symptom:** every userland program before login is hostowner. The F3 hostowner bypass fires on every line. The default boot namespace is "everyone is root."

**Fix direction:** flip the default to a NOBODY uid (e.g. 65534) and have the kernel-mediator paths (devauth's `_au_read_live_file`, init's bootstrap calls) use `vfs_open_kernel` exclusively. PID 1 stays hostowner because `etc/inittab` declares it so. The login flow upgrades a task to its target uid through `SYS_SETUID_AUTH`. This is also the right base for `seccomp-lite` to cover native syscalls.

### F10-4. 9P mount `afd` (Tauth) is silently dropped → no per-channel auth identity

**Cite:** `sys/src/9/port/syschan.ad:201-218`, `do_mount`'s afd parameter is read into `_ignored`.

**Symptom:** Plan 9's authority model relies on the Tauth/Tattach uname exchange on the mount channel. Hamnix's mounts always carry an empty uname. A future userland server cannot trust who its caller is — the F3 follow-up note in `docs/security.md` acknowledges this gap.

**Fix direction:** implement the Tauth/Tattach exchange when `afd != -1`. Wire `p9c_attach` to accept the afd, perform a Tauth, send the resulting auth-uname in Tattach. Builds on `/srv/factotum` (documented).

### F10-5. `init/main.ad` is 13,893 lines of selftests + boot orchestration mixed

**Cite:** 36 of 69 functions in `init/main.ad` are `*_smoke_test` / `*_selftest` / `*_exercise`. The boot policy is buried among them.

**Symptom:** a future reader can't tell which lines are boot policy vs which are test bodies. The "boot orchestrator" identity is muddled.

**Fix direction:** move every `*_smoke_test`, `*_selftest`, `*_exercise` body into `tests/<subsystem>_smoke.ad`. Have `init/main.ad` import a single `run_selftests_if_flag()` dispatcher from `tests/dispatcher.ad`. Boot orchestration shrinks to a couple hundred lines. The Adder build's per-test compilation flow already exists.

### F10-6. Plan 9 `Dir` record is not a first-class struct in the codebase

**Cite:** `grep -rn '^struct Dir' --include="*.ad"` returns nothing. `lib/p9.ad:48`'s comment confesses migration is "a separate kernel-side track."

**Symptom:** `ls -l`, `stat`, `du -h --time` cannot be written natively. Userland enumerates names and re-stat()s each one. devsrv listings, devproc listings, devnet listings all emit `NAME\n`. The Plan-9-shape unification of "directory read = stream of Dir records" never happened.

**Fix direction:** define `Dir` (`lib/p9.ad`): `qid` (path/version/type), `mode`, `atime`, `mtime`, `length`, `name`, `uid`, `gid`, `muid`. Add a `p9_diread(fd) -> Dir` wrapper. Migrate the kernel-side directory-read backings (`_dirfile_read`, devsrv, devproc) to emit Dir records. `ls -l` becomes obvious. This is the U-series-shape ABI move the brief flagged.

### F10-7. `nice` / `pri` ctl-file has no uid gate

**Cite:** `sys/src/9/port/devproc.ad:1500-1555` `_ctl_parse_pri` + apply via `sched_set_nice` has no uid gate; F3's `_perm_check_devproc` returns 0 unconditionally; the devproc backend doesn't check caller_uid vs target.

**Symptom:** any process can renice any process. Linux's `setpriority` gates on CAP_SYS_NICE or matching real uid.

**Fix direction:** at devproc's ctl write, check `caller_uid == target_uid OR caller_uid == 1`. Apply same rule to `policy` verb. This is "the server enforces" made real.

### F10-8. seccomp-lite covers Layer 2 only

**Cite:** `kernel/sched/core.ad:545` "LAYER-2-ONLY per-task syscall filter."

**Symptom:** native syscall surface is unrestrictable. A sandboxed program (`hpm`'s build hook, a chrooted Debian script) can still call the full native dispatch.

**Fix direction:** extend seccomp-lite to gate `do_syscall` in `arch/x86/kernel/syscall.ad`. The filter bitmap already exists at TaskStruct offset (kernel/sched/core.ad:566). Add a `seccomp_native_filter` arm + a `prctl(SET_NATIVE_FILTER, bitmap)` syscall. Userland `kdrop` becomes useful.

### F10-9. Linux ABI `is_*_path` strcmp ladder in u_syscalls (F4 deferred)

**Cite:** `linux_abi/u_syscalls.ad:585-608+` imports `is_tmpfs_path`, `is_ext_path`, `is_fat_path`, `is_var_path`, `is_tmpfs_dir_path`; `linux_abi/u_syscalls.ad:9085-9100` `_statfs_classify_path` is a literal-prefix ladder.

**Symptom:** even in the L-shim, fs identity is decided by string prefix, not by `vfs_fs_kind`. The chan model knows the answer; statfs re-strcmps.

**Fix direction:** route Linux statfs through `vfs_fs_kind(name)` → FS_KIND → backing-fs ID. Delete the path strcmp helpers from u_syscalls' import list. (Some uses remain valid — e.g. checking whether a /ext path is mounted — but those should use vfs's mount table not the prefix string.)

### F10-10. oom_score_adj is per-task, not per-Pgrp

**Cite:** `kernel/sched/core.ad:1585` `g_oom_score_adj: Array[16, int32]` is keyed by task slot.

**Symptom:** namespace-cap (#174) covers CPU + memory accounting, but the OOM kill victim selection ignores Pgrp. A capped Pgrp's tasks compete with the system for OOM survival.

**Fix direction:** add `pgrp_oom_score_adj` (per-Pgrp default) + per-task delta. Or kill the per-task slot and rely on per-Pgrp score. Aligns OOM with the rest of the resource-cap model.

### F10-11. `drivers/net/socket.ad` filename violates the no-sockets mandate

**Cite:** `drivers/net/socket.ad:1`. The file exists; the name suggests BSD sockets.

**Symptom:** even if the file is a Plan-9-shape primitive (haven't read its body), a reader looking for "where do sockets live in Hamnix" will land in a file with the wrong name. The codebase advertises "no native socket" (memory/feedback_no_sockets.md).

**Fix direction:** rename to `drivers/net/sock_compat.ad` or similar, OR add a leading docstring stating "this is the L-shim adapter, not native API." Same exercise as the `linux_abi/api_socket.ad` companion file.

### F10-12. Doc rot: `docs/rootfs_partition.md` references deleted `chan_resolve_prefix`

**Cite:** `docs/rootfs_partition.md:259-265`.

**Fix direction:** replace with ns_walk semantics + the per-Pgrp longest-prefix rule.

---

## 9. Closing note

**Honest read:** the wave structurally succeeded on F4, F6, F8, F9. F1's keystone is half-finished — the substrate exists, but `vfs_open` doesn't run it for namec-served names, so the per-Pgrp namespace gate enforces only on the cpio/disk leg. F2 is a name change — the syscalls still do the work. F3 is closer to "dispatcher reshuffle" than "policy moved to servers" — most `_perm_check_<X>` are stubs and the practical perm model remains "uid 1 wins, ext4 mode-bits gate non-root."

**The spine's actual Plan 9 shape today:**

- `#X` server-letter dispatch: REAL. The `#`-arm at the top of `vfs_open` is the universal entry, and the F1 named-stack handles `#by-id`, `#sysroot`, `#part0` etc.
- Per-Pgrp mount table: REAL. `ns_walk` is the sole authority for canonical paths.
- Unbound = ENOENT: TRUE for disk-routed paths, FALSE for namec devtab paths (the F1 carve-out it didn't fix).
- File servers as the resource model: STRUCTURAL only. Servers exist (`#c`, `#p`, `#s`, `#I`, `#b`), but policy/auth/identity remain in the dispatcher.
- 9P-on-the-wire: REAL for V6 tagged-concurrency (#451) and distrofs.
- 9P auth (Tauth/Tattach uname): MISSING — afd is dropped.
- `Dir` records: MISSING — listings are still `NAME\n` byte streams.
- Notes (Plan 9 signals): partly real (`/proc/<pid>/note` exists, p9_note writes to it); the note handler / drain path is documented as a follow-up.

**North star delta:** the architecture *announces* the Plan 9 shape correctly. The codebase is one or two more sweeps from the announcement actually holding. The two structural keystones still owed:

1. `resolve_path` at every `vfs_open` entry (closes F10-1, F10-2, removes the namespace-gate bypass).
2. `Dir` record as the universal directory enumeration shape (closes F10-6, lets userland become Plan-9-idiomatic without re-stat-per-line).

After those two, F3's perm bodies and F2's syscall thin-shimming become small, isolated follow-ups. The base will then match the headline.
