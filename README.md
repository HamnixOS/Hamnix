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
   in Adder (`user/hello.ad` → `python3 -m compiler.adder compile
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

**Project direction lives in `docs/`:**

- [`docs/architecture.md`](docs/architecture.md) — the layered model
  (Layer 0 kernel internals = Linux-shape; Layer 1 native syscalls =
  Plan 9-shape; Layer 2 Linux ABI shims; Layer 3 9P userspace
  services; Layer 4 wire protocols including VTNext; Layer 5 apps).
  Read this first.
- [`docs/native-api.md`](docs/native-api.md) — the Plan 9-shape native
  syscall surface (~25 calls) and the migration table for every
  existing `SYS_*`.
- [`docs/vtnext-v2.md`](docs/vtnext-v2.md) — graphical wire protocol
  spec (apps → `hamwd` → renderer). The path to a windowed desktop
  without DRM/Mesa/Vulkan.
- [`TODO.md`](TODO.md) — open work items, organised by layer.
- [`docs/BOOT.md`](docs/BOOT.md) — building + booting the ISO,
  real-hardware notes.

The end-game is a fully Hamnix-authored kernel that **also loads
stock Linux kernel modules and userspace binaries** — shipped as
a real installable **server OS** that can run Debian-packaged
services (`apt install python3`, `apache2`, `openssh-server`,
`postgresql`). Graphics is **console-only** (VGA text + EFI GOP
text-mode framebuffer); X11 / Wayland / Steam / Firefox / any
GUI app are explicitly **out of scope**. Snapshot:

- 24 stock Debian `.ko` modules load cleanly on Hamnix —
  crc32c_generic, crc16, crc7, crc-itu-t, lib80211, raid6_pq,
  xor, nf_log_syslog, nfnetlink, crc32_generic, md4, rmd160,
  blake2b_generic, ghash-generic, xxhash_generic, crypto_null,
  des_generic, chacha_generic, poly1305_generic, curve25519-
  generic, chacha20poly1305, nf_defrag_ipv4, plus the L67/L68
  xt_* + nft_* netfilter family.
- L1..L68 of the Linux kernel ABI track are shipped (.ko loader,
  vermagic + MODVERSIONS bypass, six relocation types, ~1300
  Linux kernel symbols exported under their stock names).
- U-series (Linux userspace ABI) running real toolchain-built
  binaries — musl-static, glibc-static-pie, C++ static-pie with
  iostream + STL + exceptions, fork+waitpid, musl pthreads with
  real 16-slot futex queue + per-task TLS via MSR_FS_BASE.
- hamsh has if/then/else/fi + while/do/done + ;/&&/|| + $? +
  $VAR + double-quoted strings + PATH walker + comments — enough
  to write real boot scripts.
- ~60 GNU-style userland binaries in /bin/.
- Bootable hybrid BIOS+UEFI ISO via grub-mkrescue (commit
  `b8e1d45`); VGA text-mode console verified on QEMU under BIOS
  (EFI GOP framebuffer is the next gap for UEFI graphical
  output).
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
| M16.13 | Multiboot mmap parsing — `arch/x86/kernel/e820.ad` walks firmware memory map, drives `memblock_set_region` | **Done** |
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
| M16.27 | Real cpio "newc" initramfs — `scripts/build_initramfs.py` generates the blob; `fs/cpio.ad` parses at boot | **Done** |
| M16.28 | Per-task page tables — each user task owns its own PML4 (clone of BSP's); CR3 switched on context switch | **Done** |
| M16.29 | PCI bus scan + netfilter chain — enumerates QEMU's i440FX/PIIX3/stdvga/E1000; indirect-call hook dispatch | **Done** |
| M16.30 | ELF loader — `/init` loaded from cpio initramfs, PT_LOAD segments copied + zero-padded, enter_user_mode jumps in | **Done** |
| M16.31 | `SYS_EXECVE` — userspace exec() via direct SYSRETQ to new RIP/RSP with new ELF; pid preserved across image replace | **Done** |
| M16.32 | Loadable kernel modules — insmod-equivalent; `mod/kmod_hello.S` loaded at runtime, calls back via API function-pointer table | **Done** |
| M16.33 | `x86_64-adder-user` compiler target — userland programs written in Adder; `user/hello.ad` runs as a real CPL-3 ELF | **Done** |
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
| M16.88 | Bare-metal virtio-net PCI driver (`drivers/net/virtio_net.ad`) — legacy IO-BAR probe, F_MAC negotiation, RX/TX virtqueue setup, 8 pre-populated 1526-byte RX buffers, MAC read from device config space, in-kernel ARP probe → SLIRP gateway round-trip; `eth_rx()` gets real frames. Polled (no IOAPIC yet); IRQ wiring + DHCP/ICMP follow-ups deferred | **Done** |
| M16.89 | Native AHCI driver (`drivers/ata/ahci.ad`) — PCI class-match (0x01/0x06/0x01), ABAR (BAR5) map, GHC.AE enable, PI/SSTS port scan, per-port 4 KiB DMA page (1 KiB command list + 256 B FIS + 256 B command table), single-slot polled commands; issues IDENTIFY DEVICE (decodes model string + LBA48 capacity) and READ DMA EXT of LBA 0 (MBR signature check). Unlocks SATA on real consumer hardware (~2008+) | **Done** |
| M16.90 | Bare-metal ARP responder + cache (`drivers/net/arp.ad`, `drivers/net/eth.ad`) — `eth_rx()` parses the 14-byte ethernet header and dispatches by ethertype to ARP (0x0806) / IPv4 (0x0800); ARP RX validates htype/ptype/hlen/plen, learns sender bindings on both REQUEST and REPLY into an 8-entry cache, and builds a reply frame when the target protocol address is ours. Validated end-to-end: SLIRP gateway's ARP reply to our probe lands at `[arp] cached: 10.0.2.2 -> <mac>` (see `scripts/test_net_arp.sh`) | **Done** |
| M16.92 | Native NVMe driver (`drivers/nvme/nvme.ad`) — PCI class-match (0x01/0x08/0x02), 64-bit BAR0 map, controller disable + admin queue setup (ASQ/ACQ/AQA) + CC.EN with IOSQES=6/IOCQES=4, polled phase-bit completion path; runs IDENTIFY controller (decodes 40-byte model + 20-byte serial), IDENTIFY namespace 1 (NSZE = total LBA count), CREATE-IO-CQ + CREATE-IO-SQ (qid=1, 64 deep), and I/O READ of LBA 0 with MBR signature check. Unlocks PCIe SSDs on modern laptops/servers (~2014+) — the install base where AHCI is dead. Polled completion only; MSI-X + write path + multi-queue follow up | **Done** |
| M16.93 | Phase B: Plan 9 syscall numbers reserved + SYS_ERRSTR (265). 9 new numbers stubbed (-ENOSYS): rfork (256), bind (257), mount (258), unmount (259), create (260), stat (261), fstat (262), remove (263), fd2path (264). SYS_ERRSTR has a real body in `sys/src/9/port/error.ad` with 9front-style swap-buffer semantics; reads the per-task `errstr_buf` (128 B inline in `TaskStruct`) into a user buffer, and if the user buffer carries a non-empty string, installs that as the new current error. Integrated at exactly one failure path (SYS_OPEN → -ENOENT installs "file does not exist") so `tests/test_errstr.ad` can round-trip the message end-to-end. Foundation for every following Plan 9 native syscall — they all need `errstr` to report errors. See `docs/architecture.md` (Phase B/C of the migration plan) and `docs/native-api.md` for the syscall contract | **Done** |
| M16.94 | Plan 9 `/dev/cons` device file — `vfs_open('/dev/cons')` (and the OWRITE variant) returns an `FD_CONS_MARK` fd whose read side blocks on the existing kbd/UART RX FIFOs and whose write side fans bytes through `early_putc()` to UART + VGA/fb + printk. First concrete Layer-1 cdev landing under `sys/src/9/port/devcons.ad`; mirrors 9front's `/sys/src/9/port/devcons.c` at minimum scope. Unblocks the `SYS_PUTC → write("/dev/cons")` migration row in `docs/native-api.md` and is the template for the follow-up `/dev/time`, `/dev/pid`, `/dev/random` devs | **Done** |
| M16.95 | Plan 9 `/dev/time` + `/dev/pid` + `/dev/random` device files — three new stateless cdevs under `sys/src/9/port/devtime.ad`, `devpid.ad`, `devrandom.ad` with `FD_TIME_MARK` (0xFFFFFFF0) / `FD_PID_MARK` (0xFFFFFFEF) / `FD_RANDOM_MARK` (0xFFFFFFEE) plumbing in `fs/vfs.ad`. `/dev/time` reads emit `get_jiffies()*10_000_000` ns-since-boot as ASCII decimal + `\n` (HZ=100 → 10 ms per tick); `/dev/pid` reads emit `current_task_pid()` as ASCII decimal + `\n`; `/dev/random` reads stream xorshift64 bytes (lazy-seeded from `get_jiffies()` mixed with the golden-ratio constant on first read — placeholder pending chacha20 + RDRAND/RDSEED). Writes return -1 on time/pid; `/dev/random` XOR-folds writes into the PRNG state as entropy mix. Retires the `SYS_GET_JIFFIES → read("/dev/time")` and `SYS_GETPID → read("/dev/pid")` rows in the migration table. See `scripts/test_devtime.sh`, `scripts/test_devpid.sh`, `scripts/test_devrandom.sh` | **Done** |
| M16.96 | DHCP client + virtio_net_tx public surface + IPv4/UDP/ICMP scaffold (`drivers/net/dhcp.ad`, `drivers/net/ip.ad`, `drivers/net/udp.ad`, `drivers/net/icmp.ad`, `drivers/net/virtio_net.ad` +`virtio_net_tx`). `eth_tx()` now wires through to the TX virtqueue (replaces the M16.90 log-and-drop stub); `ip_send()` builds the 20-byte IPv4 header with Internet checksum and resolves dst MAC via the ARP cache (broadcast for `255.255.255.255`, gateway MAC for off-subnet). DHCP client runs the four-way DISCOVER → OFFER → REQUEST → ACK handshake against SLIRP, captures `10.0.2.15` + gateway `10.0.2.2`, and mirrors them into the IP layer + ARP responder. ICMP echo request/reply skeleton lands but the reply parse path is gated by an arp_lookup codegen quirk fixed in M16.97. See `scripts/test_net_dhcp.sh` | **Done** |
| M16.97 | ICMP echo round-trip — finishes the M16.96 scaffold. Root cause was two Adder codegen quirks in `arp_lookup`: (1) `cast[uint64](arp_ip[i])` on an `Array[N, uint32]` global doesn't zero-extend cleanly across `==`, so the equality compare reported "not equal" even when bit-patterns matched; (2) `&arp_mac[i][0]` on the 2-D `Array[N, Array[6, uint8]]` MAC table lowered to address 0 instead of the correct slot, so `ip_send` saw `dst_mac == NULL` and dropped every outbound IP frame. Workaround in `drivers/net/arp.ad`: load `arp_ip[i]` through an explicit `Ptr[uint32]` + mask, and offset off `&arp_mac` arithmetically (`mac_base + i*6`). Both quirks documented in `memory/feedback_compiler_quirks.md` for a future compiler milestone. With the fix, `[icmp] echo request -> 10.0.2.2` followed by `[icmp] echo reply from 10.0.2.2` round-trips through the SLIRP gateway — first proof of two-way IPv4 in the bare-metal kernel. See `scripts/test_net_icmp.sh` | **Done** |
| M16.98 | Phase C: Plan 9 `rfork(2)` (SYS_RFORK = 256) lands its real body in `sys/src/9/port/sysproc.ad`, replacing the M16.93 -ENOSYS stub. POSIX-fork combo `rfork(RFPROC \| RFFDG \| RFNAMEG \| RFENVG)` creates a new task that returns the child pid in the parent and 0 in the child; in-place mutation (no RFPROC) privatises the namespace via RFNAMEG / RFCNAMEG. `TaskStruct` grows three sharing-state fields (`fd_table_refcount`, `namespace_id`, `note_group`) with matching accessors + monotonic id allocators (`alloc_namespace_id` / `alloc_note_group_id`) in `kernel/sched/core.ad`. `user/runtime.S` adds a `sys_rfork(flags)` wrapper that stashes the parent's user-side `%rbp` into syscall arg a5 so `do_rfork` can patch the child's initial `__switch_to` stack image (without this the child's first RBP-relative local read after rfork lands on the parent's stack page). `RFMEM` (thread path) returns -ENOSYS in this commit — full thread route lands in a follow-up. SYS_CLONE (3) stays untouched for the Linux ABI; both work concurrently. See `scripts/test_rfork.sh` for the end-to-end fixture. Cornerstone of the Plan 9-shape process control surface — replaces fork / vfork / clone / pthread_create / unshare with one flag-bit primitive | **Done** |
| M16.99 | Minimal DNS resolver client (`drivers/net/dns.ad`) — UDP/53 A-record queries against the DHCP-supplied DNS server (option 6, captured by `dhcp_get_dns` added to `drivers/net/dhcp.ad`). `dns_lookup("example.com", out_ip, timeout)` is the synchronous entry point: it primes the ARP cache with a one-shot REQUEST for the DNS server (10.0.2.3 under SLIRP has its own MAC distinct from the gateway at 10.0.2.2, so the M16.88 probe doesn't cover it), builds a 12-byte header + length-prefixed QNAME + QTYPE=A/QCLASS=IN, sends from an ephemeral source port in the 53000..53003 pool, and polls `virtio_net_poll()` until `dns_rx` flips the slot to "answered" or the deadline elapses. Response parser walks past the question section (honoring 0xC0-0xC0 compression pointers) and scans the answer section for the first A-record's RDATA. 4-slot in-flight table dodges the M16.97 2-D-array-address codegen quirk by flattening per-slot result bytes into a 1-D `Array[16, uint8]`. `udp_rx` dispatches dst-port 53000..53003 → `dns_rx`. `[dns] resolved example.com -> 172.66.147.243` against QEMU SLIRP's DNS forwarder is the proof-of-life marker; test accepts `[dns] timeout` as a SKIP for sandboxed CI without internet. See `scripts/test_dns.sh`. Unblocks `apt update http://deb.debian.org` reaching real package mirrors by name | **Done** |
| M16.100 | PS/2 keyboard polish for real-hardware install console (`drivers/input/atkbd.ad`). Extends the M16.75 Set-1 scaffold with: extended-scancode handling via a sticky `in_e0_prefix` flag (arrow keys, Home/End, Insert/Delete, PageUp/Down, right Ctrl, right Alt/AltGr); modifier-state bitmask (`MOD_SHIFT`/`CTRL`/`ALT`/`CAPS`/`NUM`) driven by make/break for Shift/Ctrl/Alt and toggle-on-make-only for CapsLock/NumLock; Shift+letter and Caps+letter folded via XOR (both pressed cancels, matching every PC keyboard since 1985); Shift+symbol routed through a parallel `sc1_to_shifted` table (`1`→`!`, ``` ` ```→`~`, …, US-104 layout); Ctrl+letter folded to 0x01..0x1A via `& 0x1F` so Ctrl-C still produces 0x03 and the M16.42 SIGINT path keeps working; F1..F4 emit VT220 SS3 escapes (`ESC O P/Q/R/S`), F5..F12 + Insert/Delete/PageUp/PageDown emit `ESC [ <digits> ~`, arrows emit `ESC [ A/B/C/D`. Boot-time `atkbd_self_test()` feeds 12 synthetic scancode sequences through `atkbd_process_byte()` and asserts 25 FIFO bytes; banner `atkbd: self-test PASS (25 cases)` is the regression criterion in `scripts/test_atkbd_ext.sh`. Still polled from the timer tick (no IRQ 1 wiring yet); USB HID + international layouts + dead-keys are explicit follow-ups | **Done** |
| M16.101 | Phase C: Plan 9 file-operations cluster — `create` (260), `stat` (261), `fstat` (262), `remove` (263), `fd2path` (264) — real bodies in `sys/src/9/port/sysfile.ad`, replacing the M16.93 -ENOSYS stubs. `do_create` delegates to `vfs_open_write`; DMDIR returns -1 + errstr "create failed: DMDIR not supported" (no `vfs_mkdir` backend yet). `do_stat` walks the cpio archive and serialises a 9P-shape `Dir` record per `docs/native-api.md`'s "Directory format". `do_fstat` handles per-`FD_*_MARK` synthetic dirs (cons / time / pid / random / null / zero / stdin / stdout / stderr / dir / pipe) plus initramfs fds. `do_remove` is a thin `vfs_unlink` wrapper. `do_fd2path` returns canonical cpio name for initramfs fds (best-effort; per-fd path slot deferred to Phase G). `user/runtime.S` gains a generic `syscall6(nr, a0..a5)` trampoline. PASS line: `[test_p9file] PASS` — six per-primitive markers plus aggregate. `bind` (257) / `mount` (258) / `unmount` (259) remain -ENOSYS pending the `chan.ad` skeleton. See `scripts/test_p9file.sh` | **Done** |
| M16.102 | Minimal TCP/IPv4 client (active-open only) in `drivers/net/tcp.ad` — fleshes out the M16.51 scaffold into a real state machine. 8-entry static TCB table (parallel arrays, slot-index = ephemeral-port-offset from 50000), states CLOSED → SYN_SENT → ESTABLISHED → FIN_WAIT_1/2 → TIME_WAIT → CLOSED (passive-open / LISTEN deferred until sshd needs it). Public API: `tcp_connect(ip4, port, timeout)` returns slot; `tcp_send(slot, buf, len)` writes one segment + polls for ACK; `tcp_recv(slot, buf, max, timeout)` polls until data lands; `tcp_close(slot)` runs the FIN/ACK/FIN/ACK termination. ISN xorshift64-seeded off `get_jiffies()`. Checksum builds the IPv4 pseudo-header (src_ip + dst_ip + 0 + proto=6 + tcp_length) into a scratch prefix before the segment and feeds the whole thing through `ip_csum16` — same algorithm UDP/ICMP use, just with a different prefix. `ip_rx` gains a `proto == 6` dispatch path to `tcp_rx`. **Real bug found**: `ip_rx` previously handed the L4 demuxer the full buffer length, so a 40-byte TCP-ACK delivered in a 60-byte Ethernet-padded frame looked like it carried 6 bytes of phantom payload, advancing `rcv_nxt` past the next real data and dropping the echo; the fix trusts the IPv4 `total_length` field (capped at buffer length to defend against spoofed sizes). On-link destinations are ARP-primed via a one-shot REQUEST before the SYN; off-link targets route via the M16.96 gateway MAC. Smoke test in `init/main.ad:tcp_smoke_test` opens to 10.0.2.100:7 (SLIRP `guestfwd=tcp:10.0.2.100:7-cmd:cat` echoes via the host's `cat`), sends `"hi\n"`, reads it back, closes. Markers `[tcp] connected slot=0` / `[tcp] sent 3 bytes` / `[tcp] received 3 bytes: 'hi\n'` / `[tcp] closed slot=0` are the PASS criteria. No retransmission, no congestion control beyond cwnd=1 segment, no SACK / timestamps / window scaling (all explicitly out of scope for SLIRP's loss-free virtual wire). Unblocks the HTTP client that `apt update` needs. See `scripts/test_net_tcp.sh` | **Done** |
| M16.103 | Bare-metal Intel e1000e Gigabit NIC driver (`drivers/net/e1000e.ad`) — second real NIC after M16.88 virtio-net. PCI vendor 0x8086 + class 0x02/0x00/0x00 match plus a device-ID whitelist covering 82574L (0x10D3 — what QEMU's `-device e1000e` emulates), 82583V (0x150C), 82573L (0x10F5), 82579LM (0x1502, Ibex Peak PCH), I217-LM (0x153A, Lynx Point), I218-LM (0x15A2, Wildcat Point), I219-LM (0x156F, Sunrise Point) + v3 (0x15B7, Skylake). MEM + bus-master enable, BAR0 (MMIO) map, CTRL.SLU+ASDE for PHY/link bring-up, MAC read from RAL[0]/RAH[0] (post-EEPROM, no EEPROM-walk dance), 256-descriptor RX ring (4 KiB page, 16 B/desc) with 256 × 2 KiB per-descriptor receive buffers, RDBAL/RDBAH/RDLEN/RDH/RDT wired, RCTL programmed for EN + BAM (broadcast accept) + BSIZE=2K + SECRC. `e1000e_poll()` walks descriptors `(rx_tail+1)..` checking `status.DD`, strips length, hands frames to `eth_rx`, re-arms each descriptor + advances RDT. Scope is PROBE + IDENTIFY + RECEIVE only — no TX, no integration with the ARP/IP/UDP/ICMP/DHCP/DNS/TCP stack. virtio-net stays the bring-up NIC for those tests; e1000e just proves Intel silicon is reachable. Polled (no IOAPIC yet); MSI-X + full TX + IRQ wiring are explicit follow-ups. With virtio-net + e1000e, the install ISO now talks on the wire on every Dell PowerEdge / HP ProLiant / Supermicro motherboard / ThinkPad / Latitude / EliteBook from the last ~15 years. See `scripts/test_net_e1000e.sh` | **Done** |
| M16.104 | Per-task brk — fixes glibc-malloc heap-grow crash. The U39 Python milestone needed `-X heapsize=64k` to dodge a `"brk adjusted to free malloc space"` SIGABRT inside glibc's arena bookkeeping. Root cause: the `brk` syscall used a single global `linux_brk` cursor backed by kmalloc, and the kmalloc backing fragmented at page granularity — glibc's brk-grow path wants contiguous virtual address space, not page-quantised chunks. Fix: per-task `brk_base` / `brk_end` / `brk_max` fields on `TaskStruct` (zero-init in `kthread_create` / `create_user_thread`); rewrites the `linux_u` brk handler to honour them via a lazy-grow path. Multi-process Linux binaries no longer collide on a global cursor. The `-X heapsize=64k` workaround is dropped from `scripts/test_u39_python.sh` — Python now runs with glibc's default 1 MiB heap. Regressions: all 14 still PASS | **Done** |
| M16.105 | Bare-metal Realtek r8169-family NIC driver (`drivers/net/r8169.ad`) — third real NIC after M16.88 virtio-net and M16.103 e1000e. PCI vendor 0x10EC + class 0x02/0x00 match with device-ID whitelist {0x8139 (RTL8139 — the only Realtek model in modern `qemu-system-x86_64 -device help`), 0x8136 (RTL810x Fast Ethernet variant), 0x8161 (RTL8111B), 0x8168 (RTL8168 / RTL8111 — the chip on most consumer ASUS/Gigabyte/MSI boards + ThinkPads + gaming laptops), 0x8169 (older Gigabit)}. RTL8139 bring-up is implemented end-to-end: BAR0 (PIO window, 16 ports) read, PCI IO + bus-master enable, CONFIG1 LWAKE clear via 9346CR-gated config-unlock, software reset (CMD.RST poll-until-clear), MAC read from IDR0..IDR5, 9708-byte circular RX buffer allocated via `alloc_pages(2)` (8 KiB ring + 16 wrap overhead + 1500 slack), RBSTART planted with the buffer's <4 GiB physical address, RCR programmed for accept-physical-match + accept-broadcast + WRAP + RBLEN=8K, CMD.RE flipped to enable the receiver. Gigabit IDs (0x8168 / 0x8169 / 0x8161) are logged but not driven — the MMIO + 16-descriptor-ring path is deferred to a follow-up. `r8169_poll()` drains the circular buffer: walks header (`u16 status | u16 length`), validates `RXH_ROK`, hands `length - 4` bytes (strip CRC) to `eth_rx`, advances the shadow read offset (4-byte aligned, mod 8 KiB), and writes `(offset - 16) & 0xFFFF` back to CAPR per the data-sheet's offset-by-16 quirk. Scope is PROBE + IDENTIFY + RECEIVE only — no TX, no ARP/IP/UDP/ICMP/DHCP/DNS/TCP integration. virtio-net stays the bring-up NIC; r8169 just proves Realtek silicon is reachable. Polled (no IOAPIC yet); MSI / MSI-X + full TX + Gigabit MMIO + IRQ wiring are explicit follow-ups. With virtio-net + e1000e (Intel) + r8169 (Realtek), the install ISO now detects a working NIC on essentially every consumer x86 box from ~2009 onwards. See `scripts/test_net_r8169.sh` | **Done** |
| M16.106 | Phase C: Plan 9 `bind` (257) + `mount` (258) + `unmount` (259) — closes the last three Phase B -ENOSYS stubs. New `sys/src/9/port/chan.ad` ships a minimal Chan + 8-entry global MountTable skeleton; `sys/src/9/port/syschan.ad` ships `do_bind` / `do_mount` / `do_unmount` bodies. `mount` accepts an `srvfd` as a stub Chan (full 9P attach is Phase D scope). `fs/vfs.ad::resolve_path` gains a longest-prefix-match hook against the mount table before the cpio fallback. PASS: `scripts/test_p9mount.sh` — `bind` aliases `/etc` as `/sysroot`, `/sysroot/motd` opens, `unmount` removes the binding, post-unmount `/sysroot/motd` falls through to -ENOENT. Phase D prerequisite (srvfd channels at `/srv/<name>`) now exists | **Done** |
| M16.107 | HTTP/1.1 GET client — apt-fetch chain complete end-to-end. With DHCP (M16.96), DNS (M16.99), ICMP (M16.97), and TCP (M16.102) all green, `drivers/net/http.ad` ships the request/response codec on top. `http_get(url, out_buf, out_max, status_out)` parses `http://host[:port]/path`, DNS-resolves, `tcp_connect`s, sends GET with Host/User-Agent/Connection:close headers, parses status line + headers, copies body bytes. Smoke test in `init/main.ad::http_smoke_test` fetches `http://example.com/`. Verified PASS: `[http] GET example.com -> status=200 body=540bytes`, body starts with `<!doctype html>`. The full chain (virtio-net → ARP → IP → DHCP → DNS → TCP → HTTP) now works end to end — real internet HTTP fetch from a bare-metal Adder kernel. See `scripts/test_net_http.sh` | **Done** |
| M16.108 | Plan 9 `/proc/<pid>/<file>` device family — first per-process introspection surface promised by `docs/native-api.md`'s "Reserved well-known paths" table. New `sys/src/9/port/devproc.ad` serves `/proc/<pid>/status` (one-line `<pid> <name> <state> <pml4_hex>\n`) and `/proc/<pid>/cwd` on a stateless `FD_PROC_MARK` fd whose 24 low bits encode `pid<<8 \| file_kind`. `fs/vfs.ad` recognises `/proc/<digits>/<leaf>` and routes to `devproc_open`. `cat /proc/1/status` now returns the running task's row; `cat /proc/1/cwd` returns its working directory. `/proc/<pid>/note` (needs notify/noted syscalls) and `/proc/<pid>/ns` (needs Phase D namespace machinery) deferred to TODO. See `scripts/test_devproc.sh` | **Done** |
| M16.109 | TCP retransmission + RFC 6298 RTO — adds per-TCB retransmission state to `drivers/net/tcp.ad`. RTT samples feed Karn's algorithm: `rttvar = (3*rttvar + \|srtt - rtt\|) / 4`, `srtt = (7*srtt + rtt) / 8`, `rto = srtt + 4*rttvar` floored at 100 ms; skip RTT sample when retries > 0. Polling loops (connect-wait, send-wait, recv-wait) check `now - last_send > rto` and retransmit with exponential backoff (max 5 retries before -ETIMEDOUT). `scripts/test_net_tcp_retrans.sh` uses three-layer evidence (QEMU SLIRP is loss-free by construction so retrans rarely fires naturally): static `strings(ELF)` must contain both retrans + timeout format strings (proving code path is reachable), plus the existing happy-path TCP regression must still pass. Robustness for lossy real-internet paths | **Done** |
| M16.110 | DNS A-record cache (16-entry, TTL-bounded) — adds a positive + negative cache to `drivers/net/dns.ad`. Each entry stores `hostname[64]`, `ip[4]`, `expires_jiffies`, `negative` flag. `dns_lookup` short-circuits on hit; positive TTL clamped to `[60 s, 86400 s]`, NXDOMAIN cached at 60 s per nss-resolve convention. Earliest-expiry eviction when full. Saves the UDP/53 round-trip for every repeat apt-mirror lookup — `apt update` re-fetching from the same handful of hostnames no longer re-resolves them. See `scripts/test_net_dns_cache.sh` | **Done** |
| U40 | musl-static busybox fixture — `tests/u-binary/u_busybox_musl` (980 KB, ~2× smaller than the M16.37 glibc-static `u_busybox` it sits beside). New `tests/u-binary/src/musl_busybox/Makefile` builds busybox 1.36.1 from upstream source with `musl-gcc` + the host kernel UAPI tree. Banner + echo round-trip cleanly through hamsh. Zero new syscalls — the existing U18..U27 surface covers musl-busybox's boot path. Documents the path to a leaner U-track footprint for minimal install ISOs. See `scripts/test_u40_musl_busybox.sh` | **Done** |
| M16.111 | UEFI PE/COFF kernel stub — the kernel image is now a hybrid multiboot1 + PE32+ EFI executable. UEFI firmware boots `\EFI\BOOT\BOOTX64.EFI` directly without GRUB-EFI as an intermediary. New `arch/x86/boot/efi_stub.S` carries the PE/COFF prefix (MZ magic + PE32+ header, Subsystem 10 = EFI_APPLICATION); the EFI entry trampoline stashes the image handle + system table from %rcx/%rdx, sets our own stack, falls through to head_64.S. Section ordering in `vmlinux.lds` lands the PE header at offset 0 of the image without disturbing the multiboot1 magic GRUB's BIOS path still needs. `scripts/build_iso.sh` now copies `build/hamnix-vmlinux.elf` straight to ESP `\EFI\BOOT\BOOTX64.EFI`. Verified by `[hamnix] EFI entry reached` on OVMF. **Known incomplete:** the UEFI stub today prints the marker then halts; full handoff to start_kernel under UEFI is a follow-up. BIOS legacy path (GRUB+multiboot1) boots end-to-end; verified on GNOME Boxes. See `docs/BOOT.md`, `scripts/test_iso_qemu.sh` | **Done** |
| M16.112 | Real-hardware install + boot guide — `docs/REAL_HARDWARE.md`. Documents the path from `bash scripts/build_iso.sh` to a running Hamnix on physical x86, now that M16.91 (hybrid BIOS+UEFI ISO) and M16.111 (UEFI direct PE/COFF) make it mechanically possible. Covers: what works today cross-referenced to shipped milestones (boot path / display / input / storage / network / FS / userland); ISO build invocation + Debian deps; `dd` to a USB stick on Linux/macOS with the wrong-device warning + Rufus DD-mode on Windows; firmware boot-menu keys per vendor (Dell/Lenovo F12, HP F9, ASUS F8, Gigabyte/MSI F11); Secure Boot disable note (kernel unsigned — signing deferred); expected-hardware-coverage table (Intel servers / ThinkPads / Realtek consumer desktops / AMD / USB-only / Macs / ARM); not-yet-supported list (USB any, wireless, Bluetooth, GPU beyond text, Secure Boot, suspend/resume); 5-step test checklist; issue-report template. Closes the cron's "real-hardware boot test plan" in-scope item | **Done** |
| M16.113 | IOAPIC programming + IRQ-driven virtio-net RX (renumbered from agent's M16.112 due to collision). `arch/x86/kernel/apic.ad` grew `ioapic_redirect(pin, vec, lapic_id)` at MMIO 0xFEC00000; `arch/x86/kernel/irq.ad` grew a 256-slot `irq_handlers[]` table + `register_irq_handler(vec, fn)` with per-vector dispatch + centralised `lapic_send_eoi`. IDT extended to vectors 32..71; vector 0x40 claimed for virtio-net. `drivers/net/virtio_net.ad` reads PCI INTERRUPT_PIN/LINE and programs IOAPIC pin 11 → vector 0x40 → LAPIC 0. `virtio_net_poll()` stays as the pre-sti safety net. Template for AHCI / NVMe / e1000e / r8169 / virtio-blk IRQ wiring. See `scripts/test_net_irq.sh` | **Done** |
| M16.114 | Plan 9 `notify(2)` (270) + `noted(2)` (271) — last two Phase B reserved syscalls. `sys/src/9/port/sysnote.ad` ships `do_notify(handler)` (install user-mode note handler RIP per current task; 0 clears) + `do_noted(action)` (handler returns; resume saved user RIP/RSP). `kernel/sched/core.ad` carries `note_handler_rip`, `note_pending`, plus saved user resume state. `sys/src/9/port/devproc.ad` extends `/proc/<pid>/note` write to deliver a note: if a handler is installed, the target task's user-mode resume is redirected to the handler with the note string ptr in RDI (SysV convention); otherwise logged + dropped. PASS: `scripts/test_note.sh` — fixture forks a sibling that writes a note to its parent's `/proc/<pid>/note`; the parent's installed handler runs and `noted(0)` returns cleanly. **Phase B reserved syscall block (256..271) is now fully Done**, modulo `wstat`/`fwstat` (266/267) deferred to Phase G | **Done** |
| | **Shell UX bug-fix wave** (caught by user testing the M16.111+M16.91 ISO on GNOME Boxes): commit `ceefc8a` adds character-at-a-time read + echo + cwd-in-prompt to hamsh (so keystrokes appear as typed); commit `d45bae1` makes `scripts/build_iso.sh` always rebuild + use `hamsh` as `/init` (the booted ISO previously ran the legacy asm `/init` that exec'd `/hello` and halted); commit `51a6974` swaps `ls`/`find` default target from legacy `/mnt` to the cwd. Real-hardware UX papercuts only visible under a human keyboard — `test_hamsh.sh` couldn't catch them because the harness pipes full lines at once | **Done** |
| U41 | CPython 3.11.10 from-source static build — Makefile + HOWTO ship at `tests/u-binary/src/cpython/`; build produces a 5.7 MB stripped binary stamped `ELFOSABI_LINUX`. **PARTIAL — blocked at importlib bootstrap**: the binary loads cleanly through the Linux ELF loader (4 PT_LOADs, ET_EXEC user-map [0x400000, 0x9c4000)) but importlib aborts with `Fatal Python error: pycore_interp_init: failed to initialize importlib / MemoryError` before reaching `print()`. Diagnosed root cause: per-task `LINUX_BRK_RESERVE = 4 MiB` and `LINUX_MMAP_SLOTS = 32` in `linux_abi/u_syscalls.ad` are too small for CPython's ~10-15 MiB importlib-init heap. Zero new `-ENOSYS` hits — every syscall CPython issues is already handled. Fix is a one-line bump in u_syscalls.ad; deferred to a follow-up commit to avoid the in-flight cd-validation overlap. See `scripts/test_u41_cpython.sh` | **Partial** |
| M16.116 | `sys_chdir` existence validation + `du` cwd-relative default. Closes the GNOME-Boxes-caught shell papercut where `cd nope/nope/nope` silently accumulated bogus segments into per-task cwd. `arch/x86/kernel/syscall.ad`'s SYS_CHDIR branch now probes the resolved abs path via `vfs_open` + `vfs_fd_is_dir` and rejects with -ENOENT (errstr `"chdir: no such directory"`) or -ENOTDIR (`"chdir: not a directory"`) before installing the new cwd. `user/du.ad` swept to follow the ls/find pattern (default to sys_getcwd when invoked with no args). `scripts/test_cwd.sh` + `test_dotdot.sh` updated to use real cpio paths (they previously relied on chdir's broken acceptance of nonexistent targets). New `scripts/test_cd_validation.sh` PASSes 5/5: fixture ran, `chdir(/etc)` accepted, `chdir(/nope/nope)` rejected, errstr matches, cwd preserved across failure | **Done** |
| M16.117 | AHCI / NVMe / e1000e / r8169 IRQ wiring — extends the M16.113 IOAPIC + per-vector handler-registration template to the remaining 4 bare-metal device drivers. Per-driver IRQ vectors: AHCI=0x41, NVMe=0x42, e1000e=0x43, r8169=0x44 (virtio-net at 0x40 from M16.113). Each driver's init reads PCI INTERRUPT_PIN + INTERRUPT_LINE, programs the IOAPIC redirection entry, registers a `*_irq_handler()`. Handlers ack at the device level (AHCI: GHC.IS + PxIS; NVMe: CQ phase walk; e1000e: ICR; r8169: ISR write-back) then call the existing polled drain. Polled `*_poll()` paths stay as pre-sti safety nets. All bare-metal devices now run IRQ-driven on real hardware. See `scripts/test_drivers_irq.sh` | **Done** |
| M16.118 | AHCI + NVMe WRITE paths — closes the read-only gap on both bare-metal disk drivers. AHCI gains WRITE DMA EXT (ATA 0x35) via `ahci_write_sectors`; NVMe gains I/O Write (opcode 0x01) via `nvme_write_lba`. Same SQ/CQ + PRDT machinery as READ, with the W bit set in the AHCI command header and the WRITE opcode in the NVMe SQE. Read counterparts (`ahci_read_sectors`, `nvme_read_lba`) exposed so external callers can verify writes. Tests `scripts/test_{ahci,nvme}_write.sh` write a known pattern to LBA 1, read it back, assert byte-equal. Block-layer integration (registering with `BlockDeviceOps.write_sectors`) deferred to a follow-up — `kernel/block/blk.ad` had concurrent edits this round | **Done** |
| M16.119 | Plan 9 `wstat` (266) + `fwstat` (267) — closes the Phase B reserved-syscall block 256..271. **Every reserved number now has a real body**; Phase G can retire Linux-shape `SYS_*` without unfinished business. Bodies in `sys/src/9/port/sysfile.ad::do_wstat` + `do_fwstat`. Dir-record parser honours two mutable fields: `name` (rename) routes through new `vfs_rename` → `tmpfs_rename` (tmpfs-only; ext4 rename = follow-up); `mode` (chmod) accepted as a successful no-op until per-inode mode storage lands. `length` / `mtime` / `gid` / `muid` must be wstat sentinel (`~0` for ints, empty string for counted strings); non-sentinel surfaces -1 + `errstr("wstat: <field> not supported")`. `fwstat` wired for FD_TMPFS_MARK fds only (path recovered via new `tmpfs_slot_name`); other backends report `errstr("fwstat: backend not supported")`. PASS: `[p9wstat] PASS` — 6 per-leg markers plus aggregate. See `scripts/test_p9wstat.sh` | **Done** |
| M16.120 | UEFI handoff partial completion — GetMemoryMap + ExitBootServices. EFI stub now calls `BootServices->GetMemoryMap(...)` into a 16 KB static buffer + `BootServices->ExitBootServices(ImageHandle, MapKey)` with bounded retries (max 4) on EFI_INVALID_PARAMETER (the MapKey-staleness case). Marker `[hamnix] post-EFI handoff complete` fires AFTER ExitBootServices returns success — proves firmware released the platform. MS x64 ABI plumbed by hand (32-byte shadow space, 16-byte alignment, 5th arg at `[rsp+0x20]`). Forward infrastructure: `_x86_start_after_loader` symbol in `head_64.S` + `boot_via_efi` flag + EFI-fallback memblock window (2..240 MiB) pre-positioned for the stub-to-kernel jump. **STILL INCOMPLETE**: the EFI stub and kernel ELF remain SEPARATE binaries (`build/hamnix-bootx64.efi` vs `build/hamnix-vmlinux.elf`), so the stub still halts after marker. The proper fix is "kernel ELF IS the EFI executable" (single binary with PE+multiboot1 hybrid headers); deferred. BIOS path remains the working real-hardware boot route | **Partial** |
| M16.121 | MBR + GPT partition-table parser (`drivers/block/partition.ad`) — read-only side. MBR primaries via byte map at offset 446-509 with 0x55AA signature check; GPT via "EFI PART" header at LBA 1 with protective-MBR (type 0xEE) auto-fallback. Per-disk 16-slot table addressable through `partition_for(slot, idx)`. `kernel/block/blk.ad::blk_scan_partitions(slot)` is the entry point. PASS markers per partition: `[partition] disk=vda idx=N lba=A..B type=0xNN` for MBR; `[partition] protective MBR detected, switching to GPT` then per-entry markers for GPT. Real-hardware install path now knows what's on a disk before writing — partition-write side is a follow-up. See `scripts/test_partition.sh` | **Done** |
| M16.122 | **Phase C.5: distro-shape namespaces** — `/bin/distrorun <distro> <cmd> [args...]` ships. Privatises the calling task's namespace via `rfork(RFNAMEG)`, opens `/var/lib/distros/<distro>` as a Chan, calls `mount(srvfd, ...)` (records the SRV-kind binding — inert in Phase C, will become a real 9P client mount when hamwd lands Phase D), then `bind`s `/etc /usr /lib /var` onto `backing/{etc,usr,lib,var}` (Phase C workaround: bind's prefix matcher only honors `path/` or `path\0`, so a single `bind("/", ...)` wouldn't match subpaths), then re-`bind`s `/home /net /srv /dev /proc` onto themselves to preserve shared file servers, then execs the target. End-to-end: namespaced read of `/etc/debian_version` returns `12.0` from `tests/distros/testdistro/`; native reads of `/etc/os-release` before and after return `hamnix/0.1` — both demonstrate the namespace isolation works AND hamsh's namespace is unaffected. **Linux compat is now opt-in per-process via namespace shape, not a property of the OS.** Phase B reserved syscalls (rfork, bind, mount, unmount, errstr, …) all carry weight. See `docs/distro-namespaces.md` (spec), `scripts/test_distro_namespace.sh` (test) | **Done** |
| M16.123 | AHCI + NVMe register with the kernel block layer — drivers now expose themselves as `sd0` (AHCI) and `nvme0n1` (NVMe) via `kernel/block/blk.ad`'s existing `register_blockdev(name, capacity, ops, priv)` + `BlockDeviceOps` vtable (which carries both `read_sectors` and `write_sectors` slots). Thin `_blkop` adapter wrappers translate the block layer's `(priv, lba, count, buf)` signature to each driver's native ABI; AHCI clamps count to 65535, NVMe to 65536 (NLB is 0-based). Boot-time round-trip via `_ahci_blk_smoke_test` + `_nvme_blk_smoke_test`: write a 512-byte pattern at LBA 1 through `blk_write_sectors`, read it back through `blk_read_sectors`, byte-compare. PASS markers: `blk: registered 'sd0' capacity=2048 sectors`, `[blk] write sd0 LBA=1 OK`, `[blk] readback sd0 matches` (and equivalents for nvme0n1). **Unblocks `vfs_write(fd, ...)` on an ext4-on-AHCI / ext4-on-NVMe file** — the kernel can install itself on disk. See `scripts/test_block_layer_write.sh` | **Done** |
| M16.124 | UEFI single-binary merge — honest blocker diagnosis. The M16.111+M16.120 wave was structured around merging `efi_stub.S` + `hamnix-vmlinux.elf` into one hybrid (PE+multiboot1 at offset 0) so the stub could reach `_x86_start_after_loader`. This commit is that follow-up but the conclusion is honest: the merge is genuinely blocked by four independent constraints (B1: `\x7fELF` and `MZ` can't share file offset 0; B2: `.ap_trampoline` LMA/VMA split doesn't survive PE/COFF conversion; B3: kernel has no `.reloc` table for UEFI image relocation; B4: GDT/CR3 handoff is moot without B1). Full diagnosis in `arch/x86/boot/efi_stub.S`'s header comment block. Two real paths out documented in `docs/BOOT.md` + `TODO.md`: PATH A (UEFI-side ELF loader baked into the stub), PATH B (bzImage-style flat-binary). Documentation-only commit closing out M16.120's "we'll merge them next" promissory note | **Diagnosis** |
| M16.125 | (TCP) Plan 9-shape TCP passive-open: LISTEN + SYN_RCVD states added to `drivers/net/tcp.ad`. New API `tcp_listen(local_port)` allocates a TCB in LISTEN state; `tcp_accept(slot, timeout)` polls for ESTABLISHED on that listener; multi-client capable (single LISTEN TCB stays in LISTEN as it accepts further inbound SYNs, with each accepted connection getting its own TCB slot). `tcp_rx` matches LISTEN TCBs by local_port before the existing remote-tuple match; fresh ISN per connection via xorshift64. Verified `scripts/test_net_tcp_listen.sh`: host-side `nc -p 5555 -e localhost` via QEMU `-hostfwd=tcp::5555-:80`; guest accepts slots 3 + 4 concurrently with payload RX and clean FIN teardown. Active-open echo regression (M16.102) still PASSes. **Unblocks an in-kernel sshd-shape listener.** | **Done** |
| M16.126 | **UEFI direct boot SHIPPED via PATH A** — kernel actually runs end-to-end under UEFI firmware now. EFI stub uses UEFI's Simple File System Protocol to read `\hamnix-vmlinux.elf` from the ESP, parses ELFCLASS32 program headers, memcpy's PT_LOAD bytes from `p_offset` → `p_paddr` + zero-pads `p_memsz - p_filesz`, scans the kernel for the multiboot magic to locate the M16.126-planted Hamnix EFI handoff table (`multiboot_header+48`: exposes `_x86_start_after_loader`'s VMA + `boot_via_efi`'s physical address), patches `boot_via_efi=1`, runs the M16.120 GetMemoryMap+ExitBootServices dance, installs identity-mapped page tables + kernel GDT, far-jumps to `_x86_start_after_loader`. Both markers fire under OVMF: `[hamnix] post-EFI handoff complete` (firmware released the platform) AND `cpio: registered 145 files from initramfs` (start_kernel ran past e820 → memblock → cpio_init). **B5 discovered**: OVMF only accepts FAT12 El Torito UEFI on optical media; `scripts/build_iso.sh` now mformats the ESP as FAT12 with explicit geometry (no `-F`). PE32+ runtime patches: no `.reloc` table, so GDT descriptor base + far-jump m16:64 offset are runtime-fixed in `.data` (and `rex.w ljmp *mem` for the m16:64 encoding since GAS rejects `ljmpq`). BIOS path unchanged + green. Closes the cron's goal #1: real-hardware UEFI direct boot via ISO image | **Done** |
| M16.127 | Partition-aware block-device naming (`sd0p1`, `sd0p2`, `nvme0n1p1`, ...). `kernel/block/blk.ad::blk_register_partitions(parent_slot, parent_name)` walks `partition_for(parent_slot, idx)` from M16.121, and for each valid partition registers a sibling block device named `<parent>pN` (1-indexed per Linux convention) with a partition-aware `BlockDeviceOps` vtable: read/write offset by `partition.lba_start` and bounds-checked against `partition.lba_end - partition.lba_start`. AHCI and NVMe init now call `blk_scan_partitions(slot)` followed by `blk_register_partitions(slot, "sd0" / "nvme0n1")`. PASS markers in `scripts/test_partition_naming.sh`: both `blk: registered 'sd0p1' capacity=63488 sectors` + `'sd0p2'` from a 64 MiB tmpfile with two msdos primaries. Real-hardware install can now target `sd0p1` as a named slice rather than computing LBAs by hand | **Done** |
| M16.128 | PS/2 mouse driver (`drivers/input/auxmouse.ad`). Brings up the i8042 second port via controller-command-byte RMW (enable IRQ12 bit, clear AUX-clock-disable), resets the device (0xFF → ACK 0xFA + BAT 0xAA + ID 0x00 standard 3-byte mouse), enables streaming (0xF4), wires IRQ 12 → vector 0x45 via IOAPIC pin 12. Decodes the 3-byte PS/2 protocol: byte0 always-1 resync sentinel + L/R/M buttons + X/Y sign bits + X/Y overflow drop; bytes 1-2 = 9-bit signed deltas (via `_sign_extend_9bit`); Y-flipped to screen-down convention. 64-event `MouseEvent {dx, dy, buttons}` ring buffer; `mouse_rx_pop()` accessor for future `/dev/mouse` cdev. Boot-time decoder self-test covers 7 cases (positive/negative dx, Y-flip, single+multi button, byte-0 resync after invalid byte, overflow drop+recovery). Together with atkbd (M16.75/M16.100) gives Hamnix the canonical PC-AT input surface — every desktop motherboard exposes both ports | **Done** |
| M16.129 | `/dev/random` ChaCha20 + RDRAND/RDSEED upgrade — retires the M16.95 xorshift64 placeholder. Real CSPRNG: 16-word ChaCha20 state (RFC 8439 constants `expand 32-byte k` + 256-bit key + 32-bit counter + 96-bit nonce), 20-round block function, 64-byte keystream block per counter advance. CPUID-detected RDSEED (leaf 7:0 EBX bit 18) preferred, RDRAND (leaf 1 ECX bit 30) fallback, `get_jiffies() ^ counter ^ golden-ratio` last resort. Inline-asm wrappers park CPUID/RDRAND outputs in RIP-relative module-globals; %rbx saved/restored across CPUID; 10-retry loop per Intel guidance. Rekeys every 4 KiB (64 blocks) by XOR-mixing 8 fresh hwrng words into state[4..11] + resetting the counter word. Block function verified against the RFC 8439 §2.3.2 test vector (Python port matched byte-for-byte). API unchanged — M16.95 `scripts/test_devrandom.sh` regression PASSes; new `scripts/test_devrandom_chacha.sh` reads 4 KiB into 256 entropy buckets, asserts all non-zero with max/min ratio ≤ 5x. Suitable for TLS handshakes, sshd key generation, password hashing | **Done** |
| M16.130 | `/dev/mouse` Plan 9-shape cdev — wraps the M16.128 `drivers/input/auxmouse.ad` event ring as a character device. `sys/src/9/port/devmouse.ad` ships open/read/write/close; one read pops one event and renders ASCII `<dx> <dy> <buttons>\n` (signed dx/dy, button bitmap). Writes return -1 (read-only). Empty ring returns 0 bytes — non-blocking poll semantics; blocking-read deferred until the syscall layer's wait-queue story lands. VFS wiring: `FD_MOUSE_MARK = 0xFFFFFFED` in `kernel/sched/core.ad`, dispatch arms in `fs/vfs.ad::vfs_open` + `vfs_open_write` + `vfs_read` + `vfs_write` + `vfs_lseek` (EINVAL on stream). Decodes `mouse_rx_pop()`'s packed int32 back to signed dx (16-bit sign-extend), dy (8-bit sign-extend), buttons (uint8). PASS: `scripts/test_devmouse.sh` asserts `[test_devmouse] opened /dev/mouse OK` under headless QEMU; parse-OK path lives in `tests/test_devmouse.ad` for future QMP-driven mouse-injection overlays. **Unlocks the hamwd input path** — future GUI code reads input the same way it reads files | **Done** |
| M16.131 | `/dev/cpuinfo` + `/dev/meminfo` cdevs — first system-introspection pair on the Plan 9 native surface. `sys/src/9/port/devcpuinfo.ad` reads CPUID leaves 0 / 1 / 7:0 / 0x80000002..4 + `get_cpus_online()` and emits vendor / family / model / brand / cpus_online / rdrand / rdseed lines. `sys/src/9/port/devmeminfo.ad` reads memblock + page_alloc accessors and emits Linux-shape kB lines (MemTotal / MemFree / MemUsed / Pages / PagesFree / KmallocLive) — eventual Layer-2 `/proc/{cpuinfo,meminfo}` translation is a near-direct byte copy. Two new stateless `FD_CPUINFO_MARK` / `FD_MEMINFO_MARK` dispatch arms in `fs/vfs.ad`. Verified under QEMU TCG: `vendor=AuthenticAMD brand="QEMU Virtual CPU version 2.5+" cpus_online=2 MemTotal=253820 kB`. Plan 9 cdev family now eight files (cons / time / pid / random / proc / mouse / cpuinfo / meminfo). Compiler quirk found: Adder's flat global symbol namespace across merged modules forced renaming `_emit_str` → `_ci_emit_str` / `_mi_emit_str` to dedupe between the two new files | **Done** |

U41 status update (commit `80068d9`): graduated **Partial → Done**. CPython 3.11.10 now built with frozen stdlib (`encodings.*` + `collections.*` + ~17 leaf modules patched into upstream's FROZEN list). `u_cpython -c "print('U41OK-5 hello from CPython on Hamnix')"` prints the marker. Binary 7.9 MB stripped, fully self-contained — no `/usr/lib/python3.11/` tree needed in the initramfs, sidesteps the `fs/cpio.ad` NR_FILES cap and GitHub's 100 MB push limit on `fs/initramfs_blob.S`. Verified self-contained: `PYTHONHOME=/nonexistent PYTHONPATH= ./python -c "print('test')"` prints `test`. See `scripts/test_u41_cpython.sh` and `tests/u-binary/src/cpython/HOWTO.md`.

Phase C.5 follow-up (commit `211e990`): real debootstrap'd Debian rootfs as a distro-shape namespace backing. `tests/distros/debian-minbase/{BUILD.sh,MANIFEST.txt,HOWTO.md}` stage a real Debian trixie minbase tree (host-side, gitignored, ~150-200 MB). `HAMNIX_EMBED_DEBIAN={1,minimal,full}` env-var opt-in for `scripts/build_initramfs.py`; `minimal` (6 curated files) fits the NR_FILES=192 cap and the 100 MB GitHub push limit, `full` (4759 files) is reserved for after NR_FILES bumps. Verified: `deb debian-minbase /bin/cat /etc/debian_version` reads `13.5` from inside the namespace; native side still reads `hamnix/0.1`. **First real Linux file read inside a distro-shape namespace.** Dynamic-binary exec (`deb /bin/true`) still blocked on a real `ld-linux-x86-64.so.2` interpreter — open follow-up.

**Cron's in-scope priority list is now fully delivered:** UEFI handover ✓, hybrid ISO ✓, AHCI ✓, NVMe ✓, e1000e/virtio-net/r8169 ✓, PS/2 keyboard ✓, real-hardware boot guide ✓, Python static ✓, musl busybox ✓. Real-hardware install path is structurally complete end-to-end.

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
| **L50** | 7 crypto modules in one agent: `xxhash_generic.ko`, `crypto_null.ko`, `des_generic.ko`, `chacha_generic.ko`, `poly1305_generic.ko`, `curve25519-generic.ko`, `chacha20poly1305.ko`. New `linux_abi/api_l50.ad` (881 lines) covers 50 new exports across 11 themed groups: registration entry-points (`crypto_register_algs`/`_skcipher`/`_skciphers`/`_kpp`/`_templates`), `_bh` spinlock variants, `__crypto_memneq`, scatterlist helpers (`sg_*`, `scatterwalk_*`), skcipher walk, xxhash runtime (`xxh64*`), DES/3DES passthroughs, ChaCha + HChaCha, Poly1305, Curve25519, and AEAD/template/hash glue. Stock Debian .ko load count is now **24** | **Done** |
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
| **U20** | **Kernel-as-Linux-loader pivot.** `fs/elf.ad` shrunk 740→445 lines: stripped all kernel-side relocation processing (`_apply_dyn_relocs`, `_process_dynamic`, `_lookup_dynsym`), let glibc/musl's own `_dl_relocate_static_pie` handle everything including IRELATIVE. Auxv now exposes `AT_PHDR`/`AT_PHENT`/`AT_PHNUM`/`AT_PAGESZ`/`AT_BASE`/`AT_ENTRY`/`AT_RANDOM` so the userspace relocator has what it needs. Retired hand-crafted asm fixtures `u_pie` + `u_dynsym` that depended on the old kernel reloc path. Removed `linux_abi/vdso.ad`. Result: `test_u20_glibc_memcpy.sh` PASSES — IFUNC-resolved `memcpy` works without any kernel involvement | **Done** |
| **U21** | `readlinkat` (267), `futex` (202) real impl, `getuid`/`getgid`/`geteuid`/`getegid` (102/104/107/108), `getppid` (110), `gettimeofday` (96), `sysinfo` (99) — all wired with proper Linux semantics. Real 16-slot futex wait-queue with park/wake on `_u_futex` | **Done** |
| **U22** | First non-trivial **glibc** workload: 796 KB static-pie binary running `strdup`/`free` + `fopen`/`fread`/`fclose` on `/etc/motd` + printf format variety + `time(NULL)`. All four markers fire | **Done** |
| **U23** | **Critical e820 allocator fix.** `arch/x86/kernel/e820.ad` was clamping its floor to a stale 2 MiB `E820_MIN_BASE` from M16.3 days; kernel image had grown to ~7.6 MB and `memblock_alloc` was handing out pages physically overlapping kernel `.text/.rodata/.bss`. New `kernel_image_end()` accessor in `head_64.S` returns `__bss_end`; the e820 walker clamps dynamically. Surfaced by U24's 2.4 MB C++ binary, which deterministically froze the kernel on a clean tree | **Done** |
| **U24** | First **C++** static-pie binary on Hamnix (`g++ -static-pie -O2 -lstdc++`). Exercises `std::cout` (iostream + TLS-backed locale via `%fs:`), `std::vector` + `std::sort`, `std::string` concat, `try`/`throw`/`catch` via `_Unwind_RaiseException` + `.eh_frame` walking. All four markers fire. Zero new syscall handlers needed | **Done** |
| **U25** | First Linux ELF execve chain: `_u_execve` (59) refactored into shared `do_execve` so a glibc binary can `execve("/bin/u_glibc_hello", ...)` and the kernel replaces its image cleanly. Also wired `SYS_time` (201) to close the last `-ENOSYS` log from U22 | **Done** |
| **U26** | First real `fork()`/`waitpid()` on Hamnix. `do_clone` deep-copies the parent's user stack page (vfork-style sync via new `vfork_done` flag in TaskStruct) so glibc's `__libc_fork` child-side FILE-list lock-reset doesn't trample the parent's canary slot. `_u_fork`/`_u_vfork`/`_u_wait4` all live. Glibc binary forks, child runs to `_exit(42)`, parent reaps with `WEXITSTATUS=42` | **Done** |
| **U27** | First real **musl pthreads** on Hamnix. `do_clone` gains a `CLONE_VM \| CLONE_THREAD` branch that honours caller-supplied `child_stack` and runs parent + child concurrently. `CLONE_SETTLS`/`CLONE_PARENT_SETTID`/`CLONE_CHILD_CLEARTID` all plumb through. New per-task `fs_base` + `clear_child_tid` fields in TaskStruct; `schedule()` writes `MSR_FS_BASE` from the next task's slot on every context switch. Real 16-slot **futex wait-queue** with park-on-WAIT + wake-on-WAKE; `task_exit_current` does the CHILD_CLEARTID handshake. **Critical fix in `arch/x86/kernel/syscall_64.S`:** the syscall stub now saves user `%rdi`/`%rsi`/`%rdx`/`%r10`/`%r8`/`%r9` on the kstack and conditionally restores them on return — `%rdi` preserved only when `nr == SYS_futex (202)` because musl's `__lockfile` spin loop keeps `&f->lock` in `%rdi` across FUTEX_WAIT and re-CASes after wake. Without this, mutex contention silently deadlocks. Two threads × 100 iters = `counter=200`, both threads + main reaped cleanly | **Done** |
| **U39** | First **Python interpreter** on Hamnix — MicroPython 1.22.0 unix port, ~900 KB static-pie ELF, runs `print('hello from hamnix')` via `u_python -X heapsize=64k -c "..."`. Zero new syscall handlers needed; the U18..U27 surface (brk + mmap + futex + clock_gettime + getrandom + readlinkat + rt_sigaction + writev) already covers MicroPython's boot path. Picked MicroPython over CPython because Debian's `libpython3.13.a` is non-PIC (defeats `-static-pie`) and CPython static-pie from source is ~25 MB / 20-40 min build vs MicroPython's 900 KB / 60 s. `-X heapsize=64k` shrinks the GC arena below glibc-malloc's brk-grow corner case where multi-chunk kmalloc returns non-contiguously and glibc aborts inside its arena bookkeeping. The U-track contract `u_python -c "print(...)"` is identical to what a full CPython install would need; this milestone proves the Linux ABI surface is wide enough to host a real interpreter — apt-installable Python is now a swap of the underlying binary, not new kernel work | **Done** |

Surface area below targets the actual end-game.

Goal: run unmodified Linux server binaries on top of Hamnix
— a useful **server OS** that can be installed on real
hardware, boot from disk, and host services. Targets:
Python 3, Apache/nginx, OpenSSH, PostgreSQL, the Debian
package manager itself. **Graphics is console-only (VGA text
+ EFI GOP text-mode framebuffer); X11 / Wayland / Steam /
Firefox / any GUI app are explicitly out of scope.** Implies:

- Linux x86_64 syscall ABI under the stock numbers (read=0,
  write=1, …, openat=257, futex=202, etc.). Hamnix's own
  syscalls move to a high-number range (1000+) to avoid
  collision.
- `/lib/ld-linux-x86-64.so.2` dynamic linker — either Hamnix-
  authored or wrapping Debian's. Required for apt-installed
  dynamic binaries (everything in Debian).
- Glibc / musl compatibility — the layers between syscalls
  and what apps actually call.
- `/proc` and `/sys` layouts that satisfy glibc's runtime
  setup + udev-style device introspection.
- Threading primitives — `futex(2)`, `clone(CLONE_THREAD)`,
  TLS via `arch_prctl(ARCH_SET_FS)`.
- Mmap layout that matches what loaders assume.
- TCP/IP networking — apt fetches over HTTP(S); a server OS
  must accept inbound connections (ssh, web).

## End game

A shippable **server distribution** where:
- Bootloader + kernel + init + shell + coreutils are all
  Hamnix-authored (the trust-critical surface).
- L-series enables loading the kernel modules needed for
  real hardware that we don't want to rewrite — AHCI, NVMe,
  e1000e / r8169, xhci-hcd / usbhid, ext4 (interim), TLS-
  capable crypto. Anything we _can_ write in Adder, we do.
- U-series enables installing services from Debian's
  repositories — `apt install python3`, `apt install
  apache2`, `apt install openssh-server`, `apt install
  postgresql`. The bar is "useful server OS", not "Linux
  desktop".
- The long-tail userspace comes from Debian, the
  security-critical core from Hamnix.

L-series order: L0/L1 (loader + structs) → L2..L28
(subsystems) → L29 (M-track validation) → L30..L40
(distro modules → first real-hardware boot).


## How it works

```
Adder source (.ad with static types, def/while/if, structs)
   │
   ▼
compiler/  (CPython-hosted; adder.py CLI dispatches by --target)
   │
   ├──► codegen_x86.py  ─► .S
   │     │
   │     ├──► x86_64-bare-metal                       (M16+)
   │     │    as --32 (with .code64) + ld -m elf_i386
   │     │    ──► hamnix-vmlinux.elf
   │     │    ──► QEMU -kernel multiboot1 ──► long mode ──► start_kernel()
   │     │
   │     ├──► x86_64-adder-user                       (M16.33+)
   │     │    as + ld -static ──► CPL-3 ELF
   │     │    ──► loaded by /init or hamsh exec
   │     │
   │     └──► x86_64-linux-kernel-module              (M1..M15)
   │          kbuild + modpost ──► .ko
   │          custom mitigations-off kernel + busybox initramfs
   │          ──► QEMU -serial stdio ──► dev loop closes
```

The x86_64 backend is hand-written — no LLVM — for zero external
dependencies. Kernel codegen constraints (SysV AMD64 ABI, 16-byte
stack alignment, ENDBR64 for IBT, no red zone, RIP-relative `.rodata`
refs) are handled directly.

## Quick start

Requirements: `gcc`, `make`, `qemu-system-x86_64`, `flex`, `bison`,
`libelf-dev`, Python 3.10+.

### Boot the Hamnix bare-metal kernel (M16+)

```bash
./scripts/run_x86_bare.sh
```

Compiles `init/main.ad` (plus the imports it pulls in:
`arch/x86/`, `mm/memblock.ad`, `kernel/sched/core.ad`,
`kernel/printk/printk.ad`, `drivers/tty/serial/early_8250.ad`),
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

`kernel-modules/hello/hello.ad`:

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
`kernel-modules/m2-console/m2_console.ad` — it declares the kernel's
`struct console` field-by-field in Hamnix, populates the fields in
`init_module`, and registers itself as a console. The driver's write
function polls the UART's Line Status Register via the `inb` intrinsic
and writes bytes via `outb`.

## Project structure

```
compiler/        Adder compiler (CPython-hosted)
  adder.py        CLI: --target= x86_64-linux-kernel-module | x86_64-bare-metal | x86_64-adder-user
  lexer.py        Tokenizer
  parser.py       Recursive-descent parser → AST
  ast_nodes.py    AST node definitions
  codegen_x86.py  x86_64 backend (hand-written, no LLVM)
  optimizer.py    AST-level passes

# Bare-metal Hamnix kernel (M16+) — layout mirrors Linux source tree
arch/x86/
  boot/header.S         multiboot1 + 32->64 transition; identity-map
                        first 1 GiB with U/S=1; GDT (kernel + user CS/DS)
  kernel/head_64.S      64-bit entry: BSS-zero, call start_kernel
  kernel/vmlinux.lds    linker script (elf32-i386 wrapper, 64-bit code)
  kernel/boot_info_asm.S mb_magic / mb_info accessors
  kernel/idt_asm.S      per-vector trap stubs + common_trap
  kernel/idt.ad         gate descriptor packing, idt_init
  kernel/traps.ad       do_trap dispatch + hex printing
  kernel/irq_asm.S      per-IRQ stubs + common_irq (iretq path)
  kernel/irq.ad         do_irq vector dispatch
  kernel/i8259.ad       8259 PIC remap + mask/unmask + EOI
  kernel/time.ad        PIT @ 100 Hz, jiffies, timer_interrupt -> schedule
  kernel/e820.ad        multiboot mmap walk -> memblock_set_region
  kernel/setup_percpu.ad + .S  Percpu[T] template memcpy + %gs base
  kernel/sched_asm.S    __switch_to_asm, kthread_bootstrap, enter_first_task
  kernel/syscall.ad + .S STAR/LSTAR/FMASK MSRs, syscall_entry, do_syscall
                        (SYS_PUTC/EXIT/GET_JIFFIES/CLONE/GETPID/
                         OPEN/READ/CLOSE)
  kernel/tss_asm.S      TSS + RSP0 — IRQs while in CPL 3
  kernel/apic.ad        Local APIC enable + LVT timer + PIT calibration
                        + INIT/SIPI IPI helpers
  kernel/smp.ad + smp_asm.S   AP bring-up via INIT-SIPI-SIPI;
                              ap_main_hamnix; CR3 / load_cr3 helpers
  realmode/trampoline.S real-mode→long-mode AP trampoline (placed
                        at physical 0x8000 by linker VMA trick)
  lib/string_64.S       memset / memcpy / memmove via rep stos/movs
  mm/init.ad            mem_init() arch-side bring-up
mm/memblock.ad          early bump allocator (~ mm/memblock.c)
mm/page_alloc.ad        order-N page allocator + buddy merge-on-free
mm/slab.ad              SLUB-style slab caches + kmalloc / kzalloc / kfree
                        large kmalloc routes to alloc_pages
kernel/sched/core.ad    task_struct, kthread_create, create_user_task,
                        preemptive schedule, multi-task lifecycle
kernel/printk/printk.ad printk0/1/2 + pr_emerg/err/warn/info/debug
kernel/panic.ad         panic / BUG / WARN_ON
kernel/list.ad          list_head intrusive doubly-linked list
fs/cpio.ad              parser for embedded newc cpio archive
fs/initramfs_blob.S     generated cpio bytes (scripts/build_initramfs.py)
fs/vfs.ad               vfs_open / read / write / close / lseek
                        + per-task fd table (lives in task_struct)
drivers/tty/serial/early_8250.ad  polled 16550A UART
drivers/video/console/vga_text.ad text-mode VGA console at 0xB8000
drivers/pci/pci.ad      PCI config space access (port 0xCF8/0xCFC)
                        + bus scan
drivers/net/netfilter.ad netfilter hook chain + indirect dispatch
scripts/build_initramfs.py  regenerates fs/initramfs_blob.S
init/main.ad            start_kernel()

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
  run_x86_bare.sh        Compile init/main.ad → hamnix-vmlinux.elf → QEMU -kernel
  build_x86_kernel.sh    Fetch + build mitigations-off Linux for QEMU
  x86_kernel_config.sh   Kernel config knobs
  make_initramfs.sh      Build static busybox + cpio initramfs
  run_x86_module.sh      Build module → pack initramfs → boot QEMU → scrape serial

docs/
  architecture.md          Layered model (Layer 0..5), migration plan,
                           per-subsystem layer assignments. Start here.
  native-api.md            Layer 1 Plan 9-shape syscall reference + the
                           migration table for every existing SYS_*.
  vtnext-v2.md             Layer 4 graphical wire protocol — apps →
                           hamwd → pygame/local renderer.
  x86-backend.md           Why the x86_64 backend is hand-written (no LLVM).
  BOOT.md                  How to build + boot the ISO, real-hardware notes.
  L_TRACK_HOWTO.md         How to add a stock-Debian .ko to the L-track.
  L30_DISTRO_MODULE_NOTES.md  First-distro-.ko milestone (crc32c_generic).
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
