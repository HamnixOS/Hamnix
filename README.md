# Pynux

**A Python-syntax systems language being used to write a Linux-equivalent
kernel on x86_64 from boot up — and incrementally infiltrate stock Linux
along the way.**

Pynux compiles Python-syntax source with static types directly to native
machine code via a hand-written, zero-dependency compiler. Two parallel
tracks share the same compiler and language:

1. **Bare-metal Pynux kernel + userland** (M16+) — Pynux compiles its
   own bootable kernel image AND its own user-mode programs.
   QEMU `-kernel build/pynux-vmlinux.elf -smp 2` boots
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
   in Pynux (`user/hello.py` → `python3 -m compiler.pynux compile
   --target=x86_64-pynux-user ...`) and `SYS_EXECVE` replaces a
   running user image with a new ELF from the initramfs. Source
   tree mirrors Linux's layout
   (`arch/x86/boot/`, `arch/x86/kernel/`, `arch/x86/mm/`,
   `arch/x86/lib/`, `arch/x86/realmode/`, `init/`, `mm/`, `kernel/`,
   `kernel/sched/`, `kernel/printk/`, `drivers/tty/serial/`,
   `drivers/video/console/`, `drivers/pci/`, `drivers/net/`, `fs/`,
   `user/`, `mod/`) so reading the equivalent Linux file → porting
   it to Pynux is the unit of work. The Pynux language has gained a small set of
   kernel-aware primitives along the way — `Percpu[T]` per-CPU
   storage, `container_of(ptr, Type, field)`, `cast[Ptr[T]](x)`, and
   inline `asm_volatile` / `outb`/`inb`/`outl`/`inl` — so the source
   stays close to how Linux's `include/linux/*.h` macros read.

2. **.ko module infiltration** (M1..M15) — 40 Pynux-authored kernel
   modules that load into a stock Linux kernel via the regular kbuild
   path. Exercise nearly every major kernel subsystem (chrdev, procfs,
   debugfs, ramfs, slab, kthread, workqueue, hrtimer, mutex, kprobe,
   kretprobe, sysfs, crypto, virtio-blk/-net, netfilter, kfifo, ...).
   Still build and pass; kept as the regression baseline as bare-metal
   subsystems land.

The end-game is a fully Pynux-authored kernel.

## Status

