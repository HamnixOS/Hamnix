# Pynux

**A Python-syntax systems language being used to incrementally rewrite
Linux kernel code on x86_64 — one loadable module at a time.**

Pynux compiles Python-syntax source with static types directly to native
machine code via a hand-written, zero-dependency compiler. The current
focus is using Pynux as the target language for a "slow infection" of the
Linux kernel: real kernel subsystems get reimplemented in Pynux and loaded
into a stock kernel as `.ko` modules. The end-game is a fully-Pynux
kernel built up subsystem by subsystem.

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
   ├──► codegen_x86.py  ─►  GNU `as` (x86_64 SysV) ──► .o ──► .ko (kbuild + modpost)
   │                        custom kernel + busybox initramfs
   │                        ──► QEMU -serial stdio ──► dev loop closes
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
  pynux.py       CLI: --target=arm-cortex-m3 (default) or x86_64-linux-kernel-module
  lexer.py       Tokenizer
  parser.py      Recursive-descent parser → AST
  ast_nodes.py   AST node definitions
  codegen_x86.py x86_64 backend (hand-written, growing per milestone)
  codegen_arm.py ARM Thumb-2 backend for the MCU OS (frozen reference)
  optimizer.py   AST-level passes

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

scripts/         x86 dev-loop infrastructure
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
