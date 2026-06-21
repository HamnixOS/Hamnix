# UMDF — User-Mode Driver Framework (Track 4)

Stock Linux `.ko` modules historically load into **kernel** memory
(`linux_abi/loader.ad`) and share the kernel fault domain: a buggy vendor
driver panics the box. A Plan 9- and server-correct OS runs drivers as
**restartable userland file servers**. UMDF moves `.ko` execution out of
the kernel fault domain into a normal userland process.

This document describes the **first vertical slice**: the protocol, the
three privileged kernel primitives, the userland host, and the
crash-isolation guarantee. The in-kernel loader path is unchanged and
still available; UMDF is the new, crash-isolated path.

## Shape

A user-mode driver is a normal process that:

1. loads + relocates a stock ET_REL `.ko` in **its own user memory** and
   runs `init_module()` in **CPL3** (`user/umdf_host.ad`);
2. requests the irreducible kernel-trust primitives over a narrow,
   audited **syscall channel** (below);
3. posts a `#X` **9P file server** (existing `SYS_SRV_POST`, the
   namespace law) so the rest of the system reaches the driver as files.

A fault in the `.ko` — or a `kill` of the host — is a **process crash the
kernel survives**. The host can be restarted; the kernel reclaims every
privilege it held.

## The three privileged primitives

Everything a driver needs that userspace cannot synthesize, and nothing
more. Bodies live in `linux_abi/umdf_kernel.ad`, reached from the Layer-1
dispatcher (`arch/x86/kernel/syscall.ad`) through registered hooks so
Layer 1 never statically names the Linux-ABI module (a native-only build
returns `-ENOSYS`).

| Primitive | Syscall | Contract |
|-----------|---------|----------|
| **MMIO map** | `SYS_UMDF_MMIO_MAP` (321) `a0=phys, a1=len` | Overlay a device BAR region into the caller's **user VA**, **uncacheable** (PCD set). Returns user VA / `-errno`. The driver pokes registers with plain loads/stores. |
| **DMA alloc** | `SYS_UMDF_DMA_ALLOC` (322) `a0=len, a1=&out_phys` | Allocate **physically-contiguous** pages, map them into the host's user VA, and write the **physical base** to `*out_phys` so the device can be programmed (no IOMMU: CPU phys == bus addr). Returns user VA / `-errno`. |
| **IRQ file** | `SYS_UMDF_IRQ_OPEN` (323) `a0=vector` | Register a CPU vector and return a readable **irq fd**. A `read(fd, buf, 8)` blocks until the vector fires, then returns the accumulated fire count as a little-endian `uint64`. "Everything is a file" applied to interrupts. |

### How each is implemented

- **MMIO / DMA map** reserve a placed, teardown-tracked user-VA window via
  `vma_alloc_demand`, then **overlay** the real physical pages onto that
  window's leaf PTEs with `elf_install_user_mapping` (the same primitive
  that maps ELF segments into a task). The reservation is then marked
  `is_foreign` (`vma_mark_foreign`) so task teardown clears the PTEs but
  **never `free_page()`s the frames** — they are device registers, or DMA
  pages reclaimed explicitly on host exit. Without this flag, exiting a
  host would free device-physical addresses into the buddy allocator.
- **IRQ file** keeps a small per-vector registry; `SYS_UMDF_IRQ_OPEN`
  installs a per-row trampoline as the vector's handler
  (`register_irq_handler`). On each fire the trampoline bumps a count and
  `wq_wake_all`s a per-row `WaitQueue` (IRQ-safe). The blocking `read`
  uses the two-phase `wq_wait_prepare` / recheck / `wq_wait_commit` dance,
  closing the SMP lost-wakeup window against the trampoline.

## Crash isolation

`task_exit_current` (scheduler) calls a registered hook
`register_umdf_task_exit_hook(umdf_task_cleanup)` for **every** task exit
— clean exit, `kill`, or fault all funnel through it. `umdf_task_cleanup`
releases the host's IRQ files (unclaims the vector; the trampoline becomes
a no-op) and frees its DMA buffers. The host's user-VA windows are torn
down by the normal VMA teardown (`vma_clear` → the `is_foreign` arm). So a
vendor `.ko` crash leaves **no** kernel vector or DMA region wedged, and a
fresh host re-`umdf_open`s the same vector cleanly.

## The userland host

`user/umdf_host.ad` is the port of the in-kernel ET_REL machinery (ELF64
parse, SHF_ALLOC layout, progbits copy / bss zero, x86_64 relocation,
symbol resolution, `init_module` dispatch) into a CPL3 process. The `.ko`
lands in `mmap`'d **user** memory (RW for data, RWX for the loaded code
region). External symbols resolve against the host's userland shim table
(`shim_lookup`) — the per-process equivalent of `linux_abi/exports.ad`:
`_printk` lands in a userland printk, and the privileged-primitive shims
(`umdf_mmio_map` / `umdf_dma_alloc` / `umdf_irq_open`) trap into the three
syscalls above. After `init_module()` returns 0 the host posts `#umdf` and
serves.

`selftest-mmio` / `selftest-dma` / `selftest-irq` exercise each primitive;
`crashme` dereferences NULL to demonstrate that a driver fault is a
recoverable process crash.

## Gate

`scripts/test_umdf_host.sh` builds a **hermetic** stock-shape probe `.ko`
from the tracked Adder source `kernel-modules/m2-string/m2_string.ad`
(via the Adder `x86_64-linux-kernel-module` target + `as` — no Linux tree
needed; a genuine ET_REL with GLOBAL `init_module`, an UND `_printk`, and
`R_X86_64_PC32`/`R_X86_64_PLT32` relocs). Driven from `/etc/hamsh.rc`, it
loads the `.ko` in userland, exercises DMA + IRQ, crashes a host, asserts
the kernel survives, and re-inits a fresh host.

## What is explicitly out of this slice

- A respawn **supervisor** that auto-restarts a crashed driver host
  (today: kernel survives + host is manually restartable).
- A real BAR-backed driver and the full block/net `#X` file tree (the
  server loop is handshake-minimal).
- A userland-shim table at parity with `linux_abi/exports.ad`, and `%gs`
  per-CPU handling in userland (the in-kernel loader keeps these).
- The in-kernel loader path stays in place; UMDF is additive.
