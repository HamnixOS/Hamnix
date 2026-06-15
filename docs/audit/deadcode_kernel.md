# Dead-code / redundancy audit — kernel + Plan 9 port + arch + mm

Scope: `sys/src/9/port/`, `kernel/`, `arch/x86/`, `arch/arm64/`, `mm/`.
All reference counts verified TREE-WIDE (`grep -rIn -w <name>` across every
`*.ad/*.S/*.py/*.sh`, excluding `.git/` and `build/`).

## Method notes (load-bearing build facts established first)

- The Adder kernel is **whole-program compiled from `init/main.ad`**
  (`python3 -m compiler.adder compile init/main.ad`). A `.ad` file is linked
  iff it is in the transitive `import` graph of `init/main.ad`
  (`compiler/adder.py:collect_all_imports`). A def/global is reachable iff it
  has a real reference; unused public names are still *emitted* but are dead.
- `sys/src/9/port/` is imported via the dotted path `sys.src.port9.port.*`,
  which resolves through the **`sys/src/port9 -> 9` symlink**. The whole tree
  IS in the import graph (an earlier naive walk that ignored the symlink wrongly
  flagged it all as orphaned — it is NOT).
- **x86 `.S` files are never orphans**: `assemble_and_link_x86_bare()`
  auto-globs every `*.S` under `arch/x86`, `fs`, `drivers` and links it
  (`adder.py` ~line 690). Drop-in linkage.
- **ARM64** links exactly `arch/arm64/boot.S` + `arch/arm64/vectors.S` plus the
  compiled `arch/arm64/kmain.ad` (its OWN build root, `--target=aarch64-bare-metal`).
  `kmain.ad` is therefore NOT an orphan even though `init/main.ad` never imports it.
- `arch/arm64/kmain.ad` is a single ~28k-line monolithic bring-up + self-test
  harness. It contains hundreds of phase-local constants/defs (`P17_*`…`P48_*`,
  `arm64_pNN_*`) with tree-wide refcount 1–2. These are **per-phase test-fixture
  scaffolding, locally scoped within that one file** — not orchestrator-level dead
  code. They are NOT enumerated individually below; see category 1 closing note.

---

## 1. DEAD CODE (zero callers tree-wide, excluding the definition)

Every item below has tree-wide refcount **1** (only its own `def`/decl line).
None is declared `extern def` anywhere, none is reached by a string/table
dispatch (the Plan-9 dev dispatch in `namec.ad` is read/write-only — there is no
open/close vtable), none is a syscall-table arm.

### arch/x86
- [NEEDS-REVIEW] `arch/x86/kernel/apic.ad:834` `ioapic_mask` — IOAPIC RTE masker. Zero callers. Plausibly an intended IRQ-management primitive kept as API surface; mask-by-write is a real future need. Recommend: confirm with IRQ owner, else remove.
- [NEEDS-REVIEW] `arch/x86/kernel/i8259.ad:84` `i8259_mask_irq` — 8259 PIC per-IRQ mask. Zero callers (the kernel runs APIC; PIC is masked en-masse at init). Recommend: keep if PIC-fallback path is still desired, else remove.
- [NEEDS-REVIEW] `arch/x86/kernel/cpu_kaslr.ad:65` `cpu_kaslr_offset` — getter for the KASLR slide. Zero callers. Likely a telemetry/debug accessor. Recommend: remove unless a KASLR self-test is planned.
- [NEEDS-REVIEW] `arch/x86/kernel/e820.ad:193` `set_boot_via_efi` — setter for a boot-source flag. Zero callers (the UEFI entry that would call it is itself unbuilt — see category 3 `uefi_entry.ad`). Recommend: remove together with the UEFI scaffold, or wire when UEFI handoff lands.
- [NEEDS-REVIEW] `arch/x86/kernel/efi_runtime.ad:152` `efi_set_variable` — EFI RT SetVariable wrapper. Zero callers. Part of the not-yet-exercised EFI runtime-services surface. Recommend: keep as documented RT-services stub OR remove with the UEFI scaffold.
- [SAFE-REMOVE] `arch/x86/kernel/irq.ad:235` `resched_ipi_get_count` — reschedule-IPI counter getter. Zero callers; the counter it reads is still incremented internally, but nothing reads it out. Pure dead accessor.
- [NEEDS-REVIEW] `arch/x86/kernel/power.ad:228` `power_s3_set_silicon_enable` — S3 silicon-enable setter. Zero callers. S3 path is partially built; may be a live hook awaiting a caller. Recommend: confirm with ACPI/S3 owner.
- [NEEDS-REVIEW] `arch/x86/kernel/power.ad:417` `power_lid_armed` — lid-switch armed getter. Zero callers. Same S3/ACPI track. Recommend: confirm, else remove.
- [SAFE-REMOVE] `arch/x86/kernel/time.ad:225` `get_jiffies_addr` — returns the address of the jiffies global. Zero callers (everyone uses `get_jiffies()` value, not the address). Dead accessor.

