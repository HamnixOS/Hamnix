# Hamnix

**A Python-syntax systems language being used to write a Linux-equivalent
kernel on x86_64 from boot up — and incrementally infiltrate stock Linux
along the way.**

Hamnix compiles Python-syntax source with static types directly to native
machine code via a hand-written, zero-dependency compiler. Two parallel
tracks share the same compiler and language:

1. **Bare-metal Hamnix kernel + userland** (M16+) — Hamnix compiles its
   own bootable kernel image AND its own user-mode programs.
   QEMU `-kernel build/hamnix-vmlinux.elf -smp 2` boots
   through multiboot1 into 64-bit long mode (4 GiB identity-mapped
   with 1 GiB pages, U/S=1), runs `start_kernel()`, configures traps
   + Local APIC (PIT-calibrated to exactly 100 Hz) + per-CPU storage
   + TSS for ring-3 → ring-0 transitions, brings up the four-layer
   allocator (memblock → page_alloc with buddy merge → slab/kmalloc
   → kzalloc), enumerates the PCI bus, wakes the second CPU via
   INIT-SIPI-SIPI through a real-mode trampoline, schedules ring-0
   and ring-3 tasks preemptively (each user task on its own PML4 +
   per-task fd table), parses a baked-in cpio "newc" initramfs into
   a file table, drops into a userspace task that reads `/motd` via
   `SYS_OPEN`/`SYS_READ`/`SYS_WRITE`/`SYS_LSEEK`/`SYS_CLOSE`, spawns
   a sibling via `SYS_CLONE`, and exits cleanly when all tasks
   finish. **The userspace `/init` and a kernel module (`/kmod_hello`)
   are loaded from a real cpio-format initramfs via an ELF loader
   that walks PT_LOAD segments.** Userland binaries can be written
   in Hamnix (`user/hello.py` → `python3 -m compiler.adder compile
   --target=x86_64-adder-user ...`) and `SYS_EXECVE` replaces a
   running user image with a new ELF from the initramfs. Source
   tree mirrors Linux's layout
   (`arch/x86/boot/`, `arch/x86/kernel/`, `arch/x86/mm/`,
   `arch/x86/lib/`, `arch/x86/realmode/`, `init/`, `mm/`, `kernel/`,
   `kernel/sched/`, `kernel/printk/`, `drivers/tty/serial/`,
   `drivers/video/console/`, `drivers/pci/`, `drivers/net/`, `fs/`,
   `user/`, `mod/`) so reading the equivalent Linux file → porting
   it to Hamnix is the unit of work. The Hamnix language has gained a small set of
   kernel-aware primitives along the way — `Percpu[T]` per-CPU
   storage, `container_of(ptr, Type, field)`, `cast[Ptr[T]](x)`, and
   inline `asm_volatile` / `outb`/`inb`/`outl`/`inl` — so the source
   stays close to how Linux's `include/linux/*.h` macros read.

2. **.ko module infiltration** (M1..M15) — 40 Hamnix-authored kernel
   modules that load into a stock Linux kernel via the regular kbuild
   path. Exercise nearly every major kernel subsystem (chrdev, procfs,
   debugfs, ramfs, slab, kthread, workqueue, hrtimer, mutex, kprobe,
   kretprobe, sysfs, crypto, virtio-blk/-net, netfilter, kfifo, ...).
   Still build and pass; kept as the regression baseline as bare-metal
   subsystems land.

The end-game is a fully Hamnix-authored kernel that **also loads
stock Linux kernel modules and userspace binaries**. As of commit
`95535a1`:

- Stock Debian `crc32c_generic.ko` loads cleanly on Hamnix —
  95 relocations applied, 0 unresolved externals, `init_module`
  returns 0, real CRC32C-Castagnoli math running on the live path
  through the Linux-ABI shims (`linux_abi/api_crypto.ad`).
- L1..L36 of the Linux kernel ABI track are shipped (.ko loader,
  vermagic + MODVERSIONS bypass, six relocation types, ~200 Linux
  kernel symbols exported under their stock names).
- U-series (Linux userspace ABI) scaffolding in place:
  `linux_abi/u_syscalls.ad` (Linux x86_64 syscall number map),
  `linux_abi/u_ldso.ad` (dynamic-linker scaffold),
  `linux_abi/u_libc.ad` (mini libc.so.6 — strlen/strcmp/memcpy/...
  with real bodies, printf/malloc/exit wired through Hamnix
  syscalls).
- hamsh has if/then/else/fi + while/do/done + ;/&&/|| + $? +
  $VAR + double-quoted strings + PATH walker + comments — enough
  to write real boot scripts.
- ~60 GNU-style userland binaries in /bin/.
- 30/30 integration tests pass.

## Status

