# Dead-code / redundancy audit — `fs/` and `linux_abi/`

READ-ONLY audit (2026-06-15). Scope: `fs/*.ad` (22 files, ~43.6k LOC) and
`linux_abi/*.ad` (113 files, ~89.3k LOC). All evidence is tree-wide grep over
`**/*.ad` plus build scripts. Tags:

- **SAFE-REMOVE** — zero references tree-wide, not reachable via any dispatch /
  hook / func-pointer / string-name mechanism; removal is mechanically safe.
- **NEEDS-REVIEW** — unreferenced *now* but is a designed entry point,
  future-work scaffold, or an architectural-redundancy call that warrants a
  human decision, not a blind delete.

Method note on false-positive guards (per brief): syscall dispatch in
`linux_abi/u_syscalls.ad` is an explicit `if nr == SYS_x: return _u_x(...)`
chain (NOT a function-pointer table), so a zero-name-reference def there is
genuinely un-dispatched. `linux_abi` handlers registered via `_add_export(...)`
were checked by their *string* export name, not just the Adder symbol.

---

## 1. DEAD CODE — zero-reference functions (SAFE-REMOVE)

- [SAFE-REMOVE] linux_abi/u_syscalls.ad:5366 `_u_unimpl_fstat` — `-ENOSYS`
  placeholder for fstat(2) — superseded by real `_u_fstat` (def :8195,
  dispatched :14235); zero references tree-wide outside its own def. The
  `_u_unimpl_*` *naming pattern* is intentional (a deliberate grep target for
  not-yet-impl syscalls, per the comment at :5360), but THIS instance is a
  leftover from before fstat was implemented. — recommendation: delete.

- [SAFE-REMOVE] linux_abi/u_syscalls.ad:8521 `_u_unimpl_newfstatat` —
  placeholder superseded by real `_u_newfstatat` (def :8260, dispatched
  :14429); 0 refs. — recommendation: delete.

- [SAFE-REMOVE] linux_abi/u_syscalls.ad:8324 `_u_unimpl_uname` — placeholder
  superseded by real `_u_uname` (def :8051, dispatched :14349); 0 refs. —
  recommendation: delete. (The other 9 `_u_unimpl_*` defs ARE still
  dispatched — leave them.)

- [SAFE-REMOVE] linux_abi/u_syscalls.ad `_fan_readable` — fanotify
  helper whose last caller is gone (0 refs outside def). — recommendation:
  delete.

- [SAFE-REMOVE] linux_abi/u_syscalls.ad `_path_eq_const4` — 4-char
  literal-path compare helper; 0 refs. Same family as the F10-9 `is_*_path`
  string predicates that were retired when path classification moved to the VFS
  mount table. — recommendation: delete.

- [SAFE-REMOVE] linux_abi/u_syscalls.ad:3682 `vdso_clock_gettime_syscall_count`
  — accessor for a vDSO fallback counter; 0 refs (the counter is read nowhere).
  — recommendation: delete (or wire into a selftest if the metric is wanted).