### kernel/
- [SAFE-REMOVE] `kernel/block/blk.ad:1229` `blk_sched_submitted` — I/O-scheduler submitted-count getter. Zero callers. Dead telemetry.
- [NEEDS-REVIEW] `kernel/block/blk.ad:1283` `blk_plug_write` — plugged-write entry point. Zero callers. Could be a real block-layer API arm left unwired; block I/O is load-bearing. Recommend: confirm the plug path is reached some other way before removing.
- [SAFE-REMOVE] `kernel/block/blk.ad:413` `bcache_evictions` — buffer-cache eviction counter getter. Zero callers. Dead telemetry.
- [SAFE-REMOVE] `kernel/block/blk.ad:417` `bcache_inserts` — buffer-cache insert counter getter. Zero callers. Dead telemetry.
- [NEEDS-REVIEW] `kernel/block/blk.ad:716` `blk_root_slot` — returns the root block-device slot. Zero callers. Possibly load-bearing for a root-mount path that currently resolves the slot inline. Recommend: confirm.
- [SAFE-REMOVE] `kernel/printk/esp_log.ad:562` `esp_log_is_ready` — readiness getter. Zero callers. Dead accessor.
- [SAFE-REMOVE] `kernel/printk/esp_log.ad:598` `esp_log_set_selftest` — self-test-mode setter. Zero callers (the ESP-log self-test is driven by `esp_log_write_selftest`, which IS called). Dead setter.
- [SAFE-REMOVE] `kernel/sched/core.ad:4557` `current_task_is_user` — predicate. Zero callers. Superseded by `task_is_linux_userspace`/other predicates that ARE used. Dead.
- [SAFE-REMOVE] `kernel/sched/core.ad:5639` `task_is_linux_userspace` — predicate. Zero callers. Dead predicate.
- [NEEDS-REVIEW] `kernel/sched/core.ad:5674` `task_clear_child_tid` — CLONE_CHILD_CLEARTID support. Zero callers. clone/futex semantics are load-bearing for glibc threads; a never-called clear-child-tid hook may be a latent missing-feature gap rather than dead code. Recommend: confirm against clone/exit paths.
- [SAFE-REMOVE] `kernel/sched/core.ad:5686` `task_exit_sem` — accessor. Zero callers. Dead.
- [NEEDS-REVIEW] `kernel/sched/core.ad:5764` `set_task_gid_at` — per-slot GID setter. Zero callers (uid analogue `set_current_task_uid` IS used). Could be a missing setgid wiring. Recommend: confirm with auth/setgid path.
- [SAFE-REMOVE] `kernel/sched/core.ad:5768` `count_live_user_tasks` — getter. Zero callers. Dead telemetry.
- [SAFE-REMOVE] `kernel/sched/core.ad:6573` `console_input_grabbed_by` — getter for the console-grab owner. Zero callers. Dead accessor.
- [SAFE-REMOVE] `kernel/sched/core.ad:7136` `get_task_pdeathsig` — getter. Zero callers (the value is consumed inline elsewhere). Dead accessor.
- [SAFE-REMOVE] `kernel/sched/core.ad:7767` `task_fd_clear_opened_path` — fd opened-path clearer. Zero callers. Dead.
- [SAFE-REMOVE] `kernel/sched/core.ad:7787` `task_fd_copy_opened_path` — fd opened-path copier. Zero callers. Dead.
- [SAFE-REMOVE] `kernel/sched/core.ad:8283` `task_detached` — predicate getter. Zero callers (`set_task_detached` IS used; the reader is not). Dead accessor.
- [SAFE-REMOVE] `kernel/seccomp_bpf.ad:600` `bpf_clear` — cBPF program clear. Zero callers. Dead.
- [NEEDS-REVIEW] `kernel/seccomp_bpf.ad:675` `seccomp_bpf_init` — seccomp subsystem init. Zero callers. A never-called `*_init` is either dead OR a latent missing-init bug. Recommend: confirm seccomp is initialized some other way before removing.
- [SAFE-REMOVE] `kernel/vt/vt.ad:100` `vt_kbd_has` — predicate. Zero callers. Dead.
- [SAFE-REMOVE] `kernel/vt/vt.ad:138` `vt_set_fg_pgid` — foreground-pgid setter. Zero callers. Dead.
- [SAFE-REMOVE] `kernel/vt/vt.ad:152` `vt_n` — VT-count getter. Zero callers. Dead telemetry.
- [SAFE-REMOVE] `kernel/boot_flags.ad:92` `_bf_strlen` — module-private strlen helper. Zero callers. Dead private helper (a public `strlen` exists elsewhere).
- [SAFE-REMOVE] `kernel/modprobe.ad:164` `_pat_consume_literal` — module-private parse helper. Zero callers. Dead private helper.

