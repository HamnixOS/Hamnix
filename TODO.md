# Hamnix TODO

Open work items not yet scheduled to a specific milestone. Items here
are fair game for any contributor — human or AI agent.

**Source of truth for the project direction lives in `docs/`:**

- [`docs/architecture.md`](docs/architecture.md) — the layered model
  (Layer 0..5), boundary rules, per-subsystem layer assignments, and
  the eight-phase migration plan. Read this first; the L+U tracks
  must keep passing through every phase.
- [`docs/native-api.md`](docs/native-api.md) — Layer 1 Plan 9-shape
  syscall reference (~25 calls). Includes the full migration table
  mapping every existing `SYS_*` to its new home.
- [`docs/vtnext-v2.md`](docs/vtnext-v2.md) — Layer 4 graphical wire
  protocol (apps → `hamwd` → renderer). The OS's path to a windowed
  desktop without DRM/Mesa/Vulkan.
- [`README.md`](README.md) — current implementation snapshot:
  shipped milestones (M16.x bare-metal kernel, L-track .ko's,
  U-track Linux ELFs), commit references, working agreements.

When picking a TODO item, check which layer it belongs to and which
phase it's blocking, then look at the relevant doc for the contract
it has to honour.

## Language

- ~~**`do-while` loop** — shipped in commit `c563762`.~~

## Compiler

- Unsigned-comparison codegen extended past `<`/`<=`/`>`/`>=` — also
  need `shrq` (logical) for unsigned right-shift (today always signed
  `sarq`), and `divq`/`modq` family for unsigned types (today always
  signed `idivq`).
- First-class function pointers — currently every indirect call
  drops into `asm_volatile("call *%rax")`. A real `Fn[R, *A]` type
  with proper SysV codegen would clean up dozens of asm helpers.
- `match`/`case` keyword tokenisation — reserved but not implemented;
  pick one of "Python 3.10 match" or "C switch" and ship.

## Plan 9 native surface (Layer 1)

- ~~**Phase B** — Reserve the Plan 9 syscall number block (256..274).
  Shipped in M16.93: SYS_RFORK (256), SYS_BIND (257), SYS_MOUNT (258),
  SYS_UNMOUNT (259), SYS_CREATE (260), SYS_STAT_P9 (261),
  SYS_FSTAT_P9 (262), SYS_REMOVE (263), SYS_FD2PATH (264),
  SYS_ERRSTR (265) all wired through `arch/x86/kernel/syscall.ad`'s
  `do_syscall`. SYS_ERRSTR has a real body in
  `sys/src/9/port/error.ad`; the rest return -ENOSYS until Phase C.~~
- **Phase C** — Land real bodies for the Plan 9 primitives next to
  the existing Linux-shape calls. Order proposed by
  `docs/architecture.md`:
  - ~~`rfork` (256) — shipped in M16.98. Body lives in
    `sys/src/9/port/sysproc.ad`; `TaskStruct` carries the three
    new sharing-state fields (`fd_table_refcount`, `namespace_id`,
    `note_group`) with accessors + monotonic id allocators in
    `kernel/sched/core.ad`. `user/runtime.S::sys_rfork` stashes the
    parent's user `%rbp` into syscall arg a5 so `do_rfork` can
    patch the child's initial-stack image. POSIX-fork combo
    (`RFPROC | RFFDG | RFNAMEG | RFENVG`) verified end-to-end by
    `scripts/test_rfork.sh`.~~ Follow-ups still pending:
      * `RFMEM` (thread path) returns -ENOSYS today. The full
        thread route needs caller-supplied `child_stack` plus
        CLONE_SETTLS-shape TLS plumbing — mirror the do_clone
        thread branch into `do_rfork` once a Plan 9 `pthread`-
        equivalent caller exists.
      * Namespace machinery body — `alloc_namespace_id` hands back
        a fresh int32 but no actual mount-table deep-copy happens
        because Hamnix has no mount table yet. Lands with the
        `bind` / `mount` bodies below.
      * ~~Note delivery — `notify(2)` (270) / `noted(2)` (271)
        shipped in M16.109. Bodies in `sys/src/9/port/sysnote.ad`;
        TaskStruct grew `note_handler_rip` + `note_pending` +
        `note_saved_rip` + `note_saved_rsp` + a 128-byte
        `note_msg` slot (`kernel/sched/core.ad`).
        `sys/src/9/port/devproc.ad` learned the `note` file_kind:
        writes to `/proc/<pid>/note` look up the target task,
        copy the message into its `note_msg` buffer, save the
        current saved-user-RIP/RSP, and rewrite the saved-RIP slot
        to the handler — so SYSRETQ on the in-flight write
        delivers control to the handler in user mode.
        End-to-end verified by `scripts/test_note.sh`.~~
        Follow-ups:
          - `note_group`-wide delivery (Plan 9 "killable group" idiom)
            — `do_rfork`'s RFNOTEG already tracks the group id; the
            devproc_write path currently looks up a single target
            pid. Group walk lands when the daemon-supervisor use
            case exists.
          - Cross-task delivery — writing to ANOTHER task's
            `/proc/<pid>/note` is parsed + accepted but logs and
            drops; the full path needs to patch the target's
            stashed iret frame from outside its syscall context.
          - NDFLT action (default = terminate target). Phase C
            silently treats every action arg as NCONT (continue).
          - Handler message argument — Plan 9 calls
            `handler(void *ureg, char *msg)`. The syscall return
            stub deliberately zeroes %rdi outside FUTEX (see
            `arch/x86/kernel/syscall_64.S`); threading the msg
            pointer through requires touching that stub. Until
            then the message is parked in `TaskStruct.note_msg`
            and not yet surfaced to user space.
      * Detach (`RFNOWAIT`) — accepted but does not yet sever the
        child's parent_pid; lands when `wait4` learns to drop
        RFNOWAIT children automatically.
  - ~~`bind` (257) + `mount` (258) + `unmount` (259) — shipped in
    M16.107. Channel + 32-entry mount-table skeleton lands in
    `sys/src/9/port/chan.ad` (new); syscall bodies in
    `sys/src/9/port/syschan.ad` (new). `fs/vfs.ad::resolve_path`
    grows a one-call `chan_resolve_prefix` hook that rewrites the
    longest-prefix mount entry before the existing cpio / tmpfs /
    ext4 routing — so `bind("/sysroot", "/etc", MREPL)` makes
    `open("/sysroot/motd")` resolve to the cpio-backed `/etc/motd`.
    `mount(srvfd, -1, "/dev/win", MREPL, "")` records a SRV-kind
    chan; the actual 9P traffic over `srvfd` is Phase D's hamwd
    job. `unmount(NULL, old)` removes every binding at `old`;
    `unmount(new, old)` removes the specific edge. End-to-end
    fixture `tests/test_p9mount.ad`. See `scripts/test_p9mount.sh`.~~
    Follow-ups:
      * Union mounts (`MBEFORE` / `MAFTER`) — flag is recorded by
        the entry but `chan_resolve_prefix` picks longest-prefix
        only; no union walk. Phase D follow-up alongside hamwd.
      * Per-namespace mount-table deep-copy on `rfork(RFNAMEG)` —
        today the rfork helper just allocates a fresh
        `namespace_id`; the mount table is still shared via
        `_entry_visible`'s "shared OR private match" rule rather
        than copied. Real deep-copy lands when union semantics
        need it.
      * Real 9P `chan_attach` — `chan.ad::chan_attach` stores the
        srvfd but doesn't speak `Tversion`/`Tattach` over it. Phase
        D's hamwd grows the wire side.
  - ~~`create` (260) — shipped in M16.101. Body in
    `sys/src/9/port/sysfile.ad::do_create`. Delegates to
    `vfs_open_write` for the regular-file path. DMDIR returns -1
    with `errstr("create failed: DMDIR not supported")` until a
    real `vfs_mkdir` backend exists (SYS_MKDIR=22 is still a no-op
    stub).~~ Follow-up: wire DMDIR to a real directory-create path
    once tmpfs / ext4 grow `mkdir` (Phase G).
  - ~~`remove` (263) — shipped in M16.101. Body in
    `sys/src/9/port/sysfile.ad::do_remove`, thin `vfs_unlink`
    wrapper. SYS_UNLINK (21) stays live concurrently; Phase G
    retires the old number.~~
  - ~~`stat` / `fstat` (261 / 262) — shipped in M16.101. 9P-shape
    `Dir` record serialiser in `sys/src/9/port/sysfile.ad`
    (`_write_dir_record` + `do_stat` + `do_fstat`). stat walks the
    cpio archive (`_cpio_lookup`); fstat synthesises per-`FD_*_MARK`
    records (cons / time / pid / random / null / zero / stdio /
    dir / pipe) plus initramfs-backed fds. tmpfs / fat / ext4 /
    socket fds return -1 with `errstr("fstat: backend not
    supported")` — follow-up to grow per-backend stat hooks.~~
  - ~~`fd2path` (264) — shipped in M16.101. Best-effort: returns
    the canonical cpio archive name for initramfs fds (may differ
    from the path the caller called open() with), synthetic
    `/dev/<name>` for cdev fds, and -1 + `errstr("fd2path:
    backend has no path")` for pipes / sockets / tmpfs / fat /
    ext4. Documented gap — Phase G adds a per-fd path slot to
    TaskStruct (deferred this round because the brk agent owns
    TaskStruct edits) so we can return the EXACT open()-time path
    9front's sysfd2path guarantees.~~
  - ~~`wstat` / `fwstat` (266 / 267) — shipped. Bodies in
    `sys/src/9/port/sysfile.ad::do_wstat` + `do_fwstat`. Closes the
    Phase B reserved-syscall block (256..271) — everything reserved
    is now real. The Dir-record parser honours TWO mutable fields
    today:
      * `name` (rename) — routed through new `vfs_rename`
        (`fs/vfs.ad`) → `tmpfs_rename` (`fs/tmpfs.ad`). The new
        name is taken as a basename; the kernel stitches the old
        parent dir onto it (Plan 9 wstat semantics).
      * `mode` (chmod) — accepted as a successful no-op (no
        per-inode mode storage yet).
    `length` / `mtime` / `gid` / `muid` MUST be the wstat sentinel
    (`~0` for ints, empty string for counted strings); a non-
    sentinel value surfaces -1 with
    `errstr("wstat: <field> not supported")`. `fwstat` is wired
    for FD_TMPFS_MARK fds only; other backends report
    `errstr("fwstat: backend not supported")`. End-to-end fixture
    `tests/test_p9wstat.ad`; see `scripts/test_p9wstat.sh`.~~
    Follow-ups:
      * `length` (truncate) — needs a backend hook
        (`tmpfs_truncate`, `ext4_truncate`). Cheap on tmpfs (just
        set `.size`), harder on ext4 (must walk + free extents).
      * `mtime` (utime) — Hamnix has no per-inode mtime storage
        today; the stat path returns boot-jiffies for every file.
        Plumb a real per-inode mtime through tmpfs + ext4 first,
        then make wstat write into it.
      * `gid` / `muid` — wait for a users database (`/adm/users`
        in Plan 9). Hamnix is single-user (`hamnix`) so the field
        has nowhere meaningful to land.
      * `mode` storage — drop the no-op and plumb the new value
        through `tmpfs.TmpfsEntry` + ext4 inode rewrite once
        per-inode mode bits exist.
      * `ext4` rename — `vfs_rename` returns -EROFS for non-tmpfs
        paths. ext4 needs `ext4_dir_remove` + `ext4_dir_insert` in
        the same transaction; lands alongside the L-track ext4
        write expansion.~~