- [SAFE-REMOVE] fs/procfs.ad `cgroup_selftest` — selftest never imported
  by init. Siblings `cpuinfo_selftest` / `procmounts_selftest` /
  `procnet_selftest` ARE imported + invoked from init/main.ad:426/7336/7372;
  this one and `node_selftest` are not. 0 callers. — recommendation: delete (or
  wire into init's procfs selftest gate alongside its siblings).

- [SAFE-REMOVE] fs/procfs.ad `node_selftest` — as above, orphaned
  selftest, not imported by init, 0 callers. — recommendation: delete or wire.

- [SAFE-REMOVE] fs/vfs.ad `vfs_open_fuse_file_l2` — thin wrapper
  `return _open_fuse_file_marked(name)`. Sibling `vfs_open_cgroup_l2` has 3
  callers; this `_l2` variant has 0. — recommendation: delete (the underlying
  `_open_fuse_file_marked` stays).

- [SAFE-REMOVE] fs/vfs.ad `vfs_open_node_l2` — same `_l2` family; 0
  callers (cgroup_l2 used, node_l2/fuse_file_l2 not). — recommendation: delete.

- [SAFE-REMOVE] fs/vfs.ad `vfs_fd_socketpair_packed` — V5 accessor for the
  `(slot<<1|dir)` pack; its own comment says the pack "lives in the
  DEV_SOCKETPAIR chan's back_slot now" (Phase 4c socket fold). Superseded; 0
  refs. — recommendation: delete.

- [SAFE-REMOVE] fs/ext4.ad `_ext4_leaf_entries` — extent-count helper for
  inline depth-0 leaves; 0 refs (callers refactored away). — recommendation:
  delete.

- [SAFE-REMOVE] fs/ext4.ad `_ext4_xattr_region_used` — xattr live-region
  byte-length helper; 0 refs. — recommendation: delete.

- [SAFE-REMOVE] fs/ext4.ad `_ext4_fc_eq` — fast-commit comparison helper;
  0 refs. — recommendation: delete.

- [SAFE-REMOVE] fs/ext4.ad:8018 `ext4_fc_add_creat` / :8024 `ext4_fc_add_unlink`
  — thin tag-wrappers over `_ext4_fc_add_dirent` (CREAT/UNLINK tags). The
  underlying `_ext4_fc_add_dirent` and the inode/data-block fast-commit adders
  ARE driven (ext4.ad:8346/8353), but these two dirent-tag wrappers have 0
  callers — the fast-commit path never journals create/unlink dirents. —
  recommendation: delete the two wrappers, OR wire them into the fast-commit
  create/unlink path if FC dirent journaling is intended.

## 1b. DEAD CODE — NEEDS-REVIEW (designed entry points / unexposed features)

- [NEEDS-REVIEW] fs/vfs.ad:3638 `vfs_rmdir` — full rmdir(2) backend (routes
  `/ext/*` -> `ext4_rmdir`). Its own comment says "the kernel rmdir(2) sysfile
  path *should* dispatch here," but nothing calls it; the actual rmdir(2)
  syscall handling lives in u_syscalls.ad (~:2862) and does not route through
  this helper. — recommendation: either wire the rmdir(2) path to call
  `vfs_rmdir`, or delete it as a stale stub. Do not blind-delete — it's a
  load-bearing-looking VFS op.

- [NEEDS-REVIEW] fs/ext4.ad `ext4_get_acl` / `ext4_set_acl` — complete
  POSIX-ACL get/set implementations (route through
  `system.posix_acl_access`/`_default` xattrs). No syscall/VFS caller reaches
  them — the ACL feature is implemented but not exposed. — recommendation:
  keep if ACL exposure is roadmapped (wire to a getxattr/setxattr or
  acl(5) path); otherwise retire. Substantial, intentional code — human call.

## 1c. ORPHAN FILES (NEEDS-REVIEW — future-work scaffolds, not wired into build)

- [NEEDS-REVIEW] linux_abi/u_ldso.ad — dynamic-linker scaffold. NOT imported by
  any `.ad`, `.py`, `.sh`, or `.json` (0 refs tree-wide; only mentioned in a
  comment inside u_libc.ad). File header self-describes as U-series design
  scaffold. — recommendation: keep as parked future-work OR move under a
  `docs/`/`design/` scaffold area so it doesn't read as live kernel source.

- [NEEDS-REVIEW] linux_abi/u_libc.ad — "mini libc.so.6 stub ... DESIGN scaffold,
  bodies are placeholder stubs." NOT imported anywhere (0 refs). — recommendation:
  same as u_ldso — parked future-work; mark clearly or relocate.

  (No `fs/` orphans — all 22 fs modules are imported. All other `linux_abi`
  modules resolve to >=1 importer; the apparent `refs=1` for many `api_*` /
  `u_*` modules is their single hub importer in `linux_abi/init.ad` or
  `loader.ad`, which is correct, not orphaned.)

---

## 2. REDUNDANT MECHANISMS

### 2a. F10-9 `is_*_path` string predicates — dead survivors (SAFE-REMOVE)

F10-9 moved path classification off literal-string probes onto the VFS mount
table (see comments at u_syscalls.ad:624/648/3395/7465/9197/9690 and
fs/vfs_mount.ad:17). Four predicates survived with their bodies but lost every
caller (only comments referencing them remain, several literally saying they
"are no [longer used]"):

- [SAFE-REMOVE] fs/tmpfs.ad:372 `is_var_path` — 0 non-comment call sites
  (only u_syscalls.ad:624 comment). — delete.
- [SAFE-REMOVE] fs/tmpfs.ad:380 `is_tmpfs_path` — 0 non-comment call sites
  (comments only in vfs_mount.ad:17, tmpfs.ad:30/344, u_syscalls.ad:624). —
  delete.
- [SAFE-REMOVE] fs/fat.ad:1914 `is_fat_path` — 0 non-comment call sites
  (comments only in vfs_mount.ad:17, fat.ad:130/1929). — delete.
- [SAFE-REMOVE] fs/procfs.ad:2653 `is_proc_path` — 0 non-comment call sites
  (comments only in tmpfs.ad:383, vfs.ad:1993/3237). — delete.

  STILL-ALIVE `is_*_path` (do NOT touch): `is_tmpfs_dir_path`
  (fs/tmpfs.ad:391, 4 callers in tmpfs.ad), `is_cgroup_path`
  (fs/procfs.ad:2058, called vfs.ad:6582), `is_node_path` (fs/procfs.ad:2319,
  called vfs.ad:2011).

### 2b. Dual path resolvers `resolve_path` vs `namec` (NEEDS-REVIEW — by design)

- [NEEDS-REVIEW] fs/vfs.ad:4579 `resolve_path` AND sys/src/9/port/namec.ad
  `namec` — two path-resolution spines. Both are LIVE and heavily called
  (`namec` ~ 8 sites incl. chan/sysfile/devauth; `resolve_path` ~ 15 sites incl.
  Linux-ABI u_* handlers, coredump, httpd). They are NOT duplicates: `namec` is
  the universal Plan 9 Chan/devtab spine; `resolve_path` is the Linux-ABI
  string-name walker that itself calls `ns_walk` (chan.ad) to reach a
  backend-addressable name. The redundancy is the documented native-Plan9 vs
  Linux-ABI-string-name split, not dead code. — recommendation: no action;
  noted so a future "one resolver" consolidation is a conscious decision.

### 2c. api_autostubs vs hand-written exports — NO drift currently (CLEAN)

- [CLEAN] linux_abi/api_autostubs.ad — generated by scripts/gen_autostubs.py.
  Verified each of its 7 `_add_export` names (`__tracepoint_dma_fence_signaled`,
  `__tracepoint_mmap_lock_{acquire_returned,released,start_locking}`,
  `__x86_indirect_thunk_rsi`, `__SCK__/__SCT__tp_func_dma_fence_signaled`)
  appears in ZERO other `linux_abi/*.ad`. The generator's "skip hand-shimmed
  names" contract is holding; no duplicate/drift to remove today. — recommendation:
  keep the gen_autostubs CI dedupe; nothing to delete. (The memory warning about
  api_autostubs drift is currently a non-issue — re-verify after any module-set
  change.)

### 2d. Native-syscall-arm vs Linux-ABI duplicate handler — none found in scope

  For fs ops in scope, the native side dispatches via `namec`/devtab + sysfile,
  and the Linux-ABI side via `_u_*` in u_syscalls.ad calling into the same fs
  backends (ext4_*, tmpfs_*). They share the backend rather than duplicating it —
  no redundant second implementation of the same op was found. (The closest is
  the resolver split in 2b, already noted.)

### 2e. crc32c — two implementations, two consumers (NEEDS-REVIEW — by design)

- [NEEDS-REVIEW] fs/crc32c.ad (`crc32c`, `crc32c_update`) AND
  linux_abi/api_crypto.ad (`__crc32c_le` + lazy `crc32c_table`). Two CRC-32C
  implementations. NOT collapsible casually: the fs one is the native in-kernel
  helper for ext4/btrfs metadata; the api_crypto one is the Linux-ABI export
  symbol that stock `.ko` modules (crc32c_generic/libcrc32c) link against. —
  recommendation: leave; optionally have api_crypto's `__crc32c_le` delegate to
  fs/crc32c.ad to dedupe the table+inner loop (small win, not urgent).

---

## 3. DUPLICATE / COPY-PASTE — none actionable in scope

- Per-filesystem `*_readdir` / dir-entry parsers (iso9660_readdir, btrfs_readdir,
  sqfs_readdir, ntfs_readdir, fat `_fat_write_dir_entry`, ext4 `_ext4_dirent_*`)
  are inherently format-specific — distinct on-disk layouts, not copy-paste.
  No shared-helper extraction is warranted.
- `mkfs` paths are per-fs (fat_mkfs.ad `_fmk_*` vs ext4.ad `_ext4_mkfs_*`) and
  legitimately distinct. No duplicate mkfs/fsck path for the same fs was found.
- `stat`/`fstat` backends (`_u_fill_stat`/`_u_fill_statx`/`_u_fstat`/`_u_stat*`)
  share fill helpers and route to one VFS getattr — no duplicate stat backend.
- SHA-256 appears in fs/sha256.ad (`sha256_oneshot`) and again in user/hpm.ad
  (`_sha256_*`). The hpm copy is USER-namespace (out of audit scope) and cannot
  link the kernel fs helper; noted only — not an fs/linux_abi finding.

---

## Summary counts

- SAFE-REMOVE: 19 symbols (11 §1 dead functions incl. the 2 ext4_fc_add_* and
  vfs_open_node_l2, + 4 §2a F10-9 predicates + the ext4 helper cluster).
- NEEDS-REVIEW: 7 items (`vfs_rmdir`, `ext4_get_acl`, `ext4_set_acl`,
  u_ldso.ad orphan, u_libc.ad orphan, resolve_path/namec split, crc32c dual).
- CLEAN (checked, no action): api_autostubs drift, native-vs-Linux-ABI fs
  handler dup, per-fs readdir/mkfs/stat "duplication".

### Top 5 SAFE-REMOVE

1. linux_abi/u_syscalls.ad — `_u_unimpl_fstat`, `_u_unimpl_newfstatat`,
   `_u_unimpl_uname` (3 superseded `-ENOSYS` placeholders; real handlers
   dispatched).
2. fs/tmpfs.ad `is_var_path` + `is_tmpfs_path`, fs/fat.ad `is_fat_path`,
   fs/procfs.ad `is_proc_path` (F10-9 retired-mechanism string predicates,
   0 callers, comments confirm).
3. fs/vfs.ad `vfs_fd_socketpair_packed` (Phase-4c socket-fold superseded
   accessor) + `vfs_open_fuse_file_l2` + `vfs_open_node_l2` (unused `_l2`
   wrappers; cgroup_l2 variant is the only live one).
4. fs/procfs.ad `cgroup_selftest` + `node_selftest` (orphaned selftests not
   imported by init; siblings cpuinfo/procmounts/procnet are wired).
5. fs/ext4.ad `_ext4_leaf_entries`, `_ext4_xattr_region_used`, `_ext4_fc_eq`,
   `ext4_fc_add_creat`, `ext4_fc_add_unlink` (orphaned ext4 internal helpers /
   unused fast-commit dirent-tag wrappers).