### mm/
- [SAFE-REMOVE] `mm/slab.ad:335` `kmalloc_live_cache_count` — getter. Zero callers. Dead telemetry.
- [SAFE-REMOVE] `mm/slab.ad:342` `kmalloc_live_active` — getter. Zero callers. Dead telemetry.
- [SAFE-REMOVE] `mm/slab.ad:349` `kmalloc_live_total` — getter. Zero callers. Dead telemetry.
- [SAFE-REMOVE] `mm/slab.ad:357` `kmalloc_live_objsize` — getter. Zero callers. Dead telemetry.
- [SAFE-REMOVE] `mm/slab.ad:363` `kmalloc_live_nr_slabs` — getter. Zero callers. Dead telemetry.
  (These five `kmalloc_live_*` accessors are a single dead telemetry block.)
- [NEEDS-REVIEW] `mm/uaccess.ad:332` `get_user_16` — 16-bit user fetch. Zero callers. uaccess is the #163 security keystone; a width variant kept for completeness/symmetry with `get_user_8/32/64`. Recommend: keep as deliberate uaccess API surface OR remove if width-16 is provably unused.
- [NEEDS-REVIEW] `mm/uaccess.ad:354` `put_user_8` — 8-bit user store. Zero callers. Same rationale as `get_user_16`. Recommend: treat as a pair with the above.
- [SAFE-REMOVE] `mm/vma.ad:3273` `vma_count` — per-slot VMA count getter. Zero callers. Dead telemetry.