| Milestone | Description | Status |
|-----------|-------------|--------|
| M1 | hello-world `.ko` — loads, `_printk`s, unloads | **Done** |
| M2 | 16550A serial console — printk traffic routed through Pynux `pynux_console_write` (RIP-relative `outb`+LSR poll) | **Done** |
| M3.1 | `/proc/pynux/state` — procfs entry with Pynux seq_file show callback | **Done** |
| M3.2 | `/dev/pynuxdisk` — 8 MiB block device, Pynux `submit_bio` | **Done** |
| M3.3 | `pynuxfs` ramfs-class filesystem — mount + file write/read + mkdir/rm/rmdir + umount | **Done** |
| M4.1 | UART RX via `request_threaded_irq` — IRQ handler in hardirq context, spinlock-guarded counter, wait_queue wake-up, `asm_volatile("pause")` | **Done** |
| M4.2 | virtio-blk — find_vqs via vtable, dma_alloc_attrs, virtqueue_add_sgs + kick → read sector 0 of disk image | **Done** |
| M4.3a | kthread + workqueue — kthread_create_on_node + manual INIT_WORK + queue_work_on | **Done** |
| M4.3b | virtio-net — register, probe, read MAC via vdev->config->get byte-by-byte, set up (rx, tx) vq pair | **Done** |
| M5.1 | `/dev/pynux` char device — file_operations.read returns greeting via simple_read_from_buffer | **Done** |
| M5.2 | kernel timer — init_timer_key + mod_timer + timer_delete, softirq-context callback | **Done** |
| M5.3 | netfilter hook on NF_INET_PRE_ROUTING — every IPv4 packet goes through Pynux | **Done** |
| M6.1 | slab cache — __kmem_cache_create_args + kmem_cache_alloc/free + kmalloc/kfree | **Done** |
| M6.2 | hrtimer — nanosecond-precision timer, 5 ms relative, HRTIMER_NORESTART | **Done** |
| M6.3 | mutex + completion — kthread takes mutex, signals completion; main waits | **Done** |
| M7.1 | kprobe — intercepts every `__x64_sys_openat` call before kernel handler runs | **Done** |
| M7.2 | sysfs — `/sys/pynux/info` via kobject_create_and_add + sysfs_create_file_ns | **Done** |
| M7.3 | crypto — SHA-256("hello") via crypto_alloc_shash + crypto_shash_tfm_digest | **Done** |
| M8.1 | `/dev/pynurand` — CSPRNG via get_random_bytes + _copy_to_user | **Done** |
| M8.2 | atomic_t — two kthreads × 1000 atomic increments via `lock incl` inline asm = exactly 2000 | **Done** |
| M8.3 | dummy ethernet `eth1` — alloc_etherdev_mqs + register_netdev + ndo_open/stop/xmit callbacks in Pynux; visible in `ifconfig` | **Done** |
| M9.1 | task introspection — read `current` via `%gs:pcpu_hot` inline asm; print pid + comm of the insmod-ing process | **Done** |
| M9.2 | intrusive doubly-linked list — INIT_LIST_HEAD + list_add + walk all implemented in pure Pynux | **Done** |
| M9.3 | kernel UDP socket — sock_create_kern + kernel_bind to port 9999 + sock_release | **Done** |
| M10.1 | `/dev/pynuxzero` — clone of /dev/zero (reads return NUL bytes via _copy_to_user) | **Done** |
| M10.2 | delayed_work — queue_delayed_work_on + delayed_work_timer_fn, fires after 10 ms | **Done** |
| M11.1 | ktime_get nanosecond clock — measures msleep(10) at ~11.6 ms | **Done** |
| M11.2 | debugfs — Pynux-owned `/sys/kernel/debug/pynux/counter`, bidirectional userspace ↔ kernel u32 | **Done** |
| M12.1 | netfilter packet inspector — parses sk_buff IPv4 header, prints src/dst of every packet | **Done** |
| M12.2 | `/dev/pynuxnull` — clone of /dev/null | **Done** |
| M13.1 | utsname reader — pulls kernel release "6.12.48" out of `init_uts_ns` | **Done** |
| M13.2 | smp_processor_id — reads CPU number from `%gs:pcpu_hot+12` | **Done** |
| M14.1 | syscall hook with payload capture — kprobe on `__x64_sys_openat` reads pt_regs->di → syscall pt_regs->si → user filename byte via copy_from_user_nofault | **Done** |
| M14.2 | kretprobe — captures syscall return values from regs->ax on `__x64_sys_openat` exit; matches M14.1's 17 entries | **Done** |
| M15.1 | register_die_notifier — Pynux on the kernel die/oops/panic notification chain | **Done** |
| M15.2 | kfifo circular buffer — alloc + in + out via the kernel's lock-free ring; "Hi!" round-trips byte-perfect | **Done** |
| **M16.1** | **Bare-metal pivot** — Pynux compiles its own bootable kernel image; QEMU multiboot1 → 64-bit long mode → Pynux `start_kernel()` → UART banner | **Done** |
| M16.2 | IDT + trap handlers — 32 vector stubs, common_trap, Pynux `do_trap` (mirrors `arch/x86/kernel/traps.c`) | **Done** |
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
| M16.33 | `x86_64-pynux-user` compiler target — userland programs written in Pynux; `user/hello.py` runs as a real CPL-3 ELF | **Done** |

The microcontroller OS the project originally shipped (ARM Cortex-M,
QEMU mps2-an385, RP2040, STM32F4) still compiles via the original ARM
Thumb-2 backend. It is intentionally kept working but is no longer the
focus of new work.

## How it works

```
Pynux source (.py with static types, def/while/if, structs)
   │
   ▼
compiler/  (CPython-hosted; pynux.py CLI dispatches by --target)
   │
   ├──► codegen_x86.py  ─► .S
   │     │
   │     ├──► x86_64-bare-metal                       (M16+)
   │     │    as --32 (with .code64) + ld -m elf_i386
   │     │    ──► pynux-vmlinux.elf
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

### Boot the Pynux bare-metal kernel (M16+)

```bash
./scripts/run_x86_bare.sh
```

Compiles `init/main.py` (plus the imports it pulls in:
`arch/x86/`, `mm/memblock.py`, `kernel/sched/core.py`,
`kernel/printk/printk.py`, `drivers/tty/serial/early_8250.py`),
assembles + links into `build/pynux-vmlinux.elf`, and boots it under
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

## Writing a kernel module in Pynux

`kernel-modules/hello/hello.py`:

```python
extern def _printk(fmt: str) -> int32