- ~~**Phase C.5** — distro-shape namespaces (`docs/distro-namespaces.md`).
  Shipped as `user/distrorun.ad` + `scripts/test_distro_namespace.sh`.
  `distrorun <distro> <cmd> [args...]` opens
  `/var/lib/distros/<distro>` for the srvfd, `rfork(RFNAMEG)`s in
  place, `mount(srvfd, -1, "/", MREPL, "")`s the backing at root
  (inert in Phase C — recorded as CHAN_KIND_SRV; resolve_path falls
  through), then `bind`s the distro-shape subdirs `/etc /usr /lib
  /var` onto `backing/{etc,usr,lib,var}` so the bind prefix matcher
  actually rewrites lookups, then re-binds the shared paths (`/home
  /net /srv /dev /proc`) onto themselves, and finally `exec`s
  argv[2..]. The test fixture lives at
  `tests/distros/testdistro/etc/{debian_version,os-release}`
  (`build_initramfs.py` walks `tests/distros/<name>/` and embeds at
  `/var/lib/distros/<name>/`). End-to-end markers: `[distrorun]
  bound /etc -> backing/etc ok` + `[distrorun] entered namespace
  ok` + `[testdistro] /etc/debian_version=12.0` (inside namespace)
  + `[native(-post)] /etc/debian_version=hamnix/0.1` (outside,
  unchanged before AND after the namespace child exits).
  `user/runtime.S` grew thin `sys_bind`/`sys_mount`/`sys_unmount`
  wrappers (Plan 9 syscall numbers 257/258/259) mirroring the
  existing `sys_chdir` shape.~~ Follow-ups:
    * ~~Debootstrap'd Debian backing — landed via
      `tests/distros/debian-minbase/{BUILD.sh,MANIFEST.txt,HOWTO.md}`
      + `scripts/test_distro_debian.sh`. `BUILD.sh` runs
      `debootstrap --variant=minbase --include=bash,coreutils
      stable ./rootfs http://deb.debian.org/debian` (one-time host
      step, ~80-150 MB, gitignored). `scripts/build_initramfs.py`
      learned a `HAMNIX_EMBED_DEBIAN={1,minimal,full}` opt-in:
      `minimal` (default when set) embeds a curated subset
      (`/etc/{debian_version,os-release,passwd,group,hostname}` +
      `/usr/lib/os-release`) sized to fit `fs/cpio.ad`'s
      `NR_FILES=192` cap; `full` walks every file in `rootfs/`
      (currently overflows the cap; lands when `NR_FILES` bumps +
      the cpio archive can ingest ~250 MB without inflating
      `fs/initramfs_blob.S` past GitHub's 100 MB push limit).
      End-to-end:
      `/bin/distrorun debian-minbase /bin/cat /etc/debian_version`
      reads the REAL Debian release token ("13.5" for trixie) from
      the debootstrap'd backing while the parent's namespace still
      reads "hamnix/0.1".~~
    * Convenience aliases at `/bin/deb`, `/bin/ubuntu`, `/bin/suse`
      that pre-translate the distro name. Each is a 200-byte
      wrapper around `distrorun <fixed-distro-name> ...argv`.
      Defer until at least one real backing tree exists.
    * `debfs` 9P server (`docs/distro-namespaces.md` Backing stores
      #2). Replaces disk-backed `/var/lib/distros/<name>/` with an
      on-demand 9P-served FHS view assembled from a `.deb` package
      store. Layer 3 service; lands after Phase F.
    * Real Debian BINARY (not just /etc/* file) running inside a
      namespace — `deb /bin/true` actually exec'ing the Debian-
      shipped `/bin/true`. U42 landed the kernel-side dynamic
      ELF interpreter — fs/elf.ad now follows PT_INTERP and loads
      ld-linux-x86-64.so.2 as a real ELF interpreter; AT_BASE /
      AT_ENTRY / AT_PHDR auxv plumbed correctly; the
      `linux_abi/u_syscalls.ad` mmap path grew file-backed
      MAP_PRIVATE plus a MAP_FIXED-into-prior-mapping overlay so
      ld.so's two-phase DSO load (reserve, then per-PT_LOAD
      MAP_FIXED) makes forward progress. Verified by
      scripts/test_u42_dynamic_elf.sh: 3/3 kernel-side checks fire
      ("PT_INTERP detected", "interpreter loaded at distinct base",
      "Linux-ABI binary detected"); ld.so successfully reaches
      userspace, opens + mmaps libc.so.6, applies relocations, and
      jumps to the application's _start.
      
      Remaining blockers for the final puts() to land on serial:
        - ~~Real VMA layer / true MAP_FIXED~~ DONE: per-task VMA
          list shipped in `mm/vma.ad` (U42 follow-up). Each
          `TaskStruct` owns a `vma_list_head` pointer; mmap /
          munmap / mprotect / mremap all route through `vma_alloc`
          / `vma_unmap` / `vma_protect`, which maintain a sorted
          singly-linked list of `VmaNode` records. MAP_FIXED inside
          an existing reservation aliases the enclosing node's
          backing pages (the ld.so PT_LOAD-overlay case); MAP_FIXED
          outside any reservation carves overlapping ranges per
          Linux semantics. `do_execve` calls `vma_clear` before
          loading the new ELF so the new image starts with an empty
          namespace of virtual-address contents. Per-page PTE
          protection is still advisory (the 4 GiB identity map is
          RWX U=1) — the VMA layer records `prot` so a future
          per-page mprotect can install real bits without
          re-touching the syscall surface.
        - VMA share / deep-copy on rfork — today every fresh task
          starts with an empty `vma_list_head`. RFMEM (share) needs
          the thread path in `create_user_thread` to copy the
          parent's head pointer; RFPROC + no RFMEM (deep copy)
          needs a walk-and-clone in `do_clone`. Both deferred until
          a real multi-process Linux workload (apt fork+exec)
          surfaces the gap.
        - MAP_SHARED with cross-process coherence — only matters
          for `/dev/shm`-style cases; deferred.
        - `fs/cpio.ad` `NR_FILES` bump (192 -> 8192+) so the full
          debootstrap'd tree (~5000 files) fits in the cpio
          archive. Today scripts/test_u42_dynamic_elf.sh works
          around this by injecting ONLY ld.so + libc.so.6 into the
          cpio archive post-build; a real `deb /bin/true` flow
          needs the entire DT_NEEDED transitive closure too.
        - libdl / dlopen — U42 covers the loader's job up to "ld.so
          executes from userspace". Anything beyond `puts()` that
          calls dlopen() ("apt install" loads plugins) needs the
          full DT_NEEDED + ld.so.cache search-path machinery to
          actually find DSOs in the namespace. Out of U42 scope.
        - Namespace plumbing for the interpreter lookup — fs/elf.ad's
          `_load_interp_elf` calls initramfs_data_ptr verbatim (no
          resolve_path / mount-table rewrite). A `deb /bin/true`
          invocation that picks up Debian's `/lib64/...` via a
          namespace bind needs the loader to route the interpreter
          lookup through the chan layer. Small follow-up.
    * `apt update` inside a namespace — needs (a) libdl/dlopen
      (above), (b) networking inside the namespace (today /net is
      the shared bind so this works), and (c) `/var/lib/dpkg/`
      write-through, which requires the debootstrap tree to be
      writable from inside the cpio archive (today it's read-only —
      we'd need to copy `/var/lib/dpkg/` onto a tmpfs overlay during
      distrorun bring-up).
    * `/bin/python3` from Debian — U42 makes the dynamic loader run;
      python3 additionally needs libdl (CPython imports .so
      extension modules at runtime), so it lands AFTER the libdl
      follow-up above.
    * Phase D follow-up: once `chan_attach` speaks 9P (Phase D's
      hamwd), replace the four per-subdir binds in `distrorun.ad`
      with a single `mount(srvfd, -1, "/", MREPL, "")` call that
      actually grafts the backing at /. The chain-of-binds today
      is a Phase C workaround for the inert SRV-kind mount.
- **Phase D** prerequisite — `srvfd` channels at `/srv/<name>`.
  `mount` needs `srvfd` to come from somewhere; without it the
  Phase C `mount` body has nothing to consume.
- ~~Wider errstr integration — Phase B / M16.93 only set the error
  message on `SYS_OPEN → -ENOENT` (the smallest viable
  demonstration).~~ DONE: the Phase C follow-up sweep added
  `set_current_errstr(...)` at every meaningful failure path in
  `arch/x86/kernel/syscall.ad` (SYS_OPEN / SYS_OPEN_WRITE /
  SYS_READ / SYS_WRITE / SYS_CLOSE / SYS_LSEEK / SYS_DUP /
  SYS_DUP2 / SYS_PIPE / SYS_KILL / SYS_CHDIR / SYS_GETCWD /
  SYS_UNLINK / SYS_LISTDIR / SYS_EXECVE / SYS_SPAWN / SYS_CLONE /
  SYS_WAITPID / SYS_INIT_MODULE / SYS_DELETE_MODULE), the rfork
  path (`sys/src/9/port/sysproc.ad`), and the realistic-hit subset
  of Linux ABI failures in `linux_abi/u_syscalls.ad` (open / pipe /
  dup2 / chdir / getcwd / unlink / kill / clock_gettime /
  unknown-syscall fallthrough). `sysfile.ad` / `syschan.ad` /
  `sysnote.ad` were already covered by their M16.101 / M16.107 /
  M16.109 bodies. Test fixture +
  `scripts/test_errstr_coverage.sh` assert 10 distinct subjects
  end-to-end. Follow-ups:
  - errstr at the per-backend layers (`fs/ext4.ad` / `fs/fat.ad` /
    `kernel/block/blk.ad`): right now those return negative values
    that bubble up through vfs.ad and the syscall site supplies a
    generic message. Backend-specific strings ("ext4: short read",
    "fat: cluster chain corrupt", ...) would surface root cause.
  - User-mode `perror`-style helper in `user/runtime.S`: a thin
    wrapper that calls `sys_errstr` + `sys_write` so user binaries
    can `perror("open")` -> `"open: file does not exist\n"`.
- **Next /dev/\* device files** — M16.94 landed `/dev/cons`; M16.95
  landed `/dev/time` + `/dev/pid` + `/dev/random` under
  `sys/src/9/port/devtime.ad`, `devpid.ad`, `devrandom.ad` with
  `FD_TIME_MARK` / `FD_PID_MARK` / `FD_RANDOM_MARK` plumbing in
  `fs/vfs.ad`. Remaining follow-ups in the same cdev shape (one
  file per /dev path, stateless `FD_*_MARK` dispatch in
  vfs_read/vfs_write, no per-fd kmalloc):
  - ~~`/dev/time` (r) — shipped in M16.95.~~
  - ~~`/dev/pid` (r) — shipped in M16.95.~~
  - ~~`/dev/random` (r) — xorshift64 placeholder shipped in M16.95;
    upgraded in M16.96 to ChaCha20 (RFC 8439) keyed off CPUID-
    detected RDSEED (preferred) / RDRAND (fallback) / get_jiffies
    (last resort), with a 4 KiB rekey epoch. Block function
    verified against the RFC 8439 §2.3.2 test vector;
    distribution verified by `tests/test_devrandom_chacha.ad` +
    `scripts/test_devrandom_chacha.sh` (all 256 byte-buckets
    non-zero over a 4 KiB sample, max/min ratio < 5x).~~
    Follow-ups (separate commits):
      * `/dev/urandom` non-blocking variant as a distinct cdev.
        Today /dev/random is unconditionally non-blocking too —
        we serve from the keystream regardless of estimated
        entropy. The Linux-shape split only matters once a real
        entropy estimator exists.
      * `getrandom(2)` Linux ABI syscall — already lives at the
        U21 site; should be re-pointed at `devrandom_read()` so
        userland callers don't have to open /dev/random.
      * Real entropy estimator. Today we have none; reads never
        block. A simple "credit each rekey with 256 bits, drain
        N bits per output byte" accounting + a blocking variant
        for /dev/random would mirror Linux 4.x semantics.
  - ~~`/dev/win/*` (Phase D) — windowing-server cdev family.
    `/dev/win/ctl` is the entry point: writes (NEWWIN, RESIZE,
    DESTROY, FOCUS) drive hamwd's window list; reads return
    the focused window id as ASCII decimal. Subsequent
    `/dev/win/<id>/{cmd,event,kbd,mouse,data}` files follow
    once hamwd has a real daemon process. Blocked on
    `hamwd` skeleton (separate userspace daemon, lives under
    `user/hamwd.ad` — not yet a milestone).~~ Phase D skeleton
    shipped — `user/hamwd.ad` runs as a userland daemon that
    maintains a 16-slot in-process window registry, parses
    VTNext-shaped commands from stdin (or one-shot argv), and
    emits framed `ESC ] vtn ; <cmd> ; ... BEL` packets to fd 1
    for `probe` / `win_create` / `win_destroy` / `present` /
    `text` (rest of the v2 command set is incremental follow-up).
    `tests/test_hamwd_smoke.ad` exercises the canonical
    client call shape `open(/srv/hamwd) → mount(srvfd, -1,
    "/dev/win", MREPL, "") → unmount` (same M16.107 contract as
    `test_p9mount.ad`); `scripts/test_hamwd.sh` greps the printable
    mirror line `[hamwd-wire] vtn;win_create;1;"Test";800;600` in
    the serial-stdio capture to prove a framed VTNext packet hit
    the wire. Phase D follow-ups (now unblocked):
      * Real `/srv/hamwd` posting. Today hamwd reads commands from
        its own stdin; clients can't yet `open("/srv/hamwd")` and
        get back an fd that routes to hamwd. Needs a kernel-side
        `/srv/` tmpfs-like surface (post-and-open semantics) plus
        a 9P client inside `sys/src/9/port/chan.ad`'s
        `chan_resolve_prefix` so `mount(srvfd, ...)` actually
        round-trips Tversion/Tattach/Twalk over the stored srvfd.
        That's the M16.107 deferred work the skeleton documents
        as GAP in `user/hamwd.ad`'s header.
      * Full window lifecycle: `win_place` / `win_resize` /
        `win_show` / `win_hide` / `win_zorder` / `win_raise` /
        `win_lower` / `win_cursor` / `win_title`. Wire-frame
        helpers in `hamwd.ad` generalise — each command is a
        parse-arm + a fixed number of `emit_param_*` calls. Pinned
        wire format in `docs/vtnext-v2.md` "Window lifecycle" and
        "Drawing".
      * Full drawing primitives: `rect`, `rect_outline`, `line`,
        `circle`, `clear`. Same shape as the existing `text` emit.
      * Reverse-channel parser. Demux `ESC [ V <kind> ; ...` lines
        from the renderer back into per-window event streams
        (eventual `/dev/win/<wid>/events`). Wire format pinned by
        `docs/vtnext-v2.md` "Renderer → Server events".
      * Second-client support. Today each `/bin/hamwd` invocation
        is a fresh process; the registry doesn't persist between
        calls. A real daemon survives across client requests —
        lands once `/srv/hamwd` posting exists (the daemon
        instance is what posts the srv channel).
      * Auto-launch from `/etc/rc`. Run `hamwd &` at boot so it's
        already up when the first GUI client invokes its mount
        sequence. Needs the persistent-daemon shape above.
      * Real renderer handshake. `hamwd` emits `probe` at startup
        but no renderer is wired to `qemu -serial stdio`; cap-line
        parse + V2/V1 fallback land once a pygame renderer (or a
        local-framebuffer renderer process per Phase H) attaches.
  - Migrate `SYS_PUTC` / `SYS_GET_JIFFIES` / `SYS_GETPID` callers
    to the corresponding `/dev/*` reads now that the fan-out has
    landed. Tracked separately so the migration row in
    `docs/native-api.md` can be ticked off per-syscall.
  - ~~System-introspection cdevs `/dev/cpuinfo` + `/dev/meminfo`
    shipped — Plan 9-shape source-of-truth for "what CPU am I on,
    how much RAM is live". `sys/src/9/port/devcpuinfo.ad` reads
    CPUID leaves 0/1/7:0/0x80000002..4 + `get_cpus_online()`;
    `sys/src/9/port/devmeminfo.ad` reads memblock + page_alloc
    accessors and emits Linux-shape kB lines so the eventual
    Layer-2 `/proc/{cpuinfo,meminfo}` translation is a near-direct
    byte copy. Follow-ups (separate commits):~~
      * ~~`/dev/uptime` — ASCII decimal seconds-since-boot (+
        idle-seconds once we have an idle accounting field).~~
        M16.132 shipped: `<secs>.<CC> <idle>.<CC>\n` from
        `get_jiffies()` (HZ=100). Idle column is "0.00" pending
        per-task idle accounting on TaskStruct — follow-up: add
        an `idle_jiffies` field that's bumped from the scheduler's
        idle path so the second column tracks real idle time.
      * ~~`/dev/loadavg` — Linux-shape "1.00 1.00 1.00 1/N pid".
        Needs a moving-average runqueue depth counter in
        `kernel/sched/core.ad` first.~~ M16.132 shipped: emits
        instantaneous RUNNING+READY count three times (NOT an
        EWMA). Real EWMA wants a per-tick sampler in
        `arch/x86/kernel/time.ad::timer_interrupt` that snapshots
        the runqueue depth every HZ ticks and folds into three
        decay-rated accumulators (1884 / 2014 / 2037 — see
        Linux's `kernel/sched/loadavg.c`). Idle-accounting
        prerequisite shared with `/dev/uptime` above.
      * ~~`/dev/stat` — aggregate "cpu / intr / ctxt / btime /
        processes" snapshot (mirror of `/proc/stat`). Reuses the
        cpuinfo CPUID helpers + a new IRQ-count accessor in
        `arch/x86/kernel/irq.ad`.~~ M16.135 shipped, alongside
        `/dev/mounts` and `/dev/diskstats`. `/dev/stat` columns
        are placeholders (all jiffies bucketed into the "user"
        column; intr/ctxt zeros; btime from `rtc_boot_epoch_get`;
        processes from `current_task_pid`) — see
        `sys/src/9/port/devstat.ad` header CAVEAT. Real per-state
        accounting wants TaskStruct rtime/stime fields and a
        per-IRQ counter in `arch/x86/kernel/irq.ad`.
        `/dev/mounts` walks chan.ad's mnttab + a synthetic
        `rootfs / cpio ro 0 0` root row; `/dev/diskstats` walks
        `blockdev_table` and emits the 14-column Linux shape with
        zero counters (placeholder until BlockDevice grows
        rd_ios / wr_ios fields and the read/write paths bump
        them). Follow-up: Layer-2 `/proc/{stat,mounts,diskstats}`
        translation in `linux_abi/u_syscalls.ad` (the M16.134
        pattern — add three entries to `_u_translate_proc_to_dev`
        so Linux ELFs reading `/proc/stat` see the same bytes
        `/dev/stat` emits).
      * ~~`/dev/version` + `/dev/hostname` — identity-introspection
        cdev pair. `/dev/version` emits the release string
        ("hamnix/0.1 (M16.132+)\n", stateless); `/dev/hostname`
        is the first READ+WRITE cdev in the family — writes
        update a kernel-RAM hostname buffer that subsequent reads
        observe.~~ M16.133 shipped. Follow-ups (separate commits):
          * Persist hostname writes back to `/etc/hostname`.
            Blocked on writable initramfs root — the cpio is
            read-only baked-in today, so the only write-back
            target is ext4 (`/ext/...`), which isn't where the
            canonical hostname lives. Once a real writable rootfs
            is mounted at `/`, devhostname_write should also
            update the file so the value survives reboot.
          * `/dev/machine_id` — 128-bit boot-stable identifier
            (mirror of `/etc/machine-id` / systemd-machine-id-setup).
            Derive from a RDSEED-keyed hash at first boot, persist
            once the writable rootfs prerequisite lands.
          * `/dev/sysname` aggregator — single-blob equivalent of
            Linux's `/proc/sys/kernel/{ostype,osrelease,version}`
            concatenation; useful for `uname(1)` callers that want
            one read instead of three opens.
      * ~~Layer-2 `/proc/cpuinfo` + `/proc/meminfo` translators
        that consume the same bytes via `linux_abi/`.~~ M16.134
        shipped — `linux_abi/u_syscalls.ad`'s `_u_open` /
        `_u_openat` rewrite `/proc/<name>` to `/dev/<name>` in
        place before `vfs_open` for all six native cdev names
        (cpuinfo, meminfo, uptime, loadavg, version, hostname).
        Linux ELFs reading `/proc/cpuinfo` now see the exact bytes
        `/dev/cpuinfo` emits; the native rootfs deliberately has
        no `/proc/<name>` entries (Plan 9 keeps system
        introspection under `/dev/`). Native Adder callers doing
        `sys_open("/proc/cpuinfo")` still flow through fs/procfs.ad's
        legacy renderer (or get -ENOENT once that's retired) —
        the translation lives entirely in Layer 2 per
        docs/architecture.md. Follow-ups (separate commits):
          * Per-pid `/proc/<pid>/*` translation. devproc.ad
            already serves `/proc/<pid>/{cwd,status}` natively;
            the Layer-2 mapping needs to take the Linux caller's
            `/proc/<pid>/<leaf>` and verify the leaf maps to a
            native devproc surface (vs. failing fast on unknown
            leaves like `mounts` or `maps` that don't exist yet).
          * `/proc/self/*` — translate to the caller's current
            pid first, then fall through to the per-pid path.
          * `/proc/{stat,mounts,diskstats}` — M16.135 shipped
            the three Plan 9 source-of-truth cdevs. Layer-2
            translation is now the small follow-up: extend
            `_u_translate_proc_to_dev` in
            `linux_abi/u_syscalls.ad` with three more entries
            mapping `/proc/stat` -> `/dev/stat`,
            `/proc/mounts` -> `/dev/mounts`, and
            `/proc/diskstats` -> `/dev/diskstats`. After that
            row, Linux monitoring tools (top, ps, df, iostat,
            mount, vmstat) all see the same bytes the native
            surface knows. Per-state CPU accounting + per-IRQ
            counts are deeper follow-ups (TaskStruct rtime/stime
            + `arch/x86/kernel/irq.ad` per-IRQ counter); the
            cdev/translation pair stays valid through that
            upgrade — only the column values change.
          * `/proc/net/*`, `/proc/cmdline` — each is its own
            follow-up, gated on its own native cdev landing
            first (the architecture rule: Layer 1 grows the
            surface, Layer 2 translates).
      * Per-cache slab walker accessor in `mm/slab.ad` so
        devmeminfo's `KmallocLive` line can show real
        `sum(nr_inuse * object_size)` instead of the in-use-page
        proxy it uses today.

## Kernel / L-track

- `MAX_EXPORTS=512` ceiling — bump again when we cross ~450 used.
- nf_conntrack core (~155 UND) — blocking conntrack helpers.
- `8021q.ko` (~118 UND, VLAN).
- `libphy.ko` (~153 UND, Ethernet PHY).
- usbcore + xhci_hcd — real-hardware drivers.

## Networking

- ~~Bare-metal virtio-net PCI driver — shipped in M16.88. RX
  delivers real frames to `eth_rx()` via SLIRP-gateway ARP
  round-trip.~~
- ~~IOAPIC programming + real virtio-net IRQ handler — shipped in
  M16.112. `arch/x86/kernel/apic.ad` grew `ioapic_redirect(pin,
  vector, lapic_id)` + lazy `_ioapic_init_once()`;
  `arch/x86/kernel/irq.ad` grew a 256-slot `irq_handlers[]` table
  with `register_irq_handler(vec, fn)` and per-vector dispatch in
  `do_irq` that calls `lapic_send_eoi()` exactly once after the
  handler returns. `drivers/net/virtio_net.ad` reads PCI
  INTERRUPT_PIN / INTERRUPT_LINE, programs the IOAPIC redirection
  entry for that pin to deliver CPU vector 0x40 to LAPIC id 0, and
  registers `virtio_net_irq_handler` (reads VIRTIO_PCI_ISR to ack,
  drains RX ring). `virtio_net_poll()` stays as the safety net for
  the pre-sti smoke-test window. See `scripts/test_net_irq.sh`.~~
- IOAPIC IRQ wiring follow-ups (one driver per row, all copy the
  M16.112 virtio-net template):
  - virtio-blk INTx — same 0x40-band claim shape, vectors 0x41+.
  - AHCI INTx — uses one IRQ per HBA port; needs per-port pin
    discovery via the AHCI capabilities + interrupt-status reg.
  - NVMe MSI-X — replace polled CQ phase-bit drain with vector
    table programming; needs MSI-X capability discovery (PCI
    capability ID 0x11) which is the bigger lift mentioned below.
  - e1000e INTx — `[e1000e]` driver already has the polled RX
    drain helper; add ICR (Interrupt Cause Read) ack in the handler.
  - r8169 INTx — same shape as e1000e; ack via IMR/ISR pair.
  - PS/2 keyboard IRQ 1 — IOAPIC pin 1, edge-triggered active-high
    (not the PCI level-low default). Needs `ioapic_redirect` to
    learn a flags arg or a sibling `ioapic_redirect_isa` helper.
- MSI-X for virtio-net — INTx is the M16.112 baseline; MSI-X is
  better (per-queue vectors, no level-line sharing). Needs PCI
  capability walking (cap ID 0x11), MSI-X table mapping (BAR-relative),
  and per-vector LAPIC programming. Bigger lift but eliminates the
  shared-INTx coordination headache for multi-queue devices.
- Multi-IOAPIC systems — M16.112 hard-codes a single IOAPIC at
  0xFEC00000. Large servers and NUMA boxes have one IOAPIC per
  socket; the MADT (already parsed by `drivers/acpi/acpi.ad`)
  carries the address + GSI base of each. Make `ioapic_redirect`
  consult the MADT-cached IOAPIC list and pick the one whose GSI
  range covers the requested pin.
- ~~Fill in `eth_rx()` body — shipped in M16.90. Header length
  check, ethertype byte-swap, dispatch to `arp_rx`/`ip_rx`,
  drop with diagnostic on unknown type.~~
- ~~ARP responder + cache — shipped in M16.90. RX path learns
  (sender_ip, sender_mac) on both REQUEST and REPLY into an
  8-entry cache; responder builds a reply frame when the target
  protocol address matches our configured IP.~~
- ~~ARP TX via virtio-net — shipped in M16.96. `eth_tx()` now wires
  through to `virtio_net_tx()`; ARP replies actually reach the wire.~~
- ~~IPv4 datagram path beyond the `eth_rx -> ip_rx` stub — shipped
  in M16.96. Header + checksum validation, dispatch by `.protocol`
  (1=ICMP / 17=UDP).~~
- ~~ICMP echo (ping reply) — shipped in M16.97. Two-way IPv4 verified
  end-to-end against the SLIRP gateway: `[icmp] echo request -> 10.0.2.2`
  followed by `[icmp] echo reply from 10.0.2.2`. See
  `scripts/test_net_icmp.sh`.~~
- ~~DHCP client — shipped in M16.96. Four-way DISCOVER/OFFER/REQUEST/ACK
  against SLIRP, captures `10.0.2.15` + gateway, mirrors into IP layer
  + ARP responder. See `scripts/test_net_dhcp.sh`.~~
- ICMP error message types — destination unreachable (type 3, sent
  when we can't deliver), time exceeded (type 11, sent when TTL
  hits 0 on a forward path we don't yet have), redirect (type 5).
  None are required for echo, but real peers expect them when
  routes break.
- ~~DNS resolver — shipped in M16.99. UDP/53 A-record query / answer
  codec in `drivers/net/dns.ad`, `dns_lookup(hostname, out_ip,
  timeout)` synchronous entry point, 4-slot in-flight table, ARP-prime
  for the DNS server before the first query. Tested against QEMU
  SLIRP's DNS forwarder (10.0.2.3): `[dns] resolved example.com ->
  172.66.147.243`. See `scripts/test_dns.sh`.~~
- DNS follow-ups:
  - ~~Per-process result cache (TTL-aware) so `apt` doesn't re-query
    `deb.debian.org` for every URL in its index. The single-query
    path here clears the slot on completion; a real cache would
    park the answer keyed by lowercased QNAME until the TTL expires.~~
    Shipped as a kernel-wide 16-entry cache (not per-process —
    nothing else needs the isolation yet) in `drivers/net/dns.ad`:
    `_dns_cache_lookup` short-circuits `dns_lookup` before any
    UDP/53 round-trip; `dns_rx` stores positive answers with the
    wire TTL clamped to [60 s, 86400 s] and negative answers
    (RCODE=3 NXDOMAIN) at 60 s. Eviction is "earliest expiry
    wins". See `scripts/test_net_dns_cache.sh`.
  - PTR records (reverse lookup) — type 12. Used by `getnameinfo`
    and reverse-DNS logging in apt-like clients. Same wire codec
    as A, just a different QTYPE and an in-addr.arpa-formatted
    QNAME on the request side.
  - MX records (mail exchange) — type 15. Required before an
    in-kernel SMTP client could route outbound mail. RDATA is
    (preference uint16, exchange-domain-name), the latter
    DNS-compression-pointer-encoded like every other name.
  - SRV records (service location) — type 33. Used by Kerberos,
    XMPP, modern HTTP/3 alt-svc lookups, and several Debian
    repository-mirror autoselection schemes. RDATA is (priority,
    weight, port, target-name).
  - Multiple A records — DNS answers often include 3-8 A-records
    for load-balancing. We take the first and ignore the rest; a
    fuller implementation would return all of them and let the
    caller round-robin.
  - AAAA (IPv6) records — IPv6 is out of scope until the IP layer
    gets a v6 header, but the DNS codec is type-agnostic and could
    be extended with TYPE=28 trivially.
  - TCP/53 fallback for responses larger than 512 bytes (the UDP
    cap from RFC 1035). Apt may hit this for large MX-style
    answers; not a blocker for A-only queries.
  - Generic ARP-request helper in `drivers/net/virtio_net.ad`
    or `arp.ad` (today `_dns_prime_arp` duplicates the
    `virtio_net_send_arp_probe` shape locally). When a second
    consumer needs unicast ARP, factor this out.
- ~~TCP three-way handshake — shipped in M16.102. Minimal active-open
  client in `drivers/net/tcp.ad` with `tcp_connect` / `tcp_send` /
  `tcp_recv` / `tcp_close` and an 8-entry static TCB table. SLIRP
  `guestfwd` echo end-to-end via `[tcp] connected slot=0` →
  `[tcp] sent 3 bytes` → `[tcp] received 3 bytes: 'hi\n'` →
  `[tcp] closed slot=0`. See `scripts/test_net_tcp.sh`.~~
- TCP follow-ups:
  - Retransmission timer — today the single-shot send returns
    success even if the peer never ACKs (we run on SLIRP which
    doesn't drop packets, so retransmission only matters off the
    virtual wire). Add an RTO based on a running RTT estimate plus
    exponential backoff per RFC 6298.
  - Congestion control — initial cwnd of one segment is fine for
    SLIRP; for the real internet we need at least the slow-start /
    congestion-avoidance pair from RFC 5681 and probably NewReno
    fast retransmit.
  - ~~Passive open (LISTEN + SYN_RCVD) — shipped in M16.124.
    `tcp_listen(local_port)` allocates a TCB in LISTEN state;
    `tcp_accept(listener_slot, timeout)` polls for a connection that
    completed the three-way handshake on the listener's port. `tcp_rx`
    falls back to a listener lookup when the 4-tuple doesn't match an
    existing TCB; on SYN it allocates a fresh slot in SYN_RCVD, picks
    an ISN (xorshift64 from `get_jiffies`), emits SYN-ACK, and waits
    for the client's ACK to transition that slot to ESTABLISHED. With
    the 8-entry TCB table, a single listener + 7 simultaneous accepted
    connections is the practical cap. See `scripts/test_net_tcp_listen.sh`
    (uses `hostfwd=tcp::5555-:80` + a host-side `nc localhost 5555`
    to drive the inbound SYN).~~
  - TCP passive-open follow-ups:
    - Multi-listener support — today a single LISTEN slot per port is
      assumed and there's no per-listener accept queue (incoming SYNs
      allocate one new TCB at a time, with the LISTEN slot staying
      LISTEN). For a real concurrent server with hundreds of
      simultaneous accepts we need either an explicit accept queue
      per listener or a wider TCB table.
    - Socket-API binding — `tcp_listen` / `tcp_accept` are callable
      only from in-kernel code paths. The Plan 9 `/net/tcp/clone`
      shape (announce/listen/accept files) lands in Phase F.
    - sshd prerequisite list now reads: (1) passive-open ready
      (M16.124); (2) crypto primitives — at minimum SHA-256, Curve25519,
      ChaCha20-Poly1305 (or AES-GCM); (3) a real PRNG seeded from
      something better than `get_jiffies()` xorshift64; (4) RSA / Ed25519
      host-key parser + verifier; (5) a /etc/passwd-shaped authentication
      table or PAM-equivalent stub. Same chain unblocks an in-kernel
      telnet server (skip steps 2-4).
  - Window scaling + SACK + timestamps — the standard performance
    options. Not blockers for `apt` (HTTP/1.1 over short
    single-segment requests), but real-world latency suffers without.
  - Multi-segment reassembly — `tcp_rx` today drops out-of-order
    segments and overwrites the per-slot single-segment rx buffer
    on each delivery; HTTP responses bigger than the receive window
    will lose data. Track gaps explicitly and reorder before
    handing up.
  - ~~HTTP/1.1 client — shipped in M16.106 (`drivers/net/http.ad`).
    Single `http_get(url, out_buf, out_max, status_out)` entry point
    builds `GET <path> HTTP/1.1\r\nHost: <host>\r\nUser-Agent:
    Hamnix-kernel/0.1\r\nAccept: */*\r\nConnection: close\r\n\r\n`,
    drains the response through TCP, parses status line + headers
    (case-insensitive Content-Length), returns body bytes into the
    caller's buffer. Smoke test fetches `http://example.com/` and
    confirms status=200 + `<!doctype html>` in the body. See
    `scripts/test_net_http.sh`. Closes the full
    `DHCP -> ARP -> IP -> UDP -> DNS -> TCP -> HTTP` chain.~~
  - Socket(2) API — Plan 9 `/net/tcp/clone` shape lands in Phase F.
    Today TCP is callable only from in-kernel code paths.
- HTTP/1.1 follow-ups:
  - Chunked transfer encoding (`Transfer-Encoding: chunked`) — the
    M16.106 client reads body bytes verbatim, so a chunked response
    leaks the hex-length frames into the buffer. Cloudflare-fronted
    `example.com` exposes this — body starts `210\r\n<!doctype...`.
    Real fix: detect the header, then in the body loop strip each
    `<hexlen>\r\n` prefix + the trailing `\r\n` per chunk until the
    `0\r\n\r\n` terminator.
  - ~~HTTPS / TLS skeleton — M16.x lands `drivers/net/tls.ad` with a
    TLS 1.3 ClientHello + ServerHello + handshake-key-schedule
    sequence on top of `tcp_send`/`tcp_recv`. Single cipher suite
    (TLS_CHACHA20_POLY1305_SHA256), single group (X25519), AEAD via
    ChaCha20-Poly1305 (RFC 8439), key derivation via HKDF-SHA-256
    (RFC 5869), X25519 scalar multiplication via the standard
    Montgomery ladder over five 51-bit limbs (RFC 7748). The
    `https_get(url, ...)` wrapper in `drivers/net/http.ad` parses
    `https://<host>[:<port>]<path>`, calls `tcp_connect`, drives
    `tls_handshake`, and tears down. Reaches the "encrypted
    ServerHello parsed + AEAD round-trip on first server flight
    record" milestone — confirms the handshake HKDF schedule is
    correct end-to-end.~~ Follow-ups carved out below.
  - HTTPS / TLS — server cert validation. The current `tls_handshake`
    parses Certificate + CertificateVerify for the transcript hash
    but DOES NOT validate the X.509 chain. Documented in the
    `drivers/net/tls.ad` header as "TLS-Unsafe; transport encryption
    only, no authentication". Needs: DER ASN.1 parser
    (SubjectPublicKeyInfo, validity, SAN), RSA-PSS + ECDSA P-256
    signature verifiers, baked-in CA trust store (ca-certificates
    equivalent), SAN/CN hostname matcher, path building. ~2000-line
    follow-up — gates real `apt update` over HTTPS.
  - HTTPS / TLS — finish post-handshake flow. Today `tls_handshake`
    returns after the AEAD round-trip on the FIRST encrypted server
    record (EncryptedExtensions). The follow-up consumes Certificate
    + CertificateVerify + Finished, sends the client Finished,
    derives application traffic keys, and wires `tls_send` /
    `tls_recv` to a full encrypted GET + response loop inside
    `https_get`. Once that lands `[https] GET host=... body=N bytes`
    shows up and the kernel can fetch
    `https://deb.debian.org/debian/dists/stable/InRelease` end-to-end.
  - HTTPS / TLS — AES-128-GCM cipher suite for AES-NI hosts. The
    current code only implements TLS_CHACHA20_POLY1305_SHA256 —
    fine because ChaCha20 is shared with the M16.129 CSPRNG path
    and works on every CPU. Adding TLS_AES_128_GCM_SHA256 lets the
    kernel match the cipher most CDNs prefer (faster on hardware
    with AES-NI + CLMUL).
  - HTTPS / TLS — TLS 1.2 fallback for old servers. TLS 1.3 is the
    only protocol we negotiate today. A handful of mirrors still
    sit behind ancient TLS 1.2-only stacks; a single-codepath
    fallback (ECDHE-RSA-AES128-GCM) would unbreak those.
  - 3xx redirect handling — `http_get` surfaces the status code
    through `status_out` so the caller can re-issue against the
    `Location:` header value; a higher-level `http_get_follow()`
    wrapper that resolves the header + caps redirect depth would
    let `apt update` follow mirror redirects automatically.
  - HTTP keep-alive (`Connection: keep-alive`) — today every GET
    opens a fresh TCP slot, runs the full SYN/SYN-ACK/ACK
    handshake, fires the request, drains, and tears down. apt
    fetches dozens of small files per repo; keep-alive (single TCP
    conn, multiple GETs back-to-back) would cut handshake overhead
    significantly.
  - Header parser that handles header continuation lines (folded
    headers per RFC 9112 §5.2) — uncommon in practice but the
    spec allows it.
  - Header block spanning multiple `tcp_recv` chunks — today the
    parser punts ("headers > 4 KiB scratch") if the `\r\n\r\n`
    boundary doesn't fall inside the first segment. Apt-shape
    servers always fit headers in well under 4 KiB so this hasn't
    fired in practice, but a real fix accumulates header bytes
    across reads.
- ~~Native Intel e1000e Gigabit NIC driver — shipped in M16.103.
  PCI vendor 0x8086 + class 0x02/0x00/0x00 match with a device-ID
  whitelist (82574L 0x10D3, 82583V 0x150C, 82573L 0x10F5, 82579LM
  0x1502, I217-LM 0x153A, I218-LM 0x15A2, I219-LM 0x156F + v3
  0x15B7). MMIO BAR0 + MEM/master enable; CTRL.SLU+ASDE for PHY
  bring-up; MAC read from RAL[0]/RAH[0]; 256-descriptor RX ring
  with 2 KiB buffers; RCTL.EN/BAM/BSIZE=2K/SECRC programmed.
  `e1000e_poll()` drains via descriptor.status.DD and re-arms RDT.
  Probe + IDENTIFY + RECEIVE only — no TX, no integration with
  the ARP/IP/UDP/ICMP/DHCP/DNS/TCP stack. With virtio-net + e1000e
  the install ISO now reaches the wire on every Dell PowerEdge /
  HP ProLiant / Supermicro motherboard / ThinkPad / Latitude /
  EliteBook from the last ~15 years. See `scripts/test_net_e1000e.sh`.~~
- e1000e follow-ups:
  - Single-segment TX (`e1000e_tx_one`) — enough to send an ARP
    probe and observe an inbound reply land in the RX ring, the
    same shape virtio_net M16.88 uses for its self-test. Once TX
    exists, the e1000e test can add an `[e1000e] RX packet`
    assertion.
  - MSI-X interrupt routing (after IOAPIC programming lands) —
    today `e1000e_poll` drains the RX ring on demand from the
    init spin loop, same shape as virtio_net_poll.
  - EEPROM-walk (`EERD`) for real hardware without a pre-loaded
    RAL/RAH — QEMU always loads MAC from `-device e1000e,mac=...`,
    but some real cards leave RAH.AV cleared until the driver
    issues an EERD-paced 16-bit-at-a-time read.
- ~~Realtek r8169-family NIC driver — shipped in M16.105. Probes
  vendor 0x10EC + class 0x02/0x00 with device-ID whitelist {0x8139,
  0x8136, 0x8161, 0x8168, 0x8169}; the RTL8139 path is fully
  implemented (PIO BAR0, software reset, MAC read from IDR0..IDR5,
  8 KiB + slack circular RX buffer, RCR enable, polled drain
  through `eth_rx`). Together with M16.88 virtio-net + M16.103
  e1000e covers essentially every consumer x86 box from ~2009
  onwards. See `scripts/test_net_r8169.sh`.~~
- r8169 follow-ups:
  - Gigabit family bring-up (RTL8168 / RTL8169 / RTL8161) — MMIO
    BAR2 read, 16-descriptor RX + TX rings, descriptor-OWN-bit
    handshake. The driver currently logs Gigabit device IDs and
    bails out before touching the chip; the MMIO path is the
    real follow-up since most consumer motherboards from ~2010
    onwards carry RTL8168, not RTL8139.
  - Single-segment TX (`r8169_tx_one`) — enough to send an ARP
    probe and round-trip an inbound reply, matching the
    virtio-net M16.88 self-test pattern. Once TX exists, the
    r8169 test can drop its "no RX assertion" caveat.
  - Real IRQ wiring (after IOAPIC programming lands) — today
    `r8169_poll` drains the RX ring on demand from the kernel
    init spin loop, same shape as virtio_net_poll / e1000e_poll.
- Broadcom tg3 driver — covers most Dell / HP business laptops
  (BCM57xx series). After r8169 + e1000e the gap to "boots on any
  real laptop" is mostly tg3 and the Atheros AR8161 family.
- Intel igb driver — covers I210 / I350 server NICs that ship on
  most modern motherboards but aren't part of the e1000e device-ID
  whitelist (they use the igb register layout, not e1000e's).

## Userspace / U-track

- **/bin tool audit — more cwd-relative defaults.** The shell-UX
  bug-fix wave covered `ls`/`find` (commit 51a6974) and `du`
  (sys_chdir-validation commit, M16.115). Other tools that hardcode
  a default path when invoked with no args should also be swept:
  candidates left to inspect across rebuilds — anything that does
  `argc < 2: ... = "/something"`. Today the obvious offenders are
  fixed; the audit is bounded by "no tool defaults to `/mnt`" and
  "every tool with a 'current dir' intent calls sys_getcwd". Adding
  new tools as Phase G lands should follow ls.ad / find.ad / du.ad
  as templates.
- **hamsh `cd` error message reports wrong cause.** The cd builtin
  prints `cd: path too long\n` on ANY sys_chdir failure, even when
  the kernel errstr is "no such directory" (-ENOENT) or "not a
  directory" (-ENOTDIR). The fix is small — read sys_errstr after a
  failed chdir and print that — but lives inside hamsh.ad, which is
  currently off-limits per the M16.x VMA/parallel-agent fence.
  Surfaced as the user-reported "path too long" symptom in the
  `ls`/`vfs_listdir` cpio-routing bug investigation (the actual ls
  bug was different — vfs_listdir falling through to -EINVAL — but
  the misleading cd error was what got blamed).
- **hamsh small-bug audit.** Surfaced during the M16.x ls/listdir
  fix investigation; left unfixed to keep that commit narrowly
  scoped:
    * **No Tab completion.** Line editor reads one char at a time
      and never intercepts TAB. Low-stakes but every new user hits
      this within seconds.
    * **Empty Enter behaviour not audited.** Pressing Enter on a
      blank prompt should re-print the prompt and re-read; verify
      that path doesn't accidentally tokenize argv[0]="" and spawn
      an empty PATH lookup.
    * **No history / arrow-key navigation.** Up/Down/Left/Right
      escape sequences appear inline as raw bytes. A real readline
      replacement (or even a minimal ring buffer) is a separate
      project; note it here so future shell-UX work doesn't claim
      hamsh "supports a normal shell experience".
    * **Argv tokenization corner-case audit.** `tokenize` in
      hamsh.ad uses double-quote-only quoting; single quotes,
      backslash escapes, and `$VAR` interpolation inside `"…"` all
      need a pass once Tab-completion or history land.
- Real vDSO blob (mapped page advertised via `AT_SYSINFO_EHDR`),
  replacing the U11-era kernel-side `_lookup_dynsym` hack we
  retired in U20.
- `futex` (202) — real wait/wake table. Today returns -ENOSYS;
  glibc tolerates but multi-threaded musl will need it.
- `clone` / `clone3` (56 / 435) — pthread bring-up.
- Per-task heap state — `linux_brk` is a single global today;
  multi-process Linux binaries will collide.
- ~~**U39 follow-up: swap MicroPython for full CPython.**~~ DONE
  at U41. Shipped: `tests/u-binary/u_cpython` + Makefile + HOWTO +
  `scripts/test_u41_cpython.sh`. CPython 3.11.10 builds as a
  `-static` (not `-static-pie`) ~7.9 MB stripped ELF via
  `make -C tests/u-binary/src/cpython install`. The binary
  exec's through the U-track ELF loader, runs through
  pycore_interp_init / _frozen_importlib / site.py init, reaches
  init_fs_encoding, finds frozen `encodings.utf_8`, and prints
  "U41OK-5 hello from CPython on Hamnix" via write(1, ...). History:
  ~~First blocker (pycore_interp_init MemoryError) fixed at commit
  1d543f1 (brk reserve / mmap slots bumped).~~
  ~~Second blocker (init_fs_encoding "No module named 'encodings'")
  first patched by the HAMNIX_EMBED_PYLIB hook in
  scripts/build_initramfs.py at commit 86b6b09, but the embedded
  Lib/ tree overflowed fs/cpio.ad's NR_FILES=192 cap.~~ Final fix
  this commit: rebuilt CPython with a widened FROZEN list in
  Tools/scripts/freeze_modules.py (`<encodings.*>`, `<collections.*>`,
  `enum`, `keyword`, `re`, `functools`, `_weakrefset`, `types`,
  `inspect`, `warnings`, `traceback`, `linecache`, `tokenize`,
  `contextlib`, `heapq`, `weakref`, `operator`, `copyreg`,
  `reprlib`, `token`). All bootstrap modules live in the binary's
  data segment via `_freeze_module`; no /usr/lib/python3.11/ tree
  needed. Binary 5.7→7.9 MB stripped (+2.2 MB for the bytecode).
- ~~**U41 follow-up: bump `NR_FILES` in `fs/cpio.ad`.**~~ Sidestepped
  by the frozen-modules build (no /usr/lib/python3.11/ tree means no
  pressure on the cpio file_table). The cap can still be bumped if
  some future workload needs more files; no longer blocks U41.
- ~~**U41 follow-up: rebuild CPython with frozen-modules.**~~ DONE
  (this commit). Pending follow-ups:
    * **Trim the frozen set if size matters.** The `<encodings.*>`
      glob pulls in ~120 .h files (~1.5 MB of bytecode). The boot
      path only touches `encodings.utf_8` + `encodings.aliases` +
      `encodings.__init__` + `encodings.ascii` + `encodings.latin_1`.
      Cutting the glob to those five would shave ~1 MB off the
      stripped binary.
    * **`--enable-optimizations` (PGO + LTO).** Would shave another
      ~5% + speed up the interpreter, but lengthens the build from
      ~5 min to ~25 min. Not enabled by default; add the flag to
      `tests/u-binary/src/cpython/Makefile` if a future agent wants
      the size + perf win.
    * **C extensions (lib-dynload/).** No dynamic loader on the
      U-track, so `_ssl`, `_hashlib`, `_socket`, `_curses` etc. are
      not loadable today. Needs a U-track equivalent of `ld.so`,
      or static linking of the C extensions into u_cpython (which
      requires a CPython build flag we don't have today).
- **U39 follow-up: fix glibc-malloc brk-grow corner case.**
  MicroPython under U39 needs `-X heapsize=64k` because a
  1 MiB heap forces glibc-malloc's main_arena onto our
  brk() path; our `_u_unimpl_brk` can only grow contiguously
  when consecutive kmalloc(LINUX_BRK_GROW) chunks happen to
  land adjacent, which for million-byte requests they
  don't, malloc prints "break adjusted to free malloc
  space" + tries to recover via mmap, then aborts inside
  arena bookkeeping. Two options: (a) back brk with a real
  per-task anon-mmap region (pre-reserved virtual range,
  page-fault populated); (b) detect "grow request larger
  than one chunk" and pre-allocate the whole tail in one
  kmalloc call so contiguity is guaranteed up to MAX_ORDER
  (4 MiB).
- **U40 follow-up: musl-busybox exit-group / getdents64
  surface.** `tests/u-binary/u_busybox_musl` lands at M16.X
  (see `scripts/test_u40_musl_busybox.sh`). The banner +
  `busybox echo` round-trip cleanly through hamsh, but a
  follow-up applet that walks a directory (`busybox ls /etc`)
  trips a #GP at vector 0x0d inside the libc exit-cleanup
  / getdents64 path. The first echo's tail-of-process
  teardown is suspect too — the test runs to PASS on the
  banner + echo markers and explicitly tolerates the TRAP.
  Fix candidates: (a) trace musl's `exit_group` -> `set_robust_list`
  -> `rseq` teardown and stub the missing syscall numbers
  in `linux_abi/u_syscalls.ad`; (b) implement `getdents64`
  (217) with a real body so `ls` works (today it returns
  -ENOSYS, which musl handles, but the follow-on cleanup
  apparently doesn't survive). See
  `tests/u-binary/src/musl_busybox/HOWTO.md` for the
  `make -C tests/u-binary/src/musl_busybox install`
  rebuild path.
- **U40 follow-up: more musl-built userland.** CPython 3.11
  static via musl (size sweet spot between MicroPython at
  900 KB and full CPython at 25 MB), apt-static via musl
  (the "install Debian packages" goal), then more applet
  coverage in the busybox `.config` (TLS / awk / sed are
  off today to keep the binary lean; turn them on once we
  have a real applet test that needs them).

## Storage

- ~~Native AHCI driver — shipped in M16.89. PCI class probe, ABAR
  map, port scan, polled IDENTIFY + READ DMA EXT of LBA 0 (MBR
  signature check). Unlocks SATA disks on consumer hardware.~~
- ~~AHCI write path (WRITE DMA EXT, 0x35). Symmetrical to the M16.89
  read path; needs port stop/start churn audited under repeat I/O.~~
  Shipped in M16.118: `ahci_write_sectors` + `_do_write_lba` mirror
  the READ path with W=1 in the command-header DW0. Boot-time
  smoke test writes a 512-byte pattern to LBA 1 and reads it back
  to verify byte-for-byte equality. See `scripts/test_ahci_write.sh`.
  Block-layer integration (register_blockdev with the AHCI port as
  priv) is the next follow-up — BlockDeviceOps.write_sectors slot
  already exists in `kernel/block/blk.ad`.
- AHCI native command queueing (NCQ) — multiple in-flight commands
  per port via READ FPDMA QUEUED / WRITE FPDMA QUEUED (0x60 / 0x61),
  driven by SACT + per-slot completion. Today every command
  serialises on slot 0.
- ~~Partition-table read (parse MBR + GPT). Shipped in M16.x as
  `drivers/block/partition.ad` + `blk_scan_partitions(slot)`. MBR
  primaries 1..4 + GPT (with protective-MBR fallback) decode against
  any device the block layer knows about; per-disk 16-slot table
  populated; one `[partition] disk=<name> idx=N lba=<start>..<end>
  type=<short>` log line per live partition. See
  `scripts/test_partition.sh` for the end-to-end virtio-blk fixture.~~
  Partition follow-ups:
    - mkpart / mklabel write path — sibling to the read side; writes
      a fresh MBR or GPT (header + array sectors + CRC32) so the
      installer can lay down partitions before the file system goes
      down on a freshly-wiped real disk.
    - `/dev/sd<a-z><N>` naming — today partitions live in a per-slot
      table; the installer needs `open("/dev/sda2")` to resolve via
      `find_blockdev("sda")` + partition index 1 to a slot range
      derived from `partition_for(slot, idx).lba_start`.
    - Extended-partition (CHS) chain — types 0x05 / 0x0F. Rare on
      modern disks but DOS-formatted USB sticks still ship with them.
    - BSD disklabel — needed for `*BSD` install-media interop.
    - Apple Partition Map (APM) — pre-GPT Mac partition format.
      Probably never blocking but cheap once the read framework
      exists.
- AHCI hot-plug / COMRESET / port reset retry — real ThinkPads
  flap SATA on resume; the driver needs to re-init a port that
  drops link.
- ~~NVMe driver — shipped in M16.92. PCI class-match (0x01/0x08/0x02),
  64-bit BAR0 map, controller reset + admin SQ/CQ + CC.EN dance,
  IDENTIFY controller + namespace, CREATE-IO-CQ/SQ, I/O READ of LBA 0
  with MBR signature check. Polled completion via CQ phase bit.~~
- ~~NVMe write path (opcode 0x01) — symmetrical to the M16.92 read path;
  PRP1 = source buffer, CDW10/11 = LBA, CDW12 = NLB-1. Should reuse
  the existing I/O queue + `_io_submit_and_wait` plumbing.~~ Shipped
  in M16.118: `nvme_write_lba` reuses `_io_submit_and_wait` over the
  existing qid=1 I/O SQ/CQ. Boot-time smoke test writes a 512-byte
  pattern to LBA 1 of namespace 1 and reads it back via the existing
  READ path to verify byte equality. See `scripts/test_nvme_write.sh`.
  Block-layer integration (register_blockdev with namespace cookie as
  priv) is the next follow-up.
- NVMe multi-queue (one SQ per CPU) — today every I/O serialises on
  qid=1. Per-CPU SQs unlock the scalability the protocol was
  designed for.
- NVMe MSI-X IRQ wiring — replace the busy-poll on CQ phase with an
  actual interrupt handler. Blocks on real IOAPIC + MSI-X bring-up.
- NVMe multi-namespace support — current driver hard-codes NSID=1.
  Real controllers carve multiple namespaces; need IDENTIFY active
  namespace list (CNS=0x02) + a per-NS state struct.
- ~~M16.118 follow-up: register AHCI + NVMe with `kernel/block/blk.ad`.~~
  Shipped in M16.119: `drivers/ata/ahci.ad` and `drivers/nvme/nvme.ad`
  now build a `BlockDeviceOps` vtable with thin `_blkop` adapter
  wrappers (block layer's `(priv, lba, count, buf)` shape onto the
  driver-level `(port|nsid, lba, nblocks, buf)` shape), then call
  `register_blockdev("sd0", ...)` / `register_blockdev("nvme0n1", ...)`
  after the M16.118 write-smoke tests have passed. Boot-time
  block-layer round-trip writes a pattern at LBA 1 through
  `blk_write_sectors(slot, ...)` and reads it back via
  `blk_read_sectors(slot, ...)`. PASS markers: `[blk] write sd0
  LBA=1 OK`, `[blk] readback sd0 matches`, and equivalents for
  `nvme0n1`. See `scripts/test_block_layer_write.sh`. Follow-ups:
    * ~~Partition-aware naming (`sd0p1`, `nvme0n1p1`) so the installer
      can `open("/dev/sd0p1")` and have the kernel map that to slot +
      LBA-base via `partition_for(slot, idx)`.~~ Shipped in M16.x:
      `kernel/block/blk.ad::blk_register_partitions(parent_slot,
      parent_name)` walks `partition_for(parent_slot, idx)` and
      registers each live slot as `<parent>pN` (1-indexed) with a
      partition-aware `BlockDeviceOps` vtable that offsets every
      read/write by the partition's `lba_start` and bounds-checks
      against `lba_end`. AHCI + NVMe call it after their own
      `register_blockdev`. The block-device name field grew from
      8 to 16 bytes to fit `nvme0n1p15`; `BLKDEV_MAX` grew from 4
      to 32 so partitions don't evict raw disks. See
      `scripts/test_partition_naming.sh` — partitions emerge as
      `blk: registered 'sd0p1' capacity=63488 sectors` etc.
      Sub-follow-ups:
        - GPT partition names beyond the first-DWORD type-GUID
          shorthand: today GPT entries register under the parent's
          type prefix (the on-disk UTF-16LE name at offset +56 of
          each GPT entry is decoded for the `[partition]` log but
          not propagated into the block-device tag).
        - Mountable Plan 9 syntax `mount /dev/sd0p1 /mnt`: today
          fs/fat.ad + fs/ext4.ad mount whichever raw disk wins the
          magic-number probe. The 9P mount(2) front-end needs a
          path-string-to-slot resolver that walks /dev → block-layer
          name.
    * Multi-port AHCI naming (`sd1`, `sd2`, ...) — today only the
      first active port wins; the rest of the PI mask is logged but
      not registered.
    * NVMe multi-namespace (`nvme0n2`, `nvme0n3`, ...) — paired with
      IDENTIFY active-namespace-list (CNS=0x02) bringup.
- ~~M16.118 follow-up: partition-table parsing for AHCI + NVMe disks.~~
  Wired in M16.x alongside partition-aware naming above: the AHCI +
  NVMe registration paths now call `blk_scan_partitions(slot)`
  followed by `blk_register_partitions(slot, "<parent>")` after
  `register_blockdev`. Test fixture is
  `scripts/test_partition_naming.sh` (sfdisk-built two-primary MBR
  on an AHCI disk).
- M16.118 follow-up: ext4 write path + bootloader-install plumbing.
  With AHCI + NVMe writes in place, `dd if=hamnix.iso of=/dev/sda`
  from inside Hamnix becomes feasible; the higher-level installer
  needs ext4-write + GRUB-stage-install + MBR-write helpers built
  on top of the new primitives.
- ~~ext4 mkfs (in-kernel format-on-partition).~~ Shipped in M16.x:
  `fs/ext4.ad::ext4_mkfs(slot, total_sectors)` lays down a single-
  group ext4 layout (4 KiB blocks, 256-byte inodes, 8192 inodes/group,
  legacy 32-byte group descriptors, EXTENTS + FILETYPE incompat flags,
  no journal) over `blk_write_sectors`. Self-test
  (`ext4_mkfs_self_test`) lazily triggers on the first VFS open of a
  /ext path — locates `sd0p1` / `nvme0n1p1`, formats it, re-mounts
  via `ext4_init`, then walks the freshly-written root dir to confirm
  `.` and `..` come back. Test fixture is `scripts/test_mkfs.sh` +
  `tests/test_mkfs.ad` (sfdisk-built MBR primary on a 64 MiB AHCI
  disk). Follow-ups:
    * Extents for huge-files mkfs — today's root inode uses extents
      already (so the existing read path mounts the FS without
      changes); an `ext4_create_extent_tree` helper would let mkfs
      lay down pre-allocated multi-extent regular files (lost+found
      etc.) at format time.
    * Multi-block-group mkfs — current code clamps `total_blocks`
      to 32768 (one group, 128 MiB). Real-hardware partitions are
      tens to hundreds of GiB; a multi-group descriptor table +
      per-group bitmap/inode-table + redundant SB copies that
      SPARSE_SUPER selects are the next step.
    * Journal (`has_journal` feature) — without a journal we run
      "ext4 without journaling" (a valid tune2fs configuration, but
      means a crash mid-write loses metadata coherence). The L-track
      jbd2 module is the natural source; lands alongside fsync().

## Input

- ~~PS/2 keyboard polish — shipped in M16.100. Extended scancodes
  (arrows, F1..F12, Home/End/Ins/Del/PgUp/PgDn), modifier-state
  tracking (Shift/Ctrl/Alt + CapsLock/NumLock), Shift+letter and
  Caps+letter via XOR fold, Shift+symbol via parallel `sc1_to_shifted`
  table, Ctrl+letter -> 0x01..0x1A (preserves the M16.42 SIGINT path).
  Boot-time `atkbd_self_test()` checks 25 expectations across 12
  scenarios. See `scripts/test_atkbd_ext.sh`.~~
- IRQ 1 wiring for PS/2 keyboard — today `atkbd_poll()` is drained
  every timer tick (100 Hz = 10 ms latency). A real IRQ 1 handler
  via the IOAPIC would zero-latency the keystroke and free the
  timer ISR from doing keyboard work. Blocks on IOAPIC PCI-style
  routing for the legacy 8042 line (vector 0x21 today is masked).
- USB HID keyboard — `usbcore` + `xhci_hcd` + `usbhid` from the
  L-track. Same FIFO sink (`kbd_rx_push`); separate driver that
  parses USB HID report descriptors and synthesises the same
  ASCII / escape-sequence bytes. Required for laptops post-2018
  that ship with no PS/2 port. Large effort — own milestone.
- International keyboard layouts (Dvorak, AZERTY, German QWERTZ,
  UK, etc.) — today `sc1_to_ascii` + `sc1_to_shifted` are hard-
  coded US-104. A `kbd_set_layout(name)` entry point plus a
  registry of named layouts would suffice; layouts live as data
  tables compiled in (no runtime loader needed).
- Dead-key / compose / IME — `Compose-' a` -> 'á', etc. Not
  needed for English-only install; standard X11-shape compose
  tables plus a 2-byte pending-deadkey state in `kbd_state`
  would cover the European-Latin set.
- ~~PS/2 mouse (the other channel on the 8042). Same controller,
  different port; needed once `hamwd` window-server lands.~~
  M16.121: `drivers/input/auxmouse.ad` brings up the i8042 second
  port (CCB IRQ12-enable + AUX-clock-enable RMW), resets the mouse
  (0xFF -> ACK + BAT 0xAA + ID 0x00), enables streaming (0xF4),
  registers IRQ 12 -> vector 0x45 via IOAPIC pin 12, and decodes
  the 3-byte protocol into a 64-event ring (`MouseEvent {dx, dy,
  buttons}`). Boot-time decoder self-test asserts 7 cases (signed
  delta extraction, button-bitmap, Y-flip for screen-down, resync,
  overflow drop). See `scripts/test_mouse.sh`. Follow-ups:
    - ~~`/dev/mouse` cdev path (mirror M16.94 /dev/cons shape;
      `mouse_rx_pop()` accessor already in place).~~ M16.130:
      `sys/src/9/port/devmouse.ad` ships the Plan 9-shape cdev.
      One read pops one event and emits ASCII
      `"<dx> <dy> <buttons>\n"`; writes return -1 (read-only).
      Empty ring returns 0 bytes (non-blocking poll semantics).
      VFS wiring uses `FD_MOUSE_MARK = 0xFFFFFFED`. See
      `scripts/test_devmouse.sh`.
    - 4-byte protocol with scroll wheel — the
      `0xF3 200, 0xF3 100, 0xF3 80` knock pattern enables it;
      decoder needs a phase-3 byte for Z + extra buttons. After
      M16.130 the wire format change also needs a fourth column
      in `/dev/mouse`'s ASCII line ("<dx> <dy> <dz> <buttons>\n").
    - `hamwd` input dispatch — Layer-3 GUI consumer that maps
      events to per-window cursor coordinates. Reads from
      `/dev/mouse` instead of reaching into auxmouse.ad directly.
    - Mouse cursor rendering in the framebuffer — depends on
      hamwd; the cdev is the input source, the cursor sprite is
      a separate Layer-3 concern.
    - Blocking read on `/dev/mouse` (wait_event on
      `mouse_ring_has`) — needs the syscall layer's wait-queue
      story finalised; today the cdev is poll-only.
    - MADT IRQ-override consumption — today we accept the default
      level-triggered active-low IOAPIC redirection; ISA IRQ 12 is
      really edge-triggered active-high and a future ACPI-driven
      override pass would program it correctly.

## Toolchain & install

- ~~Real-hardware boot (ThinkPad). FAT32 read + EXT4 r/w done;
  UEFI handover outstanding.~~ M16.70: native PE/COFF stub
  (arch/x86/boot/efi_stub.S) now boots under UEFI directly — no
  GRUB-EFI dependency. ISO still ships GRUB for BIOS.
  ~~Real-hardware boot test plan (USB-stick image, README on how to
  test).~~ Shipped as `docs/REAL_HARDWARE.md` — covers ISO build,
  USB-stick write, firmware boot menus, expected hardware coverage,
  known limitations, and the issue-report template. Validation
  against actual physical machines is now a community ask — file
  reports at https://github.com/ruapotato/Hamnix/issues.
- ~~UEFI handoff completion (GetMemoryMap + ExitBootServices).
  The PE stub now completes the firmware handshake — calls
  `BootServices->GetMemoryMap()` then `ExitBootServices()` with
  bounded MapKey-staleness retries, prints `[hamnix] post-EFI
  handoff complete` after success, then halts. Verified by the
  UEFI half of `scripts/test_iso_qemu.sh`, which asserts BOTH
  markers in order. Kernel-side `_x86_start_after_loader`
  (arch/x86/kernel/head_64.S) is the merge point for the next
  step; `boot_via_efi` + EFI-fallback memblock window
  (arch/x86/kernel/e820.ad) are the kernel-side preposition.~~
- ~~UEFI stub → start_kernel chain. SHIPPED in M16.125 as PATH A
  (UEFI-side ELF loader baked into `arch/x86/boot/efi_stub.S`):
  the stub uses HandleProtocol(ImageHandle, LoadedImageGuid) →
  HandleProtocol(DeviceHandle, SfspGuid) → OpenVolume to find the
  ESP root, then opens `\hamnix-vmlinux.elf`, AllocatePool-reads
  the full file in, parses e_phnum program headers, memcpy-copies
  each PT_LOAD's p_filesz bytes from buffer+p_offset to p_paddr +
  zero-pads p_memsz-p_filesz trailing bytes. The stub then scans
  the loaded image for the multiboot1 magic, reads the
  Hamnix EFI handoff table (planted at multiboot_header+48 in
  arch/x86/boot/header.S) to extract `_x86_start_after_loader`'s
  VMA and the address of `boot_via_efi`, patches `boot_via_efi=1`,
  runs the GetMemoryMap + ExitBootServices retry loop, then
  installs identity-mapped page tables (PML4[0]->PDPT, PDPT[0..3]
  -> 1 GiB pages covering 0..4 GiB), loads a kernel-shape GDT
  (CS=0x08, DS=0x10), and `rex.w ljmp *m16:64` (the 64-bit-offset
  encoding GAS won't accept as `ljmpq`) to flush CS into 0x08
  before `jmp *_x86_start_after_loader`. Verified by
  `scripts/test_iso_qemu.sh`: BIOS + UEFI both reach
  `cpio: registered N files from initramfs`. Blockers documented:
  B1..B4 stay as historical context; M16.125 added B5 — OVMF on
  optical media only accepts FAT12 El Torito UEFI images, so
  `scripts/build_iso.sh` formats the wide ESP with explicit
  geometry `mformat -h 64 -s 32 -t <tracks>` (FAT12, no -F).~~
  Follow-ups:
  - **EFI memory-map walker** in e820.ad — the stub already saves
    the 16 KiB descriptor buffer at `efi_mmap_buf` + descsize at
    `efi_mmap_descsize`; replace the hardcoded 2..240 MiB
    fallback with a descsize-stride walker classifying entries
    by Type (EfiConventionalMemory=7). One-screen change;
    unblocks RAM above 240 MiB on UEFI boot.
  - **Expose EFI Runtime Services** to kernel code via
    `efi_system_table->RuntimeServices`. First win:
    GetTime as a real-hardware alternative to the CMOS RTC
    in `arch/x86/kernel/time.ad`; second:
    GetVariable / SetVariable for persistent boot-config knobs
    (kernel cmdline, default initramfs path).
  - **Honour the PE relocation table** instead of runtime-
    patching `efi_gdt_descriptor_base` / `efi_far_jmp_offset` in
    .data. Add a `.reloc` section + ld script directives that
    list the absolute references xorriso / ld can fix up at
    image load. Cosmetic — the runtime patches work end-to-end —
    but a real `.reloc` table is a prerequisite for Secure Boot
    signing (the EFI signing chain requires a relocation-clean
    PE+ image).
  - **Drop the FAT12 32 MiB cap** by enabling the GPT-ESP
    direct-mount path that modern OVMF supports — UEFI can read
    a FAT32 partition referenced by GPT alone without an El
    Torito UEFI alt-platform record. Conditionally drop the El
    Torito UEFI record when the GPT ESP is large enough; ship
    both records when the ESP fits FAT12. Eliminates the 32 MiB
    ceiling on initramfs growth.
- Parse the real EFI memory map instead of the hardcoded
  2..240 MiB fallback installed by `e820_init()` when
  `boot_via_efi != 0`. The stub already saves a 16 KiB
  EFI_MEMORY_DESCRIPTOR buffer at `efi_mmap_buf` plus the
  observed `descsize` at `efi_mmap_descsize`; e820.ad needs a
  descsize-stride walker that classifies each entry's Type
  (EfiConventionalMemory = 7 is "free RAM") and feeds the
  largest above kernel_image_end() to `memblock_set_region`.
  Unblocks RAM above 240 MiB on UEFI boot.
- EFI GOP graphical console. Under UEFI boot, GRUB-EFI doesn't
  program legacy VGA text mode, so `drivers/video/console/vga_text.ad`
  (writes to 0xB8000) is dark on the monitor — UEFI users see only
  the serial console. The multiboot1 framebuffer tag (type 8) is
  available at kernel entry in `%ebx`; parse it for `(base, width,
  height, bpp, pitch)` and add a sibling driver (e.g.
  `drivers/video/console/fb_text.ad`) that renders 8x16 bitmap-font
  glyphs into the linear framebuffer. Hook the new `fb_putc` into
  the same `early_putc` fan-out point. BIOS path is unaffected
  (CGA text framebuffer still works).