### sys/src/9/port/
- [SAFE-REMOVE] `sys/src/9/port/devmouse.ad:105` `devmouse_open` — Plan-9 open handler. Zero callers; `namec.ad` imports/dispatches only `devmouse_read`+`devmouse_write` (no open/close vtable exists). Vestigial. Remove.
- [SAFE-REMOVE] `sys/src/9/port/devmouse.ad:515` `devmouse_close` — Plan-9 close handler. Same as above. Vestigial. Remove.
- [NEEDS-REVIEW] `sys/src/9/port/devrandom.ad:478` `devrandom_init` — RNG init. Zero callers (`init/main.ad` calls `devrandom_selftest`, not `_init`). Never-called `*_init` — dead OR latent missing-init. Recommend: confirm RNG is seeded elsewhere.
- [SAFE-REMOVE] `sys/src/9/port/devsrv.ad:465` `devsrv_count` — getter. Zero callers. Dead telemetry.
- [SAFE-REMOVE] `sys/src/9/port/devwsys.ad:2401` `wsys_workspace_request` — getter. Zero callers. Dead (DE-perf scaffolding accessor).
- [SAFE-REMOVE] `sys/src/9/port/devwsys.ad:2405` `wsys_workspace_generation` — getter. Zero callers. Dead.
- [SAFE-REMOVE] `sys/src/9/port/devwsys.ad:2409` `wsys_wallpaper_path_ptr` — getter. Zero callers. Dead.
- [SAFE-REMOVE] `sys/src/9/port/devwsys.ad:2413` `wsys_wallpaper_path_length` — getter. Zero callers. Dead.
- [SAFE-REMOVE] `sys/src/9/port/devwsys.ad:257` `wsys_win_serial_get` — per-window damage-serial getter. Zero callers (the damage system is read by the compositor a different way). Dead accessor.
- [SAFE-REMOVE] `sys/src/9/port/devwsys.ad:5576` `wsys_wctl_serial_get` — getter. Zero callers. Dead accessor.
- [SAFE-REMOVE] `sys/src/9/port/namec.ad:3725` `namec_chan_is_pool` — predicate. Zero callers. Dead.
- [SAFE-REMOVE] `sys/src/9/port/namec.ad:3836` `namec_chan_refcount` — getter. Zero callers. Dead telemetry.
- [SAFE-REMOVE] `sys/src/9/port/namec.ad:3847` `namec_live_count` — getter. Zero callers. Dead telemetry.
- [SAFE-REMOVE] `sys/src/9/port/9p_client.ad:2172` `p9c_conn_for_srvfd` — getter. Zero callers. Dead accessor.
- [SAFE-REMOVE] `sys/src/9/port/9p_client.ad:2177` `p9c_root_fid` — getter. Zero callers. Dead accessor.
- [NEEDS-REVIEW] `sys/src/9/port/chan.ad:1267` `nscap_charge_current` — namespace-capability charge. Zero callers. Namespace-cap accounting is load-bearing security; a never-called charge half (with `nscap_uncharge_current` also dead) may be an unwired enforcement pair. Recommend: confirm with nscap owner.
- [NEEDS-REVIEW] `sys/src/9/port/chan.ad:1274` `nscap_uncharge_current` — pairs with the above. Same disposition.
- [NEEDS-REVIEW] `sys/src/9/port/chan.ad:1482` `chan_walk` — Plan-9 channel walk. Zero callers. A core-sounding Plan-9 primitive with no caller is suspicious (walk normally drives name resolution). Recommend: confirm namec doesn't depend on it via another spelling before removing.
- [SAFE-REMOVE] `sys/src/9/port/chan.ad:746` `byid_unregister` — by-id table unregister. Zero callers (register path used; unregister never invoked → also a potential leak smell). Recommend: remove OR wire on teardown; flag to chan owner.
- [SAFE-REMOVE] `sys/src/9/port/devdiskstats.ad:99` `_ds_emit_str` — module-private emit helper. Zero callers. Dead private helper.
- [SAFE-REMOVE] `sys/src/9/port/devmounts.ad:74` `_devmounts_u64_to_dec` — module-private dec helper. Zero callers. Dead private helper (and a copy-paste clone — see category 4).

**Closing note for category 1:** `arch/arm64/kmain.ad` additionally has hundreds of
phase-local symbols (`P17_*`…`P48_*`, `arm64_pNN_*`) at refcount 1–2. They are
intentional per-phase self-test fixtures inside one monolithic file, NOT
project-level dead code, and are excluded from the list above. If that file is
ever modularized, revisit them then.