def init_module() -> int32:
    _printk("Pynux: hello from init_module\n")
    return 0

def cleanup_module():
    _printk("Pynux: goodbye from cleanup_module\n")
```

`init_module` / `cleanup_module` are the kernel's legacy module-entry
symbol names, found by the loader directly — no `module_init()` macro
needed. `_printk` is the modern kernel's exported printk; declared
`extern def` in Pynux. The compiler emits `.S`; the kernel's `kbuild`
system (`obj-m := hello.o`) does the rest including modpost (vermagic,
glue, link).

For an example of real hardware access in Pynux, see
`kernel-modules/m2-console/m2_console.py` — it declares the kernel's
`struct console` field-by-field in Pynux, populates the fields in
`init_module`, and registers itself as a console. The driver's write
function polls the UART's Line Status Register via the `inb` intrinsic
and writes bytes via `outb`.

## Project structure

```
compiler/        Pynux compiler (CPython-hosted)
  pynux.py       CLI: --target= arm-cortex-m3 | x86_64-linux-kernel-module | x86_64-bare-metal
  lexer.py       Tokenizer
  parser.py      Recursive-descent parser → AST
  ast_nodes.py   AST node definitions
  codegen_x86.py x86_64 backend (hand-written, growing per milestone)
  codegen_arm.py ARM Thumb-2 backend for the MCU OS (frozen reference)
  optimizer.py   AST-level passes

# Bare-metal Pynux kernel (M16+) — layout mirrors Linux source tree
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
                              ap_main_pynux; CR3 / load_cr3 helpers
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

kernel-modules/  Pynux source for each module milestone
  hello/         M1   hello-world
  m2-arith/      M2.0 params/locals/while/if
  m2-string/     M2.1 pointer indexing
  m2-outb/       M2.2 outb/inb intrinsics
  m2-strout/     M2.3 polled string write
  m2-console/    M2.4 struct console + register_console
  m3-proc/       M3.1 /proc/pynux/state via seq_file
  m3-disk/       M3.2 /dev/pynuxdisk block device
  m3-fs/         M3.3 pynuxfs mountable filesystem
  m4-uart-rx/    M4.1 UART RX IRQ + spinlock + wait_queue
  m4-virtio-blk/ M4.2 virtio-blk read sector 0
  m4-kthread-wq/ M4.3a kthread + workqueue
  m4-virtio-net/ M4.3b virtio-net probe + MAC read + vq setup
  m5-chrdev/     M5.1 /dev/pynux char device
  m5-timer/      M5.2 jiffies-based kernel timer
  m5-netfilter/  M5.3 netfilter hook on NF_INET_PRE_ROUTING
  m6-slab/       M6.1 slab cache + kmalloc
  m6-hrtimer/    M6.2 high-resolution timer
  m6-sync/       M6.3 mutex + completion
  m7-kprobe/     M7.1 kprobe intercepting __x64_sys_openat
  m7-sysfs/      M7.2 /sys/pynux/info kobject
  m7-crypto/     M7.3 SHA-256 via kernel crypto API
  m8-random/     M8.1 /dev/pynurand via get_random_bytes
  m8-atomic/     M8.2 atomic_t via `lock incl` inline asm
  m8-netdev/     M8.3 dummy ethernet net_device
  m9-task/       M9.1 read `current` via per-CPU segment register
  m9-list/       M9.2 list_head intrusive list (pure Pynux)
  m9-socket/     M9.3 in-kernel UDP socket bound to port 9999
  m10-zero/      M10.1 /dev/pynuxzero (clone of /dev/zero)
  m10-dwork/     M10.2 delayed_work via timer-backed workqueue
  m11-ktime/     M11.1 ktime_get nanosecond clock
  m11-debugfs/   M11.2 debugfs u32 counter
  m12-nfdump/    M12.1 netfilter packet inspector
  m12-null/      M12.2 /dev/pynuxnull
  m13-utsname/   M13.1 read kernel release from init_uts_ns
  m13-cpuid/     M13.2 smp_processor_id via per-CPU segment
  m14-syscall/   M14.1 kprobe captures the path of every openat()
  m14-kretprobe/ M14.2 kretprobe captures the return value
  m15-die-notifier/ M15.1 register_die_notifier
  m15-kfifo/     M15.2 kfifo circular buffer

scripts/         x86 dev-loop infrastructure
  run_x86_bare.sh        Compile init/main.py → pynux-vmlinux.elf → QEMU -kernel
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