| Milestone | Description | Status |
|-----------|-------------|--------|
| M1 | hello-world `.ko` — loads, `_printk`s, unloads | **Done** |
| M2 | 16550A serial console — printk traffic routed through Hamnix `hamnix_console_write` (RIP-relative `outb`+LSR poll) | **Done** |
| M3.1 | `/proc/hamnix/state` — procfs entry with Hamnix seq_file show callback | **Done** |
| M3.2 | `/dev/hamnixdisk` — 8 MiB block device, Hamnix `submit_bio` | **Done** |
| M3.3 | `hamnixfs` ramfs-class filesystem — mount + file write/read + mkdir/rm/rmdir + umount | **Done** |
| M4.1 | UART RX via `request_threaded_irq` — IRQ handler in hardirq context, spinlock-guarded counter, wait_queue wake-up, `asm_volatile("pause")` | **Done** |
| M4.2 | virtio-blk — find_vqs via vtable, dma_alloc_attrs, virtqueue_add_sgs + kick → read sector 0 of disk image | **Done** |
| M4.3a | kthread + workqueue — kthread_create_on_node + manual INIT_WORK + queue_work_on | **Done** |
| M4.3b | virtio-net — register, probe, read MAC via vdev->config->get byte-by-byte, set up (rx, tx) vq pair | **Done** |
| M5.1 | `/dev/hamnix` char device — file_operations.read returns greeting via simple_read_from_buffer | **Done** |
| M5.2 | kernel timer — init_timer_key + mod_timer + timer_delete, softirq-context callback | **Done** |
| M5.3 | netfilter hook on NF_INET_PRE_ROUTING — every IPv4 packet goes through Hamnix | **Done** |
| M6.1 | slab cache — __kmem_cache_create_args + kmem_cache_alloc/free + kmalloc/kfree | **Done** |
| M6.2 | hrtimer — nanosecond-precision timer, 5 ms relative, HRTIMER_NORESTART | **Done** |
| M6.3 | mutex + completion — kthread takes mutex, signals completion; main waits | **Done** |
| M7.1 | kprobe — intercepts every `__x64_sys_openat` call before kernel handler runs | **Done** |
| M7.2 | sysfs — `/sys/hamnix/info` via kobject_create_and_add + sysfs_create_file_ns | **Done** |
| M7.3 | crypto — SHA-256("hello") via crypto_alloc_shash + crypto_shash_tfm_digest | **Done** |
| M8.1 | `/dev/pynurand` — CSPRNG via get_random_bytes + _copy_to_user | **Done** |
| M8.2 | atomic_t — two kthreads × 1000 atomic increments via `lock incl` inline asm = exactly 2000 | **Done** |
| M8.3 | dummy ethernet `eth1` — alloc_etherdev_mqs + register_netdev + ndo_open/stop/xmit callbacks in Hamnix; visible in `ifconfig` | **Done** |
| M9.1 | task introspection — read `current` via `%gs:pcpu_hot` inline asm; print pid + comm of the insmod-ing process | **Done** |
| M9.2 | intrusive doubly-linked list — INIT_LIST_HEAD + list_add + walk all implemented in pure Hamnix | **Done** |
| M9.3 | kernel UDP socket — sock_create_kern + kernel_bind to port 9999 + sock_release | **Done** |
| M10.1 | `/dev/hamnixzero` — clone of /dev/zero (reads return NUL bytes via _copy_to_user) | **Done** |
| M10.2 | delayed_work — queue_delayed_work_on + delayed_work_timer_fn, fires after 10 ms | **Done** |
| M11.1 | ktime_get nanosecond clock — measures msleep(10) at ~11.6 ms | **Done** |
| M11.2 | debugfs — Hamnix-owned `/sys/kernel/debug/hamnix/counter`, bidirectional userspace ↔ kernel u32 | **Done** |
| M12.1 | netfilter packet inspector — parses sk_buff IPv4 header, prints src/dst of every packet | **Done** |
| M12.2 | `/dev/hamnixnull` — clone of /dev/null | **Done** |
| M13.1 | utsname reader — pulls kernel release "6.12.48" out of `init_uts_ns` | **Done** |
| M13.2 | smp_processor_id — reads CPU number from `%gs:pcpu_hot+12` | **Done** |
| M14.1 | syscall hook with payload capture — kprobe on `__x64_sys_openat` reads pt_regs->di → syscall pt_regs->si → user filename byte via copy_from_user_nofault | **Done** |
| M14.2 | kretprobe — captures syscall return values from regs->ax on `__x64_sys_openat` exit; matches M14.1's 17 entries | **Done** |
| M15.1 | register_die_notifier — Hamnix on the kernel die/oops/panic notification chain | **Done** |
| M15.2 | kfifo circular buffer — alloc + in + out via the kernel's lock-free ring; "Hi!" round-trips byte-perfect | **Done** |
| **M16.1** | **Bare-metal pivot** — Hamnix compiles its own bootable kernel image; QEMU multiboot1 → 64-bit long mode → Hamnix `start_kernel()` → UART banner | **Done** |
| M16.2 | IDT + trap handlers — 32 vector stubs, common_trap, Hamnix `do_trap` (mirrors `arch/x86/kernel/traps.c`) | **Done** |
| M16.3 | memblock bump allocator — fixed 2..240 MiB range, aligned alloc (mirrors `mm/memblock.c`) | **Done** |
| M16.4 | Per-CPU areas + `%gs` base — `smp_processor_id()` = `mov %gs:0, %rax` (mirrors `arch/x86/kernel/setup_percpu.c`) | **Done** |
| M16.5 | 8259 PIC + PIT timer @ 100 Hz + `jiffies` — first real hardware IRQ (mirrors `arch/x86/kernel/i8259.c` + `time.c`) | **Done** |
| M16.6 | Cooperative scheduler — `__switch_to_asm`, `kthread_create`, two kernel threads ping-pong "ABAB…" (mirrors `kernel/sched/core.c`) | **Done** |
| M16.7 | `printk` with `%d`/`%x`/`%s`/`%p`/`%c` — `printk0`/`printk1`/`printk2` variants (mirrors `kernel/printk/printk.c`) | **Done** |
| M16.8 | kmalloc + slab + page_alloc — SLUB-style intra-object freelists, 7 kmalloc caches 32..2048 (mirrors `mm/slub.c`) | **Done** |
| M16.9 | Timer-driven preemption — `schedule()` called from timer ISR, `kthread_bootstrap` trampoline mirrors `common_irq` tail | **Done** |
| M16.10 | memset / memcpy / memmove + kzalloc — `rep stosb`/`rep movsb` (mirrors `arch/x86/lib/{memset,memcpy}_64.S`) | **Done** |
| M16.11 | panic / BUG / WARN_ON + pr_emerg/err/warn/info/debug log levels (mirrors `kernel/panic.c` + `KERN_*`) | **Done** |
| M16.12 | list_head intrusive doubly-linked list — `INIT_LIST_HEAD`, `list_add`, `list_del`, list poison (mirrors `include/linux/list.h`) | **Done** |
| M16.13 | Multiboot mmap parsing — `arch/x86/kernel/e820.py` walks firmware memory map, drives `memblock_set_region` | **Done** |
| M16.14 | `Percpu[T]` first-class language feature — codegen emits literal `%gs:offset`, master template in `.data..percpu` | **Done** |
| M16.15 | alloc_pages(order) + kmalloc > 2 KiB — per-order free lists, page-backed large allocations | **Done** |
| M16.16 | `container_of(ptr, Type, field)` compile-time builtin — collapses manual offset arithmetic at list walks | **Done** |
| M16.17 | SYSCALL/SYSRET + first ring-3 userspace task — STAR/LSTAR/FMASK MSRs, GDT user CS/DS, SYS_PUTC + SYS_EXIT | **Done** |
| M16.18 | VGA text framebuffer driver at 0xB8000 — 80×25 putc/puts/scroll (mirrors `drivers/video/console/vgacon.c`) | **Done** |
| M16.19 | TSS + RSP0 — timer IRQs fire while at CPL 3; jiffies advances during user-mode spin (50M-pause loop survives) | **Done** |
| M16.20 | clone() + multi-user-task lifecycle — parent spawns child, timer preemption interleaves them, exit() halts when last task gone | **Done** |
| M16.21 | VFS + initramfs — baked-in /motd + /version, fd table, `SYS_OPEN`/`SYS_READ`/`SYS_CLOSE` from ring 3 | **Done** |
| M16.22 | Local APIC + LAPIC timer — `IA32_APIC_BASE` enable, LVT timer periodic mode; 8259 + PIT retired | **Done** |
| M16.23 | Buddy merge-on-free in alloc_pages — cascade verified all the way to order 10 (4 MiB) | **Done** |
| M16.24 | AP bootstrap — INIT-SIPI-SIPI; trampoline at 0x8000 real→32-bit→long mode; AP bumps `cpus_online` | **Done** |
| M16.25 | LAPIC timer PIT-anchored calibration — exact HZ=100 instead of hand-picked count | **Done** |
| M16.26 | Per-task fd tables + `SYS_WRITE` + `SYS_LSEEK` — stdout/stderr pre-opened; lseek repositions | **Done** |
| M16.27 | Real cpio "newc" initramfs — `scripts/build_initramfs.py` generates the blob; `fs/cpio.py` parses at boot | **Done** |
| M16.28 | Per-task page tables — each user task owns its own PML4 (clone of BSP's); CR3 switched on context switch | **Done** |
| M16.29 | PCI bus scan + netfilter chain — enumerates QEMU's i440FX/PIIX3/stdvga/E1000; indirect-call hook dispatch | **Done** |
| M16.30 | ELF loader — `/init` loaded from cpio initramfs, PT_LOAD segments copied + zero-padded, enter_user_mode jumps in | **Done** |
| M16.31 | `SYS_EXECVE` — userspace exec() via direct SYSRETQ to new RIP/RSP with new ELF; pid preserved across image replace | **Done** |
| M16.32 | Loadable kernel modules — insmod-equivalent; `mod/kmod_hello.S` loaded at runtime, calls back via API function-pointer table | **Done** |
| M16.33 | `x86_64-adder-user` compiler target — userland programs written in Hamnix; `user/hello.py` runs as a real CPL-3 ELF | **Done** |
| M16.34 | UART RX + `sys_read` on stdin — line-buffered serial input drives interactive userland | **Done** |
| M16.35 | `hamsh` shell + `SYS_EXECVE(path, argv)` + `SYS_SPAWN` + `SYS_WAITPID` — interactive command runner with builtins | **Done** |
| M16.36 | `/proc/{version,uptime,tasks}` + `ps` — dynamic procfs snapshots rendered on open | **Done** |
| M16.37–M16.41 | Pipes (`\|`), `dup`/`dup2`, redirect (`>`), tmpfs (`/tmp/*`), multi-stage pipelines | **Done** |
| M16.42 | SIGINT delivery via Ctrl-C — kernel signals user tasks on intercept of `0x03` from the UART | **Done** |
| M16.43–M16.46 | FAT32 read-only driver — BPB parse, FAT chain walk, subdir traversal, listdir, multi-component path lookup (mirrors `fs/fat/`) | **Done** |
| M16.47–M16.49 | Per-task CWD + relative paths + `.` / `..` resolution — `sys_chdir` / `sys_getcwd` | **Done** |
| M16.50 | 7+ function parameters via SysV stack-arg ABI (compiler-side lift of 6-param cap) | **Done** |
| M16.51–M16.54 | EXT4 read-only — superblock, group descriptors, inode read, inline leaf extents, dir walk (mirrors `fs/ext4/`) | **Done** |
| M16.55 | `ls /ext` listdir wiring through VFS | **Done** |
| M16.56 | EXT4 multi-component path lookup — `cat /ext/sub/dir/file.txt` resolves through nested directories | **Done** |
| M16.57 | `/head` `/wc` `/grep` coreutils + two latent kernel bugs (task slot leak in waitpid, partial-read on transient stdin) | **Done** |
| M16.58 | EXT4 index extents (depth > 0) + 48-bit physical addresses — files past ~48 KiB and 16 TB filesystems | **Done** |
| M16.59 | EXT4 multi-block directories — dir walks every data block, not just block 0 | **Done** |
| M16.60 | Block-write path — `BlockDeviceOps.write_sectors`, virtio-blk `VIRTIO_BLK_T_OUT`, brd memcpy write | **Done** |
| M16.61–M16.62 | EXT4 block-bitmap + inode-bitmap allocators — first-fit alloc/free with on-disk bitmap write-back | **Done** |
| M16.63 | EXT4 file create end-to-end — alloc inode + alloc block + write inode + splice dirent | **Done** |
| M16.64 | EXT4 write through `>` redirect — `echo X > /ext/file` works from the shell | **Done** |
| M16.65 | tmpfs unlink + `SYS_UNLINK` + `SYS_MKDIR` no-op + `/rm` `/touch` `/mkdir` userland | **Done** |
| M16.66 | 9 more coreutils — `/seq` `/uname` `/true` `/false` `/yes` `/sleep` `/sort` `/tee` `/rev` | **Done** |
| M16.67 | EXT4 unlink (full delete: free inode + free block + tombstone dirent) | **Done** |
| M16.68 | `/dev/null` + `/dev/zero` + CMOS RTC driver + 15 more coreutils + `/etc/{hostname,passwd,group,motd,issue,os-release}` baseline | **Done** |
| M16.69 | hamsh — `#` comment lines + `$?` last-exit-code substitution | **Done** |
| M16.70 | `/df` `/du` `/tail` `/cmp` coreutils | **Done** |
| M16.71 | hamsh — `;`, `&&`, `\|\|` sub-command separators with conjunction-based skip | **Done** |
| M16.72 | Userland moved to `/bin/<name>`; hamsh PATH walker resolves bare command names (`/bin`, `/sbin`, `/usr/bin`) | **Done** |
| M16.73 | hamsh sources `/etc/rc` at startup — boot-time script in the shell's own syntax (motd, echo banners, sets up onboarding) | **Done** |
| M16.74 | `/bin/which` + 7 more coreutils (`free`, `uptime`, `mv`, `ln` stub, `cal`, `expr`, `test`) + `init2`/`/etc/inittab` scaffold | **Done** |
| M16.75 | PS/2 keyboard driver — Set 1 scancode translation, 128-byte FIFO, drained on every timer tick; `vfs_read` on stdin pulls from kbd + UART | **Done** |
| M16.76 | hamsh shell variables — `FOO=bar` assignment, `$NAME` substitution, 8-slot static table | **Done** |
| M16.77 | stdout/stderr mirrored to VGA text console — userland writes visible on real-hardware monitor, not just serial | **Done** |
| M16.78 | hamsh `env` + `unset` builtins — dump and clear shell variables | **Done** |
| M16.79 | hamsh PATH walker uses `$PATH` variable — colon-separated, falls back to hardcoded `/bin:/sbin:/usr/bin` when unset | **Done** |
| M16.80 | hamsh double-quoted string tokenization — `echo "hello world"` is one token | **Done** |
| M16.81 | `/bin/banner` + `/bin/strings` | **Done** |
| M16.82 | `/bin/halt` + `/bin/poweroff` + `/bin/reboot` stubs | **Done** |
| M16.83 | 7 more coreutils: `/bin/pgrep`, `/bin/kill`, `/bin/sed`, `/bin/awk`, `/bin/less`, `/bin/xargs`, `/bin/ascii` | **Done** |
| M16.84 | hamsh — single-line `if COND ; then BODY ; fi` conditionals | **Done** |
| M16.85 | hamsh — `else` branches + `while COND ; do BODY ; done` loops | **Done** |
| M16.86 | 5 more coreutils: `/bin/base64`, `/bin/md5sum`, `/bin/env_show`, `/bin/watch`, `/bin/whatis` | **Done** |
| M16.87 | 9 more userland: `/bin/top`, `/bin/ifconfig`, `/bin/route`, `/bin/lsmod`, `/bin/dmesg`, `/bin/su`, `/bin/passwd`, `/bin/login`, `/bin/getty` (mostly stubs; top + getty functional) | **Done** |

## L-series: Linux ABI compatibility

Track that adds binary compatibility with stock Linux 6.12.48 kernel
modules (`.ko` files). When complete, Hamnix loads unmodified `.ko`
binaries — including the M1..M15 test modules and stock distro
drivers (xhci_hcd, nvme, usbhid, e1000e). See
`linux_abi/TARGET_ABI.md` for the pinned target.

| Milestone | Description | Status |
|-----------|-------------|--------|
| **L0** | BTF parser + `scripts/gen_linux_abi.py` + initial generated structs (`module`, `list_head`, `kobject`, `kref`) | **In progress** |
| **L1** | ET_REL `.ko` loader: ELF parse, relocations, vermagic + MODVERSIONS bypass, `module_init/exit` dispatch. `SYS_INIT_MODULE`/`SYS_DELETE_MODULE`. `/bin/insmod`, `/bin/rmmod` | **Done** |
| **L2** | `kmalloc` / `kfree` / `krealloc` / `kzalloc` exports | **Done** |
| **L3** | `kmem_cache_create` / `alloc` / `free` / `destroy` | **Done** |
| **L4** | chrdev: `register_chrdev`, `cdev_init`, `cdev_add`, etc. | **Done** |
| **L5** | procfs: `proc_create`, `seq_printf`, `seq_puts`, `proc_mkdir` | **Done** |
| **L6** | Mutex + spinlock + completion (uniprocessor model) | **Done** |
| **L7** | Wait queues: `__init_waitqueue_head`, `prepare_to_wait`, `__wake_up` | **Done** |
| **L8** | kthread + workqueue: `kthread_create_on_node`, `__alloc_workqueue`, `INIT_WORK`-shape | **Done** |
| **L9** | `timer_list`: `timer_setup`, `mod_timer`, `del_timer_sync` | **Done** |
| **L10** | `hrtimer` + `ktime_get` ns clock | **Done** |
| **L11** | IRQ: `request_irq`, `request_threaded_irq`, `free_irq` | **Done** |
| **L12** | sysfs: `kobject_create_and_add`, `sysfs_create_file_ns` | **Done** |
| **L13** | kprobe / kretprobe: register/unregister | **Done** |
| **L14** | debugfs: `debugfs_create_dir` / `_file` / `_u32` | **Done** |
| **L15** | crypto: `crypto_alloc_shash`, `crypto_shash_tfm_digest` | **Done** |
| **L16** | random + `_copy_to_user` / `_copy_from_user` | **Done** |
| **L17** | atomic ops + `__queue_delayed_work` + kfifo | **Done** |
| **L18** | `init_uts_ns` + `smp_processor_id` | **Done** |
| **L19** | `list_head` re-exports under Linux names | **Done** |
| **L20** | `register_die_notifier` | **Done** |
| **L21** | PCI core: `__pci_register_driver`, config-space accessors, BAR map | **Done** |
| **L22** | DMA API: `dma_alloc_coherent`, `dma_map_single` | **Done** |
| **L23** | virtio core: `register_virtio_driver`, `virtqueue_add_sgs` | **Done** |
| **L24** | Block layer: `blk_alloc_disk`, `add_disk`, `blk_mq_alloc_tag_set` | **Done** |
| **L25** | netdev: `alloc_etherdev_mqs`, `register_netdev`, skb alloc/free | **Done** |
| **L26** | netfilter: `nf_register_net_hook`, `nf_unregister_net_hook` | **Done** |
| **L27** | Filesystem registration: `register_filesystem`, `mount_nodev` | **Done** |
| **L28** | Kernel sockets: `sock_create_kern`, `kernel_bind` | **Done** |
| L29 | M1..M15 .ko regression passes against Hamnix | Pending (harness shipped; needs Linux 6.12.48 build tree for fixtures) |
| **L30** | First stock Debian `.ko` load attempt — crc8.ko ELF parsed, 25/28 relocs applied, no panic | **Done** |
| **L31** | `__x86_return_thunk` Spectre-v2 retpoline trampoline stub. 28/28 relocs resolved against crc8 | **Done** |
| **L32** | Read init/exit via `struct module.init/.exit` fields (offset 312/1200 from L0 BTF), not just flat symbols. Library-only modules (no init) handled cleanly | **Done** |
| **L33** | Relocation walker diagnostics + library-only module proof: `.gnu.linkonce.this_module` relocs (when present) walk via the existing target-section dispatch — no special case needed | **Done** |
| **L34** | `__crc32c_le` + 6 crypto-register shims — `crc32c_generic.ko` init runs, returns -EINVAL (placeholder CRC math) | **Done** |
| **L35** | Real CRC32C (Castagnoli) implementation in `__crc32c_le` shim — table-driven, matches Linux's `lib/crc32c.c` | **Done** |
| **L36** | First stock Debian `.ko` to load cleanly on Hamnix: `crc32c_generic.ko` init returns 0. Loader gains `R_X86_64_32` + `R_X86_64_32S` reloc support. 95 relocs applied, 0 skipped, 0 unresolved externals | **Done** |
| **L37** | Two-module dependency chain: `crc32c_generic.ko` + `libcrc32c.ko` both insmod with init==0. `nm -u` cross-check identifies missing-symbol L38 targets | **Done** |
| **L38** | `__stack_chk_fail` + `__stack_chk_guard` (gcc stack-protector runtime) + `crypto_destroy_tfm` + `crypto_shash_update`. Five-of-five UND coverage for libcrc32c.ko at load AND runtime | **Done** |
| **L41** | `nf_defrag_ipv4.ko` loads with init=0 — first netfilter module on Hamnix. New `linux_abi/api_pernet.ad`: `register_pernet_subsys` / `unregister_pernet_subsys` / `ip_defrag` / `__local_bh_enable_ip` + `nf_defrag_v4_hook` (data) + `pcpu_hot` (64-byte zero buffer). 4-slot pernet table. 112 relocs, 0 unresolved | **Done** |
| **L42** | `crc16.ko` library-only load — Bluetooth HCI / T10-PI / SCSI ULD CRC variant. Zero-gap (only UND was `__x86_return_thunk`, already covered) | **Done** |
| **L43** | `crc7.ko` + `crc-itu-t.ko` both library-only. crc7 = MMC/SD command CRC; crc-itu-t = V.41 for HDLC/PPP/ISDN. Zero-gap. Stock Debian .ko load count is now 7 | **Done** |
| **L44** | `lib80211.ko` loads with init=0 — first non-zero-gap distro module. New `linux_abi/api_lib80211.ad` (333 lines) covers 9 UND symbols: list-validation, retpoline-thunk, module_put, timer, slab, jiffies (cross-module data), kmalloc_caches | **Done** |
| **L45** | `raid6_pq.ko` loads with init=0 (RAID6 P+Q syndrome bench runs cleanly). 7 UND symbols covered in `linux_abi/api_raid6.ad`. Surfaced two real bugs: `user/insmod.ad` 128 KiB→256 KiB cap (raid6_pq is ~150 KiB), and `linux_abi/loader.ad` now brackets `init_fn()` with `local_irq_enable`/`disable` because `IA32_FMASK` masks IF on SYSCALL entry — long-running inits that wait on `jiffies` need IRQs on. Stock Debian .ko load count is now 9 | **Done** |
| **L46** | `xor.ko` (RAID5 XOR-arithmetic library) loads with init=0. 10th distro module. Only 2 new symbols vs raid6: `__x86_indirect_thunk_r9` + `__x86_indirect_thunk_r11`, appended to `api_raid6.ad` | **Done** |
| **L47** | `nf_log_syslog.ko` (netfilter syslog-logger backend) loads with init=0. 11th distro module. New `linux_abi/api_nf_log.ad` (362 lines) closes 14-symbol gap: `nf_log_register`/`unregister`/`set`/`unset`, `nf_log_buf_*`, `dev_get_by_index_rcu`, `skb_copy_bits`, `from_kuid_munged`, `from_kgid_munged`, `_raw_read_lock_bh`/`unlock_bh`, `init_net` + `init_user_ns` + `sysctl_nf_log_all_netns` data slots. Logger registered for IPv4/IPv6/ARP/BRIDGE/NETDEV families | **Done** |
| **L48** | `nfnetlink.ko` (netfilter ↔ netlink message bus core). 12th distro module. New `linux_abi/api_netlink.ad` (428 lines) closes 22-symbol gap: `__netlink_kernel_create`, `netlink_kernel_release`, `netlink_unicast`, `_broadcast`, `_has_listeners`, `nlmsg_notify`, `__nla_parse`, `__rcu_read_lock`/`unlock`, `synchronize_rcu`, `try_module_get`, `__request_module`, `skb_clone`/`pull`/`consume_skb`, `is_vmalloc_addr`, `const_pcpu_hot` data. Bumped `MAX_EXPORTS` 256→512 | **Done** |
| **L49** | 5 modules in one agent: `crc32_generic.ko`, `md4.ko`, `rmd160.ko`, `blake2b_generic.ko`, `ghash-generic.ko`. New `linux_abi/api_l49.ad` (226 lines) covers 5 UND symbols: `memcpy` (Linux ABI re-export), `__warn_printk`, `gf128mul_init_4k_lle`/`gf128mul_4k_lle`, `kfree_sensitive`. Stock Debian .ko load count is now 17 | **Done** |
| L39..L40 | usbcore, xhci-pci, xhci-hcd, usbhid, nvme, efifb / simpledrm — real-hardware drivers | Pending |
| L38 | UEFI boot path (PE/COFF) | Scaffold |
| L39 | ACPI MADT/MCFG parsing | Scaffold |
| L40 | First boot on real ThinkPad hardware | Pending |

## U-series: Linux userspace ABI

| Milestone | Description | Status |
|-----------|-------------|--------|
| **U1** | Per-task `is_linux_userspace` flag in `TaskStruct`; `do_syscall` forks to `linux_u_syscall_dispatch` when set | **Done** |
| **U2** | `fs/elf.ad` detects Linux-ABI ELF binaries via OSABI marker + PT_INTERP segment; helper to read the interpreter path | **Done** |
| **U3** | `elf_load_blob` auto-flips `is_linux_userspace` when ELF has PT_INTERP or OSABI=Linux | **Done** |
| **U4** | Real Linux syscall handlers — `read`/`write`/`close`/`lseek`/`exit`/`exit_group`/`getpid` forward to Hamnix VFS + sched; `brk` kmalloc-backed; `arch_prctl(ARCH_SET_FS)` writes `%fs_base` via `wrmsr` (critical for glibc TLS); `set_tid_address` records tidptr | **Done** |
| **U5** | First end-to-end run of a real Linux ELF64 binary on Hamnix — `fs/elf.ad` ELFCLASS64 program-header parser (entry@24, phoff@32, phnum@56, uint64), dispatched on `e_ident[4]`. Linux-ABI flag plumbing fix: `elf_load_blob` now sets `elf_last_was_linux: int32` instead of flipping `is_linux_userspace` on the current task — `SYS_SPAWN`/`SYS_EXECVE` in `arch/x86/kernel/syscall.ad` apply it to the child (spawn) or current (execve) slot, so hamsh is no longer mis-flagged across `SYS_SPAWN`. Fixture `tests/u-binary/src/hello/hello.S` (pure x86_64 asm; `write(1, msg, 27)` + `exit_group(0)` via Linux syscall numbers 1/231) built with `as` + `ld -nostdlib -static`; post-build `dd` stamps `e_ident[7] = ELFOSABI_LINUX (3)` (octal `\003` for dash) so `elf_is_linux_binary` returns 1. `scripts/build_initramfs.py` auto-embeds `tests/u-binary/*` as `/bin/<name>`; `scripts/test_u5_linux_binary.sh` boots hamsh, runs `u_hello` from PATH, and asserts the write payload. The U1..U5 chain (per-task ABI flag → ELF64 loader → OSABI detection → flag-flip on correct slot → Linux syscall dispatch) is fully verified | **Done** |
| **U6** | Multi-syscall Linux ELF test (`tests/u-binary/src/multi/multi.S`): `getpid` (39), `clock_gettime(CLOCK_MONOTONIC)` (228), `brk(NULL)` then `brk(prev+0x1000)` (12) — all green. Confirmed: the boot-time 4 GiB identity map in `arch/x86/boot/header.S` (PDPT entry `0x87 = PS|US|RW|P`) makes `kmalloc`-backed memory user-accessible, so brk/anon-mmap need no separate user mapping pass | **Done** |
| **U7** | `writev` (20) walks `struct iovec[]`, `mmap` (9) anon\|private kmalloc-backs and tracks in a 16-slot table, `munmap` (11) frees by base. SYSCALL entry stub `arch/x86/kernel/syscall_64.S` widened to forward `%r8`/`%r9` (a4/a5) — Linux syscalls with 6 args (mmap) now work end-to-end | **Done** |
| **U8** | `uname` (63) fills the 390-byte `struct utsname` (sysname=Hamnix, machine=x86_64, release=6.12.0-hamnix). `fstat` (5) builds Linux's 144-byte `struct stat` — st_size via `lseek(SEEK_END)` round-trip so it works on initramfs/tmpfs/ext4 without new VFS plumbing. `newfstatat` (262) honours `AT_FDCWD` (-100), resolves via `resolve_path`+`vfs_open`+stat+close | **Done** |
| **U9** | `stat` (4), `lstat` (6), `openat` (257), `access` (21). `_u_stat_path` helper shared between stat/lstat. `openat` honours AT_FDCWD + absolute paths | **Done** |
| **U10** | ELF64 dynamic-relocation pass — `fs/elf.ad` walks `PT_DYNAMIC`, parses `.rela.dyn`/`.rela.plt`, applies `R_X86_64_RELATIVE` (the relocation that fixes static-PIE absolute pointers). Symbol-resolving relocs (R_X86_64_64 / GLOB_DAT / JUMP_SLOT) wired but defer to U11 for lookup | **Done** |
| **U11** | `.dynsym` walker + minimal vDSO shim. `_lookup_dynsym` reads ELF64 symbol entries; UND symbols resolved against a kernel-side vDSO table (`__vdso_clock_gettime`, `__vdso_gettimeofday`, `__vdso_time`, `__vdso_getcpu`). `linux_abi/vdso.ad` ships the four entry points | **Done** |
| **U12** | First real toolchain-built C binary running on Hamnix: `musl-gcc -static-pie -O2 hello.c` → "U12: musl hello" reaches serial. Surfaced + fixed two prerequisite gaps (U13, U14) along the way | **Done** |
| **U13** | Enable SSE/SSE2 in CR4 (`OSFXSR`+`OSXMMEXCPT`) on BSP (`arch/x86/boot/header.S`) and APs (`arch/x86/realmode/trampoline.S`) + normalise CR0 (MP=1, EM=0, TS=0). Without this, `pxor %xmm0,%xmm0` in musl's `_start_c` traps `#UD`. Also enhanced `do_trap` to print `rip=` for diagnostic | **Done** |
| **U14** | **Adder compiler bug discovered + worked around:** `<`/`<=`/`>`/`>=` emit signed compare for ALL integer types, so `if x < 0xFFFFFFFFFFFFFFFF` (sentinel for "find minimum") was always false on uint64. Made `_load_elf64`/`elf_load_blob` shift every PT_LOAD by +1 byte (uint64 wrap), silently fine on single-segment native binaries but breaking 16-byte `.rodata` alignment for musl's multi-segment static-PIE → `movdqa` `#GP`. Fix: replaced sentinel pattern with explicit `have_lowest` flag in `fs/elf.ad`. See `memory/feedback_compiler_quirks.md` | **Done** |
| **U14.5** | **Compiler-level fix for the U14 bug:** `compiler/codegen_x86.py` now picks `setb`/`setbe`/`seta`/`setae` for unsigned operands and `setl`/`setle`/`setg`/`setge` for signed. New helpers `_is_unsigned_type` + `_rel_cc`. Verified by temporarily reverting the `have_lowest` workaround — U12 still passes with just the codegen fix | **Done** |
| **U15** | Real musl `printf` works end-to-end. `tests/u-binary/src/musl_argv/hello.c` calls `printf("argc=%d", argc)` + per-arg loop + `fflush(stdout)`. Full musl stdio chain (vfprintf → __towrite → writev) runs on the U7-U14 syscall surface. Zero `-ENOSYS` hits | **Done** |
| **U16** | Linux process init-stack — `arch/x86/kernel/syscall.ad` `_build_user_argv_linux` builds `[argc, argv[], NULL, envp[], NULL, auxv[], AT_NULL]` at `*rsp` per Linux ABI when the new task is Linux-flagged. Minimal auxv with `AT_RANDOM` (16-byte blob for stack-canary seeding), `AT_PAGESZ`, `AT_PHENT`. Native binaries keep the SysV register handoff. argc=1, arg[0]=/bin/u_musl_argv visible from musl `main()` | **Done** |
| **U17** | envp plumbed end-to-end: SYS_SPAWN gains `a4=envp`, SYS_EXECVE gains `a2=envp`. hamsh's `_build_envp_block` walks `var_table` and serialises `"NAME=VALUE\0"` strings into a NUL-terminated pointer array. `getenv("HOME")` returns "/root" from a musl binary after hamsh's `HOME=/root` | **Done** |
| **U18** | Real glibc-static probe — `gcc -static -O2` hello.c. **FAIL on first try**: ET_EXEC binaries have absolute addresses in `.got` that don't survive Hamnix's rebase. Surfaced + documented. Same milestone added these syscall stubs in `linux_abi/u_syscalls.ad`: `set_robust_list` (273), `prlimit64` (302), `getrandom` (318), `rseq` (334), `getrlimit` (97), and upgraded `rt_sigaction`/`rt_sigprocmask`/`mprotect` from -ENOSYS to no-op | **Done** |
| **U19** | First **glibc-static-pie** binary running on Hamnix: switched fixture to `gcc -static-pie -O2` (ET_DYN). Single PASS run. 1099 relocations applied + 22 IRELATIVE skipped (next gap). Only one -ENOSYS hit: `readlinkat` (267) — glibc tolerated | **Done** |

Surface area below targets the actual end-game.

The track that lands AFTER L-series completes. Goal: run
unmodified Linux user binaries (Steam, Firefox, language
runtimes, graphical apps) on top of Hamnix-the-kernel. Implies:

- Linux x86_64 syscall ABI under the stock numbers (read=0,
  write=1, …, openat=257, futex=202, etc.). Hamnix's own
  syscalls move to a high-number range (1000+) to avoid
  collision.
- `/lib/ld-linux-x86-64.so.2` dynamic linker — either Hamnix-
  authored or wrapping Debian's.
- Glibc / musl compatibility — the layers between
  syscalls and what apps actually call.
- `/proc` and `/sys` layouts that satisfy glibc's runtime
  setup + udev-style device introspection.
- Threading primitives — `futex(2)`, `clone(CLONE_THREAD)`,
  TLS via `arch_prctl(ARCH_SET_FS)`.
- Mmap layout that matches what loaders assume.

## End game

A shippable distribution where:
- Bootloader + kernel + init + shell + coreutils are all
  Hamnix-authored (the trust-critical surface).
- L-series enables loading the NVIDIA driver + closed-source
  kernel modules.
- U-series enables installing software from Debian's
  repositories (`apt install firefox`, `apt install steam`).
- The long-tail userspace comes from Debian, the
  security-critical core from Hamnix.

L-series order: L0/L1 (loader + structs) → L2..L28
(subsystems) → L29 (M-track validation) → L30..L40
(distro modules → first real-hardware boot).


## How it works

```
Hamnix source (.py with static types, def/while/if, structs)
   │
   ▼
compiler/  (CPython-hosted; hamnix.py CLI dispatches by --target)
   │
   ├──► codegen_x86.py  ─► .S
   │     │
   │     ├──► x86_64-bare-metal                       (M16+)
   │     │    as --32 (with .code64) + ld -m elf_i386
   │     │    ──► hamnix-vmlinux.elf
   │     │    ──► QEMU -kernel multiboot1 ──► long mode ──► start_kernel()
   │     │
   │     └──► x86_64-linux-kernel-module              (M1..M15)
   │          kbuild + modpost ──► .ko
   │          custom mitigations-off kernel + busybox initramfs
   │          ──► QEMU -serial stdio ──► dev loop closes
   │
   └──► codegen_arm.py  ─►  arm-none-eabi-as/ld ──► .elf ──► QEMU mps2-an385  (legacy MCU OS)
```

The x86_64 backend is hand-written — no LLVM — for zero external
dependencies and consistency with the existing ARM backend. Kernel
codegen constraints (SysV AMD64 ABI, 16-byte stack alignment, ENDBR64
for IBT, no red zone, RIP-relative `.rodata` refs) are handled directly.

## Quick start

Requirements: `gcc`, `make`, `qemu-system-x86_64`, `flex`, `bison`,
`libelf-dev`, Python 3.10+.

### Boot the Hamnix bare-metal kernel (M16+)

```bash
./scripts/run_x86_bare.sh
```

Compiles `init/main.py` (plus the imports it pulls in:
`arch/x86/`, `mm/memblock.py`, `kernel/sched/core.py`,
`kernel/printk/printk.py`, `drivers/tty/serial/early_8250.py`),
assembles + links into `build/hamnix-vmlinux.elf`, and boots it under
QEMU. Serial output shows the boot banner, memblock smoke test,
per-CPU id, PIT timer ticks, then two kernel threads alternating
"ABAB…" before the box halts.

### Run the kernel-module regression suite (M1..M15)

```bash
# One-time: build the custom mitigations-off kernel and busybox initramfs
sudo apt install qemu-system-x86 flex bison libelf-dev
./scripts/build_x86_kernel.sh        # ~10-25 min first time, cached after

# Build + boot any kernel-module example and assert its expected output:
for d in kernel-modules/*/; do ./scripts/run_x86_module.sh "$d"; done
```

Each module directory has an `expected.txt` listing the serial-output
strings that must appear; the runner asserts them. Exit code 0 means the
module loaded, ran, and produced the expected output.

## Writing a kernel module in Hamnix

`kernel-modules/hello/hello.py`:

```python
extern def _printk(fmt: str) -> int32

def init_module() -> int32:
    _printk("Hamnix: hello from init_module\n")
    return 0

def cleanup_module():
    _printk("Hamnix: goodbye from cleanup_module\n")
```

`init_module` / `cleanup_module` are the kernel's legacy module-entry
symbol names, found by the loader directly — no `module_init()` macro
needed. `_printk` is the modern kernel's exported printk; declared
`extern def` in Hamnix. The compiler emits `.S`; the kernel's `kbuild`
system (`obj-m := hello.o`) does the rest including modpost (vermagic,
glue, link).

For an example of real hardware access in Hamnix, see
`kernel-modules/m2-console/m2_console.py` — it declares the kernel's
`struct console` field-by-field in Hamnix, populates the fields in
`init_module`, and registers itself as a console. The driver's write
function polls the UART's Line Status Register via the `inb` intrinsic
and writes bytes via `outb`.

## Project structure

```
compiler/        Hamnix compiler (CPython-hosted)
  hamnix.py       CLI: --target= arm-cortex-m3 | x86_64-linux-kernel-module | x86_64-bare-metal
  lexer.py       Tokenizer
  parser.py      Recursive-descent parser → AST
  ast_nodes.py   AST node definitions
  codegen_x86.py x86_64 backend (hand-written, growing per milestone)
  codegen_arm.py ARM Thumb-2 backend for the MCU OS (frozen reference)
  optimizer.py   AST-level passes

# Bare-metal Hamnix kernel (M16+) — layout mirrors Linux source tree
arch/x86/
  boot/header.S         multiboot1 + 32->64 transition; identity-map
                        first 1 GiB with U/S=1; GDT (kernel + user CS/DS)
  kernel/head_64.S      64-bit entry: BSS-zero, call start_kernel
  kernel/vmlinux.lds    linker script (elf32-i386 wrapper, 64-bit code)
  kernel/boot_info_asm.S mb_magic / mb_info accessors
  kernel/idt_asm.S      per-vector trap stubs + common_trap
  kernel/idt.py         gate descriptor packing, idt_init
  kernel/traps.py       do_trap dispatch + hex printing
  kernel/irq_asm.S      per-IRQ stubs + common_irq (iretq path)
  kernel/irq.py         do_irq vector dispatch
  kernel/i8259.py       8259 PIC remap + mask/unmask + EOI
  kernel/time.py        PIT @ 100 Hz, jiffies, timer_interrupt -> schedule
  kernel/e820.py        multiboot mmap walk -> memblock_set_region
  kernel/setup_percpu.py + .S  Percpu[T] template memcpy + %gs base
  kernel/sched_asm.S    __switch_to_asm, kthread_bootstrap, enter_first_task
  kernel/syscall.py + .S STAR/LSTAR/FMASK MSRs, syscall_entry, do_syscall
                        (SYS_PUTC/EXIT/GET_JIFFIES/CLONE/GETPID/
                         OPEN/READ/CLOSE)
  kernel/tss_asm.S      TSS + RSP0 — IRQs while in CPL 3
  kernel/apic.py        Local APIC enable + LVT timer + PIT calibration
                        + INIT/SIPI IPI helpers
  kernel/smp.py + smp_asm.S   AP bring-up via INIT-SIPI-SIPI;
                              ap_main_hamnix; CR3 / load_cr3 helpers
  realmode/trampoline.S real-mode→long-mode AP trampoline (placed
                        at physical 0x8000 by linker VMA trick)
  lib/string_64.S       memset / memcpy / memmove via rep stos/movs
  mm/init.py            mem_init() arch-side bring-up
mm/memblock.py          early bump allocator (~ mm/memblock.c)
mm/page_alloc.py        order-N page allocator + buddy merge-on-free
mm/slab.py              SLUB-style slab caches + kmalloc / kzalloc / kfree
                        large kmalloc routes to alloc_pages
kernel/sched/core.py    task_struct, kthread_create, create_user_task,
                        preemptive schedule, multi-task lifecycle
kernel/printk/printk.py printk0/1/2 + pr_emerg/err/warn/info/debug
kernel/panic.py         panic / BUG / WARN_ON
kernel/list.py          list_head intrusive doubly-linked list
fs/cpio.py              parser for embedded newc cpio archive
fs/initramfs_blob.S     generated cpio bytes (scripts/build_initramfs.py)
fs/vfs.py               vfs_open / read / write / close / lseek
                        + per-task fd table (lives in task_struct)
drivers/tty/serial/early_8250.py  polled 16550A UART
drivers/video/console/vga_text.py text-mode VGA console at 0xB8000
drivers/pci/pci.py      PCI config space access (port 0xCF8/0xCFC)
                        + bus scan
drivers/net/netfilter.py netfilter hook chain + indirect dispatch
scripts/build_initramfs.py  regenerates fs/initramfs_blob.S
init/main.py            start_kernel()

kernel-modules/  Hamnix source for each module milestone
  hello/         M1   hello-world
  m2-arith/      M2.0 params/locals/while/if
  m2-string/     M2.1 pointer indexing
  m2-outb/       M2.2 outb/inb intrinsics
  m2-strout/     M2.3 polled string write
  m2-console/    M2.4 struct console + register_console
  m3-proc/       M3.1 /proc/hamnix/state via seq_file
  m3-disk/       M3.2 /dev/hamnixdisk block device
  m3-fs/         M3.3 hamnixfs mountable filesystem
  m4-uart-rx/    M4.1 UART RX IRQ + spinlock + wait_queue
  m4-virtio-blk/ M4.2 virtio-blk read sector 0
  m4-kthread-wq/ M4.3a kthread + workqueue
  m4-virtio-net/ M4.3b virtio-net probe + MAC read + vq setup
  m5-chrdev/     M5.1 /dev/hamnix char device
  m5-timer/      M5.2 jiffies-based kernel timer
  m5-netfilter/  M5.3 netfilter hook on NF_INET_PRE_ROUTING
  m6-slab/       M6.1 slab cache + kmalloc
  m6-hrtimer/    M6.2 high-resolution timer
  m6-sync/       M6.3 mutex + completion
  m7-kprobe/     M7.1 kprobe intercepting __x64_sys_openat
  m7-sysfs/      M7.2 /sys/hamnix/info kobject
  m7-crypto/     M7.3 SHA-256 via kernel crypto API
  m8-random/     M8.1 /dev/pynurand via get_random_bytes
  m8-atomic/     M8.2 atomic_t via `lock incl` inline asm
  m8-netdev/     M8.3 dummy ethernet net_device
  m9-task/       M9.1 read `current` via per-CPU segment register
  m9-list/       M9.2 list_head intrusive list (pure Hamnix)
  m9-socket/     M9.3 in-kernel UDP socket bound to port 9999
  m10-zero/      M10.1 /dev/hamnixzero (clone of /dev/zero)
  m10-dwork/     M10.2 delayed_work via timer-backed workqueue
  m11-ktime/     M11.1 ktime_get nanosecond clock
  m11-debugfs/   M11.2 debugfs u32 counter
  m12-nfdump/    M12.1 netfilter packet inspector
  m12-null/      M12.2 /dev/hamnixnull
  m13-utsname/   M13.1 read kernel release from init_uts_ns
  m13-cpuid/     M13.2 smp_processor_id via per-CPU segment
  m14-syscall/   M14.1 kprobe captures the path of every openat()
  m14-kretprobe/ M14.2 kretprobe captures the return value
  m15-die-notifier/ M15.1 register_die_notifier
  m15-kfifo/     M15.2 kfifo circular buffer

scripts/         x86 dev-loop infrastructure
  run_x86_bare.sh        Compile init/main.py → hamnix-vmlinux.elf → QEMU -kernel
  build_x86_kernel.sh    Fetch + build mitigations-off Linux for QEMU
  x86_kernel_config.sh   Kernel config knobs
  make_initramfs.sh      Build static busybox + cpio initramfs
  run_x86_module.sh      Build module → pack initramfs → boot QEMU → scrape serial

docs/
  x86-backend.md         Rationale: hand-written encoder, not LLVM
  ARCHITECTURE.md        Compiler internals
  API.md, HARDWARE.md    Legacy MCU OS reference

# Legacy MCU OS (still compiles, not the focus):
kernel/  lib/  programs/  runtime/  bsp/  tests/  coreutils/  vtnext/
build.sh  boot_vm.sh                # ARM Cortex-M build/boot
```

## Working agreements

- Each language extension lands with a `LANGUAGE.md` sentence, a test in
  `tests/`, and a real use site in a kernel module that justified it.
- Small commits that boot. A failing-to-load `.ko` is worse than fewer
  features.
- When a kernel idiom is awkward, propose a minimal language extension
  before working around it in user code — the language is meant to grow.
- Kernel codegen constraints honored as code is written: SysV AMD64 ABI,
  16-byte stack alignment, ENDBR64, no red zone, RIP-relative `.rodata`.
  Initial development targets a custom kernel with mitigations off; ratchet
  them on as the codegen matures.

## License

GPL-3.0 — see [LICENSE](LICENSE).