---

## 2. REDUNDANT MECHANISMS

- [NEEDS-REVIEW] `sys/src/9/port/devwsys.ad:3136` (`nudge`), `:3189` (`nudge_report`), `:3217` (`drag`) ctl verbs — **redundant mouse-injection path** parallel to the canonical `/dev/mouse` write. All three call `mouse_rx_push_abs` (imported `devwsys.ad:137`), the SAME ring-push that `devmouse_write` (`devmouse.ad:329`) uses. This is the exact pattern named in the audit brief. **CANONICAL = `/dev/mouse` write (`devmouse_write`)**; the `nudge`/`nudge_report`/`drag` verbs are the redundant add-on (DE-perf harness #410, added because QEMU HMP `mouse_move` doesn't reach a UEFI/virtio guest). Their backing telemetry globals (`wsys_nudge_ok/drop/start_j/active`, `devwsys.ad:2384`) and the dead accessors above are part of this scaffold. Recommendation: once a DE-perf harness can inject through `/dev/mouse` directly, retire the three verbs + their counters. Marked NEEDS-REVIEW because the verbs are the current working unblock for an active harness.
- [NEEDS-REVIEW] `arch/x86/kernel/syscall.ad:4214/4235/4245` — `SYS_WSYS_ALLOC` (293) / `SYS_WSYS_FREE` (294) / `SYS_VK_WINDOW_FRAME` (312) syscall arms vs. the `/dev/wsys/ctl` `alloc`/`free`/`frame` verbs (`devwsys.ad:3335`+). The ctl verbs are the NEW Plan-9-shape canonical path (`namec.ad:496`: "Replaces SYS_WSYS_ALLOC=293…"). **As of the F2 #447 / audit §4 "thin-shim conversion" the syscall arms now FORMAT a ctl-text and DELEGATE to the verb path** (`syscall.ad:325`,`2932`) — i.e. they no longer duplicate logic, they forward. So this is a retained compat shim, not a true duplicate implementation. **CANONICAL = the ctl verbs.** Recommendation: remove the three syscall arms once all callers use the ctl files; keep the numbers reserved (see the `_RETIRED` tombstone convention below). Not SAFE-REMOVE yet — arms are still dispatched and may have live callers.
- [NEEDS-REVIEW] Retired-syscall tombstones — `SYS_TLS_CONNECT_RETIRED` (`syscall.ad:674`), `SYS_SOCKET_RETIRED`/`CONNECT_RETIRED`/`ACCEPT_SOCK_RETIRED`/`BIND_SOCK_RETIRED`/`LISTEN_SOCK_RETIRED` (`syscall.ad:952-957`). Refcount 1 each. These are **intentional number-reservation tombstones** (functionality moved to `/net` ctl files, `devnet.ad`) preventing syscall-number reuse. NOT dead code to delete — this is the documented retirement pattern. Leave as-is.

---

## 3. ORPHAN FILES (in scope, not linked by any build)

- [NEEDS-REVIEW] `arch/x86/boot/uefi_entry.ad` — UEFI/PE entry scaffold. NOT in `init/main.ad`'s import graph (zero importers tree-wide) and NOT auto-linked (only `.S` files are globbed; `.ad` files link via imports). Its symbols `uefi_main` (`:54`), `uefi_init` (`:64`), class `EfiSystemTable` (`:30`), and consts `EFI_*` are all zero-reference. The file itself documents it as an unbuilt "L38 scaffold… place to drop UEFI-specific helpers" pending a `--target=x86_64-uefi-efi` backend. Recommendation: KEEP as an intentional, clearly-labelled placeholder OR delete until the UEFI backend exists. If kept, note that `set_boot_via_efi`/`efi_set_variable` (category 1) are its would-be callers and should be removed/kept together.

No other orphans. All x86 `.S` are auto-globbed/linked; ARM64 links `boot.S`+`vectors.S`+`kmain.ad` (all used); every `sys/src/9/port` `.ad`, all `kernel/`, `mm/`, and remaining `arch/x86` `.ad` are reachable from `init/main.ad` (via the `port9->9` symlink for the 9/port tree).

---

## 4. DUPLICATE / COPY-PASTE

- [NEEDS-REVIEW] **`*_u64_to_dec` reverse-fill decimal formatter — ~14 byte-identical copies in scope (~24 tree-wide).** Each Plan-9 dev file rolls its own module-private clone with an identical body (verified `devtime.ad:30` vs `devpid.ad:20` are character-for-character identical apart from the function name; both even cite the common ancestor `fs/procfs.ad::_buf_put_dec` in their comments). Copies in scope:
  `devcpuinfo.ad:74 _devcpuinfo_u64_to_dec`, `devuptime.ad:42 _devuptime_u64_to_dec`,
  `devblk.ad:305 _u64_to_dec`, `devmountrpc.ad:35 _mrpc_u64_to_dec`,
  `devtime.ad:30 _devtime_u64_to_dec`, `devpid.ad:20 _devpid_u64_to_dec`,
  `devdiskstats.ad:78 _devdiskstats_u64_to_dec`, `devmouse.ad:40 _devmouse_u64_to_dec`
  (+ `:59 _devmouse_i32_to_dec`), `devloadavg.ad:53 _devloadavg_u64_to_dec`,
  `devmeminfo.ad:53 _devmeminfo_u64_to_dec`, `devstat.ad:99 _devstat_u64_to_dec`,
  `devproc.ad:285 _u64_to_dec` (+ `:310 _i64_to_dec`), `devmounts.ad:74 _devmounts_u64_to_dec`,
  `devwsys.ad:819 _wsys_u64_to_dec`. Tree-wide also `user/hamUI.ad:104`, `user/hamUId.ad:178`,
  `user/aplay.ad:35`, `user/x11/x11srv.ad:129`, `tests/test_devurandom.ad:37`, etc.
  **No shared canonical helper exists** — `fs/procfs.ad` has its own private
  `_buf_put_dec/_buf_put_dec2/_buf_put_dec4` (also a 3-way near-dup). Recommendation:
  add ONE public helper (e.g. `kernel/printk` or a new `lib`-level `fmt`) —
  `u64_to_dec(value, out) -> bytes` — and have every dev file import it. This deletes
  ~20 duplicate bodies. NEEDS-REVIEW (each copy is currently live; this is a consolidation
  refactor, not a delete-in-place).
- [NEEDS-REVIEW] **`*_emit_str` buffer-append helper — ~11 byte-identical copies in scope.** Same story, paired with the formatters:
  `devcpuinfo.ad:95 _ci_emit_str`, `devuptime.ad:63 _up_emit_str`,
  `devfirewall.ad:276 _fwd_emit_str`, `devdiskstats.ad:99 _ds_emit_str`,
  `devloadavg.ad:74 _la_emit_str`, `devmeminfo.ad:74 _mi_emit_str`,
  `devversion.ad:33 _ver_emit_str`, `devstat.ad:120 _st_emit_str`,
  `devmounts.ad:95 _mt_emit_str`, `devwsys.ad:838 _wsys_emit_str`,
  plus `_*_emit_u64` variants (`devnscap.ad:74`, `devdiskstats.ad:110`,
  `devstat.ad:131`, `devauth.ad:508`, `devwsys.ad:3600/5854`, `mm/slab.ad:369`,
  `kernel/sched/cgroup_cpu.ad:317 _put_dec`). Recommendation: fold into the same
  shared `fmt` helper module as the `u64_to_dec` consolidation above.

These two clusters are the single largest cleanup opportunity in scope: one shared
`fmt` helper (`u64_to_dec` + `emit_str` + `emit_u64`) collapses ~40 duplicated
private functions across the dev files into 3 shared ones.
